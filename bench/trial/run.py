#!/usr/bin/env python3
"""The pharos trial's runner (#7): one task under one arm, isolated, measured.

Design: doc/trial/007-design.md. Contract: geex's doc/stack-trial-hooks.md
(where they disagree, the contract wins). The rounds of the full trial are
bench/trial/rounds.py's job; this file does one run.

    python3 -I bench/trial/run.py --prepare --task T2          # the start state, once per task
    python3 -I bench/trial/run.py --task T2 --arm 3 --out results.jsonl
    python3 -I bench/trial/run.py --task T2 --arm 2 --smoke --out smoke.jsonl
    python3 -I bench/trial/run.py --probe-subagent --out probe.jsonl

It expects the trial's setup under /tmp/trial (see /tmp/trial/env.sh): node 22
and yarn 4.11.0; the project's prepared install in /tmp/trial/install; one
standalone repo per start state in /tmp/trial/starts (one commit, one ref, no
remote); pharos and captAInHook installed there; and the two hook scripts
pinned in /tmp/trial/hooks. DEEPSEEK_API_KEY comes from the environment; it is
passed to Claude Code only, never written or logged.

Arms: 1 no hook (captAInHook wired with no handlers, so the plumbing is the
same); 2 the compiler hook (captAInHook's compiler-hook.sh); 3 pharos's hook
(integrations/captainhook/pharos-hook.sh).

What the agent can reach: Claude Code runs in a bubblewrap mount namespace
where /home, /tmp, /mnt and /run/user are empty, with only the run's own
directory, its runtime directory, the trial's tools (read-only) and the node
install bound back. So it can't see the task files (the hidden tests), the
start repos, other runs, the runner's records, or other sessions. Its git
repository holds one commit, with no remote. The network stays open (the
model is remote); a run whose tool calls touch github.com, curl, wget, git
remotes or paths outside the run is flagged.

--smoke runs everything except the model call. It spends nothing.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TRIAL = Path("/tmp/trial")
INSTALL = TRIAL / "install"          # node_modules and yarn's install state, prepared once
STARTS = TRIAL / "starts"            # <start[:12]>.git: one commit, one ref, no remote
PRIVATE = TRIAL / "private"          # the runner's own files per run, never bound into the sandbox
HOOKS = TRIAL / "hooks"
CACHE = TRIAL / "cache"
# The hooks the trial runs, by content. arm 2: captAInHook 833f082's
# examples/payloads/compiler-hook.sh; arm 3: pharos 0.3.4's (byte-identical to 0.3.3's)
# integrations/captainhook/pharos-hook.sh. Both match Bash|Agent|Task.
PINNED = {"compiler-hook.sh": "d3d5c29c9b9405c86fb873689e0426979a0206501ba628adb3bab3aa843b613f",
          "pharos-hook.sh": "1a2a772fbd8894070ca504b5835d08910d4eed3fc3b1b92910c6c37300a81a2f"}
TASKS = Path(__file__).resolve().parent / "tasks"
NVM = Path("/home/oof/.nvm")
CLAUDE = shutil.which("claude", path=str(NVM / "versions/node/v25.4.0/bin")) or "claude"
NODE_DIR = sorted((TRIAL / "mise/installs/node").glob("22.*"))[-1] / "bin"

MODEL = "deepseek-v4-pro"
MODEL_VARS = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
              "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"]
# Setup check 3, re-measured 2026-11-19 on the tasks' own widest edits: arm 2's
# checker took 46.6-48.4 s on a quiet machine, but 116 s in the dry run's arm 2
# on T2's signature change. The budget is >= 2x the largest seen anywhere.
BUDGET_MS = 240_000
HOOK_TIMEOUT_S = 270           # Claude Code's hook timeout, above the budget
TURN_TIMEOUT_S = 45 * 60
EVENTS = {"UserPromptSubmit": "user-prompt-submit", "PreToolUse": "pre-tool-use",
          "PostToolUse": "post-tool-use", "Stop": "stop"}
# The same sentence, in every arm, before the first prompt (the server tests
# need Postgres and Redis, which the trial doesn't provide).
PREAMBLE = ("Note: the server tests (vitest project \"server\") need Postgres and Redis, which "
            "aren't available in this environment. The app and shared tests (yarn test:app, "
            "yarn test:shared) run.\n\n")
# captAInHook's payload allowlist: what a hook's child sees, plus passEnv.
HOOK_ALLOWLIST = ["PATH", "HOME", "USER", "SHELL", "LANG", "TZ", "TMPDIR"]
# Off in every arm: the web (an agent could look outline up), and subagents
# (Claude Code 2.1.328 runs them asynchronously: their result re-enters as a
# new prompt, which resets both hooks' turn). The trial is "an agent without
# subagents" (the maintainer, 2026-11-19).
DISALLOWED = ["WebSearch", "WebFetch", "Agent"]
BUILD_TEST = re.compile(r"\b(tsc|vitest|yarn (test|tsc|lint|build)|npm (test|run)|oxlint|eslint)\b")
# Tool-call text that reaches outside the run: flagged, never blocked.
SUSPICIOUS = re.compile(r"github\.com|githubusercontent|outline/outline|\bcurl\b|\bwget\b|"
                        r"\bgit (clone|fetch|pull|remote|ls-remote)\b|/home/|/tmp/trial|/tmp/claude|"
                        r"/mnt/|/run/user|\bnpm (view|info|pack)\b")
TS_ERROR = re.compile(r"^(?P<file>.+)\((?P<line>\d+),(?P<col>\d+)\): error TS(?P<code>\d+): (?P<msg>.*)$")
TS_GLOBAL = re.compile(r"^error TS(?P<code>\d+): (?P<msg>.*)$")
TS_EXT = (".ts", ".tsx", ".mts", ".cts")


class Invalid(Exception):
    """The run can't be measured fairly; it is recorded as invalid."""


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def log(msg):
    print("[trial] " + msg, file=sys.stderr, flush=True)


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def loadavg() -> list[float]:
    return [float(x) for x in open("/proc/loadavg").read().split()[:3]]


# --------------------------------------------------------------- the checks

def tsc_keys(proj: Path, buildinfo: Path, env, wrap=()) -> tuple[dict, float]:
    """The measuring check: tsc on the whole project, read into key counts.
    A key is (path, code, message), with continuation lines joined by one
    space; errors with no file have an empty path."""
    t0 = time.time()
    r = sh([*wrap, str(proj / "node_modules/.bin/tsc"), "--noEmit", "--incremental", "--pretty", "false",
            "--tsBuildInfoFile", str(buildinfo), "-p", str(proj / "tsconfig.json")], cwd=proj, env=env)
    took = time.time() - t0
    counts: dict[str, int] = {}
    cur = None

    def flush():
        if cur is not None:
            k = json.dumps([cur[0], cur[1], cur[2]])
            counts[k] = counts.get(k, 0) + 1

    for line in r.stdout.splitlines():
        if cur is not None and re.match(r"^\s+\S", line):
            cur = (cur[0], cur[1], cur[2] + " " + line.strip())
            continue
        flush()
        cur = None
        m = TS_ERROR.match(line)
        if m:
            cur = (m["file"].removeprefix("./"), "TS" + m["code"], m["msg"].rstrip())
        else:
            m = TS_GLOBAL.match(line)
            if m:
                cur = ("", "TS" + m["code"], m["msg"].rstrip())
    flush()
    return counts, took


def vitest(proj: Path, priv: Path, projects, env, files=None, wrap=()) -> dict:
    """Run vitest, its report written to the runner's private dir; return
    {passed, failed, failures, passing}."""
    out = Path(tempfile.mktemp(prefix="vitest", suffix=".json", dir=priv))
    cmd = [*wrap, str(proj / "node_modules/.bin/vitest"), "run", "--reporter=json", "--outputFile=" + str(out)]
    for p in projects:
        cmd += ["--project", p]
    cmd += list(files or [])
    r = sh(cmd, cwd=proj, env=dict(env, TZ="UTC"))
    try:
        data = json.loads(out.read_text())
        out.unlink()
    except Exception:  # noqa: BLE001
        return {"passed": 0, "failed": -1, "failures": ["vitest did not report: " + r.stderr[-400:]], "passing": []}
    failures = [t["fullName"] for f in data.get("testResults", []) for t in f.get("assertionResults", [])
                if t.get("status") == "failed"]
    # Each passing test as (file, full name), once per project that ran it
    # (shared-node and shared-jsdom run the same files): "every test that
    # passed at the start still passes" compares these as multisets.
    passing = sorted(json.dumps([os.path.relpath(f["name"], proj), t["fullName"]])
                     for f in data.get("testResults", []) for t in f.get("assertionResults", [])
                     if t.get("status") == "passed")
    if data.get("numFailedTestSuites"):
        failures += [f["name"] for f in data.get("testResults", []) if f.get("status") == "failed"
                     and not f.get("assertionResults")]
    return {"passed": data.get("numPassedTests", 0), "failed": len(failures), "failures": failures[:50],
            "passing": passing}


def tree_state(proj: Path) -> dict:
    """Every path the agent can see that a measure might write: the project
    outside node_modules, plus node_modules' cache dirs. path -> (mtime, size)."""
    state = {}
    for root, dirs, files in os.walk(proj):
        rel = os.path.relpath(root, proj)
        if rel == "node_modules":
            dirs[:] = [d for d in dirs if d in (".cache", ".vite", ".vitest")]
        elif rel == ".git" or rel.startswith(".git/"):
            dirs[:] = []
            continue
        for f in files:
            p = os.path.join(root, f)
            try:
                st = os.lstat(p)
                state[os.path.relpath(p, proj)] = (st.st_mtime_ns, st.st_size)
            except FileNotFoundError:
                pass
    return state


def measure(r, task, turn_index: int, start: dict, env) -> dict:
    """After a turn's final Stop: broken (the contract's measure) and done
    (the hidden acceptance test). Nothing it does stays visible to the
    agent: vitest's cache (which names the tests it ran) is set aside and
    restored, its reports go to a fresh report-only dir, and the hidden
    test is removed; any path it leaves changed is flagged."""
    proj, priv = r["proj"], r["priv"]
    vite, aside = proj / "node_modules/.vite", priv / ".vite-agent"
    shutil.rmtree(aside, ignore_errors=True)
    if vite.exists():
        vite.rename(aside)
    before = tree_state(proj)
    # The measure runs the agent's code (its vitest config, its tests), so
    # inside the sandbox too, with only a fresh report dir added for vitest's
    # reports: not the whole private dir, which holds the turns' logs
    # (verifier's re-check).
    reports = priv / ("measure-%d" % (turn_index + 1))
    shutil.rmtree(reports, ignore_errors=True)
    reports.mkdir()
    wrap = sandbox(r, extra_binds=[reports])
    counts, took = tsc_keys(proj, r["run"] / "measure.tsbuildinfo", env, wrap)
    grown = {k: (start["keys"].get(k, 0), n) for k, n in counts.items() if n > start["keys"].get(k, 0)}
    tests = vitest(proj, reports, task["test_projects"], env, wrap=wrap)
    now_passing = {}
    for k in tests.pop("passing"):
        now_passing[k] = now_passing.get(k, 0) + 1
    lost = sorted(k for k, n in start["passing"].items() if now_passing.get(k, 0) < n)
    acc = task["turns"][turn_index]["acceptance"]
    acc_path = proj / acc["path"]
    acc_path.write_text(acc["text"])
    try:
        done = vitest(proj, reports, [acc["project"]], env, files=[acc["path"]], wrap=wrap)
        done.pop("passing", None)
    finally:
        acc_path.unlink(missing_ok=True)
        shutil.rmtree(vite, ignore_errors=True)
        if aside.exists():
            aside.rename(vite)
    after = tree_state(proj)
    left = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p)
                  and not p.startswith("node_modules/.vite/"))
    return {"tsc_seconds": round(took, 1), "errors": sum(counts.values()), "grown_keys": grown,
            "tests": tests, "lost_tests": lost[:50], "broken": bool(grown) or bool(lost),
            "done": done["failed"] == 0 and done["passed"] > 0, "acceptance": done, "measure_left": left[:50]}


# --------------------------------------------------------------- processes

def proc_info(pid: int):
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
        exe = os.readlink(f"/proc/{pid}/exe")
        stat = open(f"/proc/{pid}/stat").read()
        ppid = int(stat[stat.rindex(")") + 2:].split()[1])
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
        return cwd, exe, ppid, cmd
    except (OSError, ValueError):
        return None


def pharos_tree(pid: int) -> bool:
    """Is pid the runner-started pharos daemon or one of its descendants (the
    language server, tsserver)? Those stay up between turns."""
    seen = 0
    while pid > 1 and seen < 64:
        info = proc_info(pid)
        if info is None:
            return False
        if info[1].startswith(str(TRIAL / "pharos/versions/")):
            return True
        pid, seen = info[2], seen + 1
    return False


def leftovers(run: Path) -> list[tuple[int, str]]:
    """Processes working under the run's directory, other than pharos's."""
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) == os.getpid():
            continue
        info = proc_info(int(name))
        if info and (info[0] == str(run) or info[0].startswith(str(run) + "/")) and not pharos_tree(int(name)):
            found.append((int(name), info[3][:160]))
    return found


def settle(run: Path) -> list[str]:
    """Kill whatever the turn left running under the run's directory (a
    watcher, a dev server, captAInHook's daemon); refuse to measure if any of
    it survives. Returns what was killed."""
    killed = []
    for _ in range(20):
        left = leftovers(run)
        if not left:
            return killed
        for pid, cmd in left:
            try:
                os.kill(pid, signal.SIGKILL)
                killed.append(cmd)
            except ProcessLookupError:
                pass
        time.sleep(0.5)
    raise Invalid("processes still running under the run dir: %r" % leftovers(run))


# --------------------------------------------------------------- the run dir

def start_repo(task) -> Path:
    return STARTS / (task["start"][:12] + ".git")


def make_run(task) -> dict:
    run = Path(os.path.realpath(tempfile.mkdtemp(prefix="tr", dir="/tmp")))
    rt = Path(os.path.realpath(tempfile.mkdtemp(prefix="rt", dir="/tmp")))
    os.chmod(rt, 0o700)
    if len(str(rt)) > 60:
        raise SystemExit("runtime dir too long: %s" % rt)
    priv = PRIVATE / run.name
    priv.mkdir(parents=True)
    home = run / "home"
    (home / ".config/pharos").mkdir(parents=True)
    proj = run / "proj"
    # A fresh repository holding the start commit only: no other ref, no
    # remote, no promisor, no reflog naming where it came from.
    c = sh(["git", "clone", "-q", "--no-local", "--single-branch", "--branch", "start",
            str(start_repo(task)), str(proj)])
    if c.returncode != 0:
        raise SystemExit("clone: " + c.stderr)
    sh(["git", "-C", str(proj), "remote", "remove", "origin"])
    sh(["git", "-C", str(proj), "reflog", "expire", "--expire=now", "--all"])
    git = {"head": sh(["git", "-C", str(proj), "rev-parse", "HEAD"]).stdout.strip(),
           "refs": sh(["git", "-C", str(proj), "for-each-ref", "--format=%(refname)"]).stdout.split(),
           "remotes": sh(["git", "-C", str(proj), "remote"]).stdout.split(),
           "commits": int(sh(["git", "-C", str(proj), "rev-list", "--all", "--count"]).stdout.strip() or 0),
           "promisor": sh(["git", "-C", str(proj), "config", "--get", "extensions.partialclone"]).stdout.strip()}
    if git != {"head": task["start"], "refs": ["refs/heads/start"], "remotes": [], "commits": 1, "promisor": ""}:
        raise SystemExit("the project's repository isn't the start commit alone: %r" % git)
    # One prepared install, hard-linked; a writable cache and .vite per run.
    sh(["cp", "-al", str(INSTALL / "node_modules"), str(proj / "node_modules")])
    for d in (".cache", ".vite"):
        shutil.rmtree(proj / "node_modules" / d, ignore_errors=True)
        (proj / "node_modules" / d).mkdir()
    (proj / ".yarn").mkdir(exist_ok=True)
    shutil.copyfile(INSTALL / ".yarn/install-state.gz", proj / ".yarn/install-state.gz")
    (home / ".config/pharos/pharos.toml").write_text(
        "# The pharos trial: typescript-language-server uses the project's own TypeScript.\n"
        "[languages.typescript]\ninitialization_options_json = '''\n"
        + json.dumps({"hostInfo": "pharos", "tsserver": {"path": str(proj / "node_modules/typescript/lib")}})
        + "\n'''\n")
    return {"run": run, "rt": rt, "home": home, "proj": proj, "priv": priv, "git": git}


def base_env(r) -> dict:
    return {
        "PATH": f"{TRIAL}/bin:{TRIAL}/tools/bin:{NODE_DIR}:/usr/bin:/bin",
        "HOME": str(r["home"]), "XDG_RUNTIME_DIR": str(r["rt"]),
        "USER": os.environ.get("USER", "trial"), "SHELL": "/bin/sh",
        "LANG": "C.UTF-8", "TZ": "UTC", "TMPDIR": "/tmp",
        "COREPACK_HOME": str(TRIAL / "corepack"), "YARN_CACHE_FOLDER": str(TRIAL / "yarn-cache"),
        "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0",
    }


def claude_env(r, effort) -> dict:
    env = base_env(r)
    env.update({
        "CLAUDE_CONFIG_DIR": str(r["run"] / "claude"),
        "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
        "ANTHROPIC_AUTH_TOKEN": os.environ["DEEPSEEK_API_KEY"],
        "CLAUDE_CODE_EFFORT_LEVEL": effort,
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
    })
    for v in MODEL_VARS:
        env[v] = MODEL
    return env


def sandbox(r, extra_binds=()) -> list[str]:
    """bubblewrap around Claude Code (and so around its tools and hooks) and
    around the measure (which runs the agent's code): the host's filesystem,
    with /home, /tmp, /mnt and /run/user emptied and only what the run needs
    bound back. Same paths inside and out, so the runner-started pharos daemon
    and the hooks agree on every path. Its own pid namespace: Claude Code
    starts each Bash command and each hook in a session of its own, which a
    process-group kill doesn't reach (verifier's re-check: captAInHook's
    daemon, cwd /, outlived every run), so everything started inside dies
    with bwrap."""
    cmd = ["bwrap", "--dev-bind", "/", "/", "--die-with-parent", "--unshare-pid", "--proc", "/proc",
           "--tmpfs", "/home", "--ro-bind", str(NVM), str(NVM),
           "--tmpfs", "/tmp", "--tmpfs", "/run/user", "--tmpfs", "/mnt"]
    if os.path.isdir("/run/WSL"):
        cmd += ["--tmpfs", "/run/WSL"]      # WSL's interop sockets: no Windows processes from inside
    resolv = os.path.realpath("/etc/resolv.conf")
    if resolv.startswith(("/mnt/", "/run/user/")):
        cmd += ["--ro-bind", resolv, resolv]
    cmd += ["--bind", str(r["run"]), str(r["run"]), "--bind", str(r["rt"]), str(r["rt"])]
    for d in ("bin", "tools", "pharos", "captainhook", "mise", "hooks"):
        cmd += ["--ro-bind", str(TRIAL / d), str(TRIAL / d)]
    for d in ("corepack", "yarn-cache"):
        (TRIAL / d).mkdir(exist_ok=True)
        cmd += ["--bind", str(TRIAL / d), str(TRIAL / d)]
    for d in extra_binds:
        cmd += ["--bind", str(d), str(d)]
    return cmd + ["--chdir", str(r["proj"])]


def check_sandbox(r) -> dict:
    """What the agent can see, checked from inside: nothing of the task
    files, the start repos, the runner's records or other runs."""
    probe = ("for p in %s; do [ -e \"$p\" ] && echo \"visible $p\"; done; ls -A /tmp | tr '\\n' ' '; echo; "
             "ls -A /home | tr '\\n' ' '" % " ".join(
                 [str(TASKS), str(STARTS), str(PRIVATE), str(CACHE), str(TRIAL / "results"), str(INSTALL),
                  "/home/oof/pharos-mcp", "/home/oof/.claude", "/run/user/%d" % os.getuid()]))
    out = sh(sandbox(r) + ["sh", "-c", probe], env=base_env(r))
    lines = out.stdout.splitlines()
    visible = [l for l in lines if l.startswith("visible ")]
    tmp = lines[len(visible)].split() if len(lines) > len(visible) else []
    ok = out.returncode == 0 and not visible and sorted(tmp) == sorted({r["run"].name, r["rt"].name, "trial"})
    if not ok:
        raise SystemExit("sandbox check failed: rc=%d %r %s" % (out.returncode, lines, out.stderr[-300:]))
    return {"tmp_visible": tmp, "home_visible": lines[-1].split() if lines else []}


def wire_hooks(r, arm) -> dict:
    """The arm's captAInHook handlers and Claude Code's hook settings."""
    proj, run = r["proj"], r["run"]
    handlers = []
    events = list(EVENTS.values())
    if arm == 2:
        handlers.append({"name": "compiler-hook", "command": str(HOOKS / "compiler-hook.sh"),
                         "args": ["--root", str(proj), "--budget-ms", str(BUDGET_MS), "--",
                                  str(proj / "node_modules/.bin/tsc"), "--noEmit", "--incremental",
                                  "--pretty", "false", "--tsBuildInfoFile", str(run / "hook.tsbuildinfo"),
                                  "-p", str(proj / "tsconfig.json")],
                         "events": events, "mode": "oneshot", "failMode": "open", "budgetMs": BUDGET_MS})
    elif arm == 3:
        handlers.append({"name": "pharos-hook", "command": str(HOOKS / "pharos-hook.sh"),
                         "args": ["--root", str(proj), "--budget-ms", str(BUDGET_MS),
                                  "--pharos", str(TRIAL / "bin/pharos")],
                         "events": events, "mode": "oneshot", "failMode": "open", "budgetMs": BUDGET_MS,
                         "passEnv": ["XDG_RUNTIME_DIR"]})
    ch = r["home"] / ".captainHook"
    ch.mkdir(parents=True, exist_ok=True)
    (ch / "handlers.json").write_text(json.dumps({"version": 1, "handlers": handlers}, indent=1))
    cfg = run / "claude"
    cfg.mkdir()
    shim = str(TRIAL / "bin/captainShim")
    settings = {"hooks": {ev: [{"hooks": [{"type": "command", "command": f"{shim} hook {name}",
                                           "timeout": HOOK_TIMEOUT_S}]}]
                          for ev, name in EVENTS.items()}}
    assert sorted(settings["hooks"]) == sorted(EVENTS), settings
    (cfg / "settings.json").write_text(json.dumps(settings, indent=1))
    return {"handlers": handlers}


def check_isolation(r) -> dict:
    v = sh([str(TRIAL / "bin/captainHook"), "version"], env=base_env(r))
    rendezvous = next((l.split(None, 1)[1] for l in v.stdout.splitlines() if l.startswith("rendezvous")), "")
    if not rendezvous.startswith(str(r["rt"])):
        raise SystemExit("isolation: captainHook's rendezvous is %r, not under %s" % (rendezvous, r["rt"]))
    return {"rendezvous": rendezvous, "rt_chars": len(str(r["rt"]))}


def versions(r) -> dict:
    env = base_env(r)

    def first(cmd, cwd=None):
        out = sh(cmd, env=env, cwd=cwd)
        return (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr).strip() else "?"
    return {"claude": first([CLAUDE, "--version"]), "pharos": first([str(TRIAL / "bin/pharos"), "--version"]),
            "tsc": first([str(r["proj"] / "node_modules/.bin/tsc"), "-v"]),
            "captainHook": sh([str(TRIAL / "bin/captainHook"), "version"], env=env).stdout.strip().splitlines()[:2],
            "node": first(["node", "-v"]), "yarn": first(["yarn", "--version"], cwd=r["proj"]),
            "typescript_language_server": first([str(TRIAL / "tools/bin/typescript-language-server"), "--version"]),
            "bwrap": first(["bwrap", "--version"])}


def hook_env(env) -> dict:
    """Exactly a hook's environment: captAInHook's allowlist plus passEnv."""
    h = {k: env[k] for k in HOOK_ALLOWLIST if k in env}
    h["XDG_RUNTIME_DIR"] = env["XDG_RUNTIME_DIR"]
    return h


def warm_start(r, arm, task, env) -> dict:
    t0 = time.time()
    if arm == 2:
        tsc_keys(r["proj"], r["run"] / "hook.tsbuildinfo", env)
        return {"seconds": round(time.time() - t0, 1)}
    if arm != 3:
        return {"seconds": 0.0}
    tries = 0
    while True:
        tries += 1
        out = sh([str(TRIAL / "bin/pharos"), "diagnostics", "--json", "--timeout-ms", "120000", task["warm_file"]],
                 cwd=r["proj"], env=hook_env(env))
        f = (json.loads(out.stdout)["files"][0] if out.returncode == 0 else {})
        if f.get("status") == "ok" and f.get("project") == str(r["proj"] / "tsconfig.json"):
            break
        if tries >= 10:
            raise Invalid("warm start: no ok answer with the trial tsconfig: %r %s" % (f, out.stderr[-300:]))
        time.sleep(2)
    # The tsserver this daemon's language server runs must be the project's own.
    ps = sh(["ps", "-eo", "args"]).stdout
    own = str(r["proj"] / "node_modules/typescript/lib/tsserver.js")
    return {"seconds": round(time.time() - t0, 1), "tries": tries, "own_tsserver": own in ps}


def scope_check(r, env) -> dict:
    """Setup check 4, once per start state: every TypeScript file of the
    project's own program, asked of pharos with the runs' tools, must be in
    the trial tsconfig's project. A non-ok answer is retried (a projectInfo
    timeout under load is transient); a named other project fails."""
    t0 = time.time()
    proj = r["proj"]
    out = sh([str(proj / "node_modules/.bin/tsc"), "--listFilesOnly", "-p", "tsconfig.json"], cwd=proj, env=env)
    files = [os.path.relpath(p, proj) for p in out.stdout.split()
             if p.startswith(str(proj) + "/") and "/node_modules/" not in p and p.endswith(TS_EXT)]
    results = {}

    def ask(batch):
        a = sh([str(TRIAL / "bin/pharos"), "diagnostics", "--json", "--timeout-ms", "60000", "--"] + batch,
               cwd=proj, env=hook_env(env))
        if a.returncode != 0:
            raise SystemExit("scope check: pharos failed: %s" % a.stderr[-400:])
        for f in json.loads(a.stdout)["files"]:
            results[f["file"]] = f
    for i in range(0, len(files), 100):
        ask(files[i:i + 100])
    for _ in range(3):
        retry = [f for f, x in results.items() if x["status"] != "ok"]
        if not retry:
            break
        time.sleep(3)
        ask(retry)
    want = str(proj / "tsconfig.json")
    other = {f: x.get("project") for f, x in results.items() if x["status"] == "ok" and x.get("project") != want}
    not_ok = {f: [x["status"], x.get("reason")] for f, x in results.items() if x["status"] != "ok"}
    ok = sum(1 for x in results.values() if x["status"] == "ok" and x.get("project") == want)
    return {"files": len(files), "ok_root": ok, "other": dict(list(other.items())[:20]),
            "not_ok": dict(list(not_ok.items())[:20]), "seconds": round(time.time() - t0, 1),
            "pass": ok == len(files) and len(files) > 0}


# --------------------------------------------------------------- the start

def cache_key(task) -> Path:
    return CACHE / ("%s-%s" % (task["id"], task["start"][:12]))


def prepare(task) -> dict:
    """The task's start state, once: the measuring check's error keys (and
    its tsbuildinfo, which makes each run's first measure incremental: the
    run dir's layout, <run>/proj beside <run>/measure.tsbuildinfo, is the
    same in every run), the tests that pass, and the scope check, with the
    versions that produced them."""
    CACHE.mkdir(parents=True, exist_ok=True)
    r = make_run(task)
    try:
        env = base_env(r)
        info = r["run"] / "measure.tsbuildinfo"
        keys, took = tsc_keys(r["proj"], info, env)
        tests = vitest(r["proj"], r["priv"], task["test_projects"], env)
        passing = {}
        for k in tests["passing"]:
            passing[k] = passing.get(k, 0) + 1
        scope = scope_check(r, env)
        st = {"task": task["id"], "start": task["start"], "prepared": now(), "keys": keys,
              "tsc_seconds": round(took, 1), "passing": passing, "failing": tests["failures"],
              "scope": scope, "versions": versions(r)}
        if not scope["pass"]:
            raise SystemExit("scope check failed for %s: %r" % (task["id"], scope))
        cache_key(task).with_suffix(".json").write_text(json.dumps(st))
        shutil.copyfile(info, cache_key(task).with_suffix(".tsbuildinfo"))
        return st
    finally:
        teardown(r, keep=False)


def start_state(r, task) -> dict:
    key = cache_key(task)
    if not (key.with_suffix(".json").exists() and key.with_suffix(".tsbuildinfo").exists()):
        raise SystemExit("no prepared start for %s: run --prepare --task %s first" % (task["id"], task["id"]))
    st = json.loads(key.with_suffix(".json").read_text())
    if not st.get("scope", {}).get("pass"):
        raise SystemExit("the prepared start for %s has no passing scope check" % task["id"])
    shutil.copyfile(key.with_suffix(".tsbuildinfo"), r["run"] / "measure.tsbuildinfo")
    return st


# --------------------------------------------------------------- the turns

def run_turn(r, env, prompt, resume, timeout) -> dict:
    """One `claude -p` in the sandbox, in its own process group, killed as a
    group afterwards; then nothing of it may be left under the run dir."""
    cmd = sandbox(r) + [CLAUDE, "-p", prompt, "--output-format", "stream-json", "--verbose",
                        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                        "--disallowedTools", *DISALLOWED, "--dangerously-skip-permissions"]
    if resume:
        cmd += ["--resume", resume]
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=r["proj"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, err = p.communicate()
        timed_out = True
    wall = time.time() - t0
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    killed = settle(r["run"])
    return {"wall_seconds": round(wall, 1), "exit": p.returncode, "timed_out": timed_out, "stream": out,
            "killed_after": killed,
            "stderr_tail": err[-600:].replace(os.environ.get("DEEPSEEK_API_KEY", "\0"), "<key>")}


def read_stream(stream: str, run: Path) -> dict:
    """Tokens, tool calls, the session id, and any tool call reaching outside
    the run, from Claude Code's stream-json."""
    usage_by_id: dict[str, dict] = {}
    session = None
    models = set()
    bash, tools, result, suspicious = [], {}, {}, []
    for line in stream.splitlines():
        try:
            m = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        if m.get("type") == "system" and m.get("subtype") == "init":
            session = session or m.get("session_id")
        if m.get("type") == "assistant":
            msg = m.get("message", {})
            if msg.get("model"):
                models.add(msg["model"])
            if msg.get("id") and msg.get("usage"):
                usage_by_id[msg["id"]] = msg["usage"]
            for c in msg.get("content", []):
                if c.get("type") == "tool_use":
                    tools[c["name"]] = tools.get(c["name"], 0) + 1
                    text = json.dumps(c.get("input", {})).replace(str(run), "<run>")
                    if SUSPICIOUS.search(text):
                        suspicious.append({"tool": c["name"], "input": text[:300]})
                    if c["name"] == "Bash":
                        bash.append(c.get("input", {}).get("command", ""))
        if m.get("type") == "result":
            result = {k: m.get(k) for k in ("num_turns", "is_error", "subtype", "duration_ms", "usage")}
    tot = {"input": 0, "cache_read": 0, "cache_creation": 0, "output": 0}
    for u in usage_by_id.values():
        tot["input"] += u.get("input_tokens", 0) or 0
        tot["cache_read"] += u.get("cache_read_input_tokens", 0) or 0
        tot["cache_creation"] += u.get("cache_creation_input_tokens", 0) or 0
        tot["output"] += u.get("output_tokens", 0) or 0
    # DeepSeek's per-message usage in stream-json carries output_tokens 0;
    # the result event's usage holds the turn's real totals. Prefer it.
    ru = result.get("usage") or {}
    if ru:
        tot = {"input": ru.get("input_tokens", 0) or 0, "cache_read": ru.get("cache_read_input_tokens", 0) or 0,
               "cache_creation": ru.get("cache_creation_input_tokens", 0) or 0,
               "output": ru.get("output_tokens", 0) or 0,
               "thinking": (ru.get("output_tokens_details") or {}).get("thinking_tokens", 0) or 0}
    return {"session": session, "models": sorted(models), "messages": len(usage_by_id),
            "tokens": tot, "tools": tools, "build_test_runs": [c[:200] for c in bash if BUILD_TEST.search(c)],
            "suspicious": suspicious[:20], "result": result}


def read_trail(home: Path) -> dict:
    """captAInHook's trail (logs/captainHook.jsonl under the run's HOME):
    each hook call's time (exec.answered durMs, per hookEvent), the
    trial.unsure lines (exec.stderr), budget kills (exec.kill), and every
    dispatch's session id."""
    unsure, kills, calls, sessions = [], 0, [], set()
    for f in sorted((home / ".captainHook/logs").glob("captainHook*.jsonl")):
        for line in f.read_text(errors="replace").splitlines():
            try:
                rec = json.loads(line)
            except Exception:  # noqa: BLE001
                continue
            evt = rec.get("evt", "")
            if evt == "dispatch.start" and rec.get("sessionId"):
                sessions.add(rec["sessionId"])
            elif evt == "exec.answered":
                try:
                    ms = float(rec.get("durMs") or 0)
                except ValueError:
                    ms = 0.0
                calls.append({"event": rec.get("hookEvent"), "ms": round(ms, 1),
                              "effect": (rec.get("data") or {}).get("effect") if isinstance(rec.get("data"), dict) else None})
            elif evt == "exec.stderr":
                unsure.extend(re.findall(r"trial\.unsure reason=\S+ event=\S+", rec.get("msg") or ""))
            elif evt == "exec.kill" and (rec.get("msg") or "") != "teardown":
                kills += 1  # captAInHook also logs exec.kill when it drains an actor at teardown
    by_event: dict[str, list] = {}
    for c in calls:
        by_event.setdefault(c["event"], []).append(c["ms"])
    summary = {ev: {"n": len(v), "median_ms": sorted(v)[len(v) // 2], "max_ms": max(v)} for ev, v in by_event.items()}
    return {"unsure": unsure, "budget_kills": kills, "hook_calls": calls, "hook_call_summary": summary,
            "sessions": sorted(sessions)}


def hook_probe(r, task, env) -> dict:
    """--smoke only: drive the arm's hook through captAInHook's shim from
    inside the sandbox, the way Claude Code would (UserPromptSubmit, an
    Edit's PreToolUse and PostToolUse on the warm file, Stop), and read
    what the trail says ran. It proves the sandboxed hook reaches the
    runner's pharos daemon (arm 3) or runs tsc (arm 2)."""
    sid = "smoke-" + r["run"].name
    path = str(r["proj"] / task["warm_file"])
    base = {"session_id": sid, "transcript_path": str(r["run"] / "transcript.jsonl"), "cwd": str(r["proj"])}
    steps = [("user-prompt-submit", {"hook_event_name": "UserPromptSubmit", "prompt": "smoke"}),
             ("pre-tool-use", {"hook_event_name": "PreToolUse", "tool_name": "Edit",
                               "tool_input": {"file_path": path, "old_string": "x", "new_string": "x"}}),
             ("post-tool-use", {"hook_event_name": "PostToolUse", "tool_name": "Edit",
                                "tool_input": {"file_path": path, "old_string": "x", "new_string": "x"},
                                "tool_response": {"filePath": path}}),
             ("stop", {"hook_event_name": "Stop", "stop_hook_active": False})]
    out = []
    for name, payload in steps:
        p = subprocess.run(sandbox(r) + [str(TRIAL / "bin/captainShim"), "hook", name], input=json.dumps(base | payload),
                           capture_output=True, text=True, env=env, timeout=HOOK_TIMEOUT_S, start_new_session=True)
        out.append({"event": name, "exit": p.returncode, "stdout": p.stdout[:200]})
    killed = settle(r["run"])
    trail = read_trail(r["home"])
    checked = []
    for f in sorted((r["home"] / ".captainHook/logs").glob("captainHook*.jsonl")):
        for line in f.read_text(errors="replace").splitlines():
            if '"exec.stderr"' in line or '"exec.answered"' in line:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                checked.append([rec.get("hookEvent"), rec.get("evt"), (rec.get("msg") or "")[:120],
                                (rec.get("data") or {}).get("effect") if isinstance(rec.get("data"), dict) else None])
    return {"steps": out, "killed_after": killed, "calls": trail["hook_call_summary"], "unsure": trail["unsure"],
            "trail": checked[:20]}


# --------------------------------------------------------------- one run

def run_task(task, arm, effort, smoke, keep, slot=None) -> dict:
    hashes = {name: sha256(HOOKS / name) for name in PINNED}
    if hashes != PINNED:
        raise SystemExit("the pinned hooks changed: %r" % hashes)
    r = make_run(task)
    log("run %s arm %d in %s (rt %s)" % (task["id"], arm, r["run"], r["rt"]))
    rec = {"task": task["id"], "kind": task["kind"], "arm": arm, "effort": effort, "model": MODEL,
           "slot": slot, "disallowed_tools": DISALLOWED, "budget_ms": BUDGET_MS, "hook_timeout_s": HOOK_TIMEOUT_S,
           "smoke": smoke, "started": now(), "load_start": loadavg(), "run_dir": str(r["run"]),
           "git": r["git"], "turns": [], "anomalies": []}
    try:
        env = claude_env(r, effort) if not smoke else base_env(r)
        rec["hooks"] = {"sha256": hashes, **wire_hooks(r, arm)}
        rec["isolation"] = check_isolation(r)
        rec["sandbox"] = check_sandbox(r)
        rec["versions"] = versions(r)
        start = start_state(r, task)
        rec["start"] = {"errors": sum(start["keys"].values()), "passing_tests": sum(start["passing"].values()),
                        "failing_tests": start["failing"], "prepared": start["prepared"],
                        "scope": {k: start["scope"][k] for k in ("files", "ok_root", "pass")}}
        rec["warm_start"] = warm_start(r, arm, task, base_env(r))
        if arm == 3 and not rec["warm_start"].get("own_tsserver"):
            rec["anomalies"].append("tsserver isn't the project's own")
        if smoke:
            rec["hook_probe"] = hook_probe(r, task, base_env(r))
        session = None
        for i, turn in enumerate(task["turns"]):
            prompt = (PREAMBLE if i == 0 else "") + turn["prompt"]
            if smoke:
                t = {"wall_seconds": 0, "exit": None, "smoke": True, "killed_after": settle(r["run"])}
            else:
                raw = run_turn(r, env, prompt, session, TURN_TIMEOUT_S)
                (r["priv"] / ("turn%d.jsonl" % (i + 1))).write_text(raw["stream"])
                s = read_stream(raw["stream"], r["run"])
                session = session or s["session"]
                t = {k: v for k, v in raw.items() if k != "stream"} | s
                if s["suspicious"]:
                    rec["anomalies"].append("turn %d: %d tool call(s) reaching outside the run" % (i + 1, len(s["suspicious"])))
            t["measure"] = measure(r, task, i, start, base_env(r))
            if t["measure"]["measure_left"]:
                rec["anomalies"].append("turn %d: the measure left %r" % (i + 1, t["measure"]["measure_left"][:5]))
            rec["turns"].append(t)
            log("turn %d: wall %ss broken=%s done=%s" % (i + 1, t["wall_seconds"], t["measure"]["broken"],
                                                        t["measure"]["done"]))
        rec["trail"] = read_trail(r["home"])
        socks = sorted(p.name for p in (r["rt"] / "pharos").glob("*.sock")) if (r["rt"] / "pharos").exists() else []
        rec["pharos_sockets"] = socks
        if len(socks) != (1 if arm == 3 else 0):
            rec["anomalies"].append("pharos sockets: %d (arm %d expects %d)" % (len(socks), arm, 1 if arm == 3 else 0))
        rec["scope_flag"] = bool(sh(["git", "status", "--porcelain", "--", "*tsconfig*.json"], cwd=r["proj"]).stdout.strip())
    except Invalid as e:
        rec["invalid"] = str(e)
        log("invalid: %s" % e)
    finally:
        rec["finished"] = now()
        rec["load_end"] = loadavg()
        teardown(r, keep)
    return rec


def teardown(r, keep):
    env = base_env(r)
    sh([str(TRIAL / "bin/pharos"), "daemon", "stop"], env=env)
    # Anything still working under the run dir after the daemon stopped
    # (the language server and tsserver it spawned, a stray watcher).
    for name in os.listdir("/proc"):
        if name.isdigit():
            info = proc_info(int(name))
            if info and info[0].startswith(str(r["run"])):
                try:
                    os.kill(int(name), signal.SIGKILL)
                except ProcessLookupError:
                    pass
    shutil.rmtree(r["rt"], ignore_errors=True)
    if not keep:
        # The run's HOME (captAInHook's trail, the hooks' state) and Claude
        # Code's config dir (the session transcripts) go to the runner's
        # private dir; the project goes.
        for d in ("home", "claude"):
            if (r["run"] / d).exists():
                shutil.move(str(r["run"] / d), str(r["priv"] / d))
        shutil.rmtree(r["run"], ignore_errors=True)


def probe_subagent(effort, smoke) -> dict:
    """Do a subagent's hook events carry the parent's session id? Arm 3, a
    one-file project, a prompt that hands the only edit to a subagent. (The
    full runs disallow the Agent tool; this probe doesn't, by design.)"""
    run = Path(os.path.realpath(tempfile.mkdtemp(prefix="tp", dir="/tmp")))
    rt = Path(os.path.realpath(tempfile.mkdtemp(prefix="rt", dir="/tmp")))
    os.chmod(rt, 0o700)
    priv = PRIVATE / run.name
    priv.mkdir(parents=True)
    home, proj = run / "home", run / "proj"
    (home / ".config/pharos").mkdir(parents=True)
    proj.mkdir()
    (proj / "tsconfig.json").write_text(json.dumps({"compilerOptions": {"strict": True, "noEmit": True}, "include": ["*.ts"]}))
    (proj / "package.json").write_text('{"name":"probe","version":"0.0.0","private":true}\n')
    (proj / "a.ts").write_text("export const a: number = 1;\n")
    (home / ".config/pharos/pharos.toml").write_text(
        "[languages.typescript]\ninitialization_options_json = '''\n"
        + json.dumps({"hostInfo": "pharos", "tsserver": {"path": str(INSTALL / "node_modules/typescript/lib")}}) + "\n'''\n")
    r = {"run": run, "rt": rt, "home": home, "proj": proj, "priv": priv}
    wire_hooks(r, 3)
    rec = {"probe": "subagent-session-id", "isolation": check_isolation(r), "smoke": smoke}
    if not smoke:
        raw = run_turn(r, claude_env(r, effort),
                       "Use the Task tool to start one subagent, and have that subagent append the line "
                       "`export const b: number = 2;` to the end of a.ts. Don't edit any file yourself.",
                       None, 15 * 60)
        (priv / "turn1.jsonl").write_text(raw["stream"])
        s = read_stream(raw["stream"], run)
        rec.update({"session": s["session"], "tools": s["tools"], "tokens": s["tokens"], "models": s["models"],
                    "wall_seconds": raw["wall_seconds"], "edited": "export const b" in (proj / "a.ts").read_text(),
                    "trail": read_trail(home), "stderr_tail": raw["stderr_tail"]})
    teardown(r, keep=False)
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--task")
    ap.add_argument("--arm", type=int, choices=[1, 2, 3])
    ap.add_argument("--effort", default="high")
    ap.add_argument("--out")
    ap.add_argument("--slot", help="the scheduler's slot (round/position/attempt), recorded")
    ap.add_argument("--smoke", action="store_true", help="everything but the model call")
    ap.add_argument("--keep", action="store_true", help="keep the run's directory")
    ap.add_argument("--prepare", action="store_true", help="build the task's start state (once per task)")
    ap.add_argument("--probe-subagent", action="store_true")
    a = ap.parse_args()
    # One run at a time on this machine, whoever starts it.
    TRIAL.joinpath("run.lock").touch()
    lock = open(TRIAL / "run.lock")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("another trial run holds /tmp/trial/run.lock")
    task = json.loads((TASKS / (a.task + ".json")).read_text()) if a.task else None
    if a.prepare:
        st = prepare(task)
        print(json.dumps({"task": task["id"], "errors": sum(st["keys"].values()),
                          "passing": sum(st["passing"].values()), "failing": len(st["failing"]),
                          "scope": {k: st["scope"][k] for k in ("files", "ok_root", "pass", "seconds")}}))
        return
    if not a.out:
        raise SystemExit("--out is required")
    if not a.smoke and not os.environ.get("DEEPSEEK_API_KEY"):
        raise SystemExit("DEEPSEEK_API_KEY isn't set")
    if a.probe_subagent:
        rec = probe_subagent(a.effort, a.smoke)
    else:
        rec = run_task(task, a.arm, a.effort, a.smoke, a.keep, slot=a.slot)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with open(a.out, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps({k: rec.get(k) for k in ("task", "arm", "slot", "probe", "smoke", "invalid", "anomalies")}))


if __name__ == "__main__":
    main()
