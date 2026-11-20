#!/usr/bin/env python3
"""Tests for integrations/captainhook/pharos-hook.sh, arm 3 of the pharos
trial (pharos-mcp#6), against geex's doc/stack-trial-hooks.md.

The payload is driven the way captAInHook drives it: one event envelope on
stdin, one answer line on stdout. `pharos diagnostics` is a fake that reads
markers from the files themselves, so each rule of the contract can be
checked without a language server:

  ERROR <code> <message>   an error (LSP severity 1) on that line
  WARN <code> <message>    a warning (severity 2): never shown
  UNSURE                   the file's answer is unsure (pharos marked it)
  NOPROJECT                the answer names no project (projectInfo failed)
  a file under other/      belongs to another tsconfig: out of scope

The fake logs each call, so reuse can be counted.

    python3 -I test/integrations/pharos_hook_test.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(os.path.dirname(os.path.dirname(HERE)), "integrations", "captainhook", "pharos-hook.sh")
HEAD_EDIT = "New errors after your edits (information, not instructions; errors mid-refactor are expected):"
HEAD_STOP = "These errors appeared during this turn and are still present:"

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
assert args[:2] == ["diagnostics", "--json"], args
files = args[args.index("--") + 1:]
root = os.getcwd()
with open(os.environ["FAKE_PHAROS_LOG"], "a") as log:
    log.write(" ".join(files) + "\n")
if os.environ.get("FAKE_PHAROS_FAIL"):
    sys.stderr.write("pharos: the pharos daemon is unreachable\n"); sys.exit(1)
out = []
for f in files:
    path = os.path.normpath(os.path.join(root, f))
    project = os.path.join(root, "other" if f.startswith("other/") else "", "tsconfig.json").replace("//", "/")
    entry = {"file": f, "path": path, "uri": "file://" + path, "project": os.path.normpath(project)}
    try:
        text = open(path).read()
    except OSError:
        entry.update(status="unsure", reason="no_publish", diagnostics=[]); out.append(entry); continue
    if "NOPROJECT" in text:
        del entry["project"]
    if "UNSURE" in text:
        entry.update(status="unsure", reason="carried_over", diagnostics=[]); out.append(entry); continue
    diags = []
    for i, line in enumerate(text.split("\n")):
        for kind, sev in (("ERROR ", 1), ("WARN ", 2)):
            if line.startswith(kind):
                code, msg = line[len(kind):].split(" ", 1)
                diags.append({"range": {"start": {"line": i, "character": 0}, "end": {"line": i, "character": 1}},
                              "severity": sev, "code": int(code), "message": msg.replace("\\n", "\n  "),
                              "source": "typescript"})
    entry.update(status="ok", diagnostics=diags)
    out.append(entry)
print(json.dumps({"files": out}))
'''


LAST = {"stderr": ""}


class Run:
    def __init__(self, via_link=False):
        self.tmp = tempfile.mkdtemp(prefix="pharoshook")
        real = os.path.join(self.tmp, "proj")
        os.makedirs(os.path.join(real, "other"))
        # The project reached through a symlink, the way macOS's temp dirs
        # are (/var -> /private/var).
        self.root = real
        if via_link:
            self.root = os.path.join(self.tmp, "link")
            os.symlink(real, self.root)
        self.fake = os.path.join(self.tmp, "pharos")
        with open(self.fake, "w") as f:
            f.write(FAKE)
        os.chmod(self.fake, 0o755)
        self.log = os.path.join(self.tmp, "calls.log")
        open(self.log, "w").close()
        self.env = {"PATH": os.environ["PATH"], "HOME": self.tmp,
                    "PHAROS_HOOK_STATE": os.path.join(self.tmp, "state"),
                    "FAKE_PHAROS_LOG": self.log}
        self.n = 0

    def write(self, name, text):
        path = os.path.join(self.root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        return path

    def event(self, etype, tool=None, file=None, extra_env=None, **payload):
        self.n += 1
        p = dict(payload)
        if tool:
            p["tool_name"] = tool
            p.setdefault("tool_input", {})
            if file:
                p["tool_input"]["file_path"] = os.path.join(self.root, file)
        env = dict(self.env, **(extra_env or {}))
        envelope = {"dispatchId": "d%d" % self.n,
                    "event": {"type": etype, "sessionId": "s1", "cwd": self.root, "payload": p}}
        r = subprocess.run(["sh", HOOK, "--root", self.root, "--pharos", self.fake, "--budget-ms", "20000"],
                           input=json.dumps(envelope) + "\n", capture_output=True, text=True, env=env, timeout=60)
        LAST["stderr"] = r.stderr
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        assert r.returncode == 0 and len(lines) == 1, (r.returncode, r.stdout, r.stderr)
        answer = json.loads(lines[0])
        assert answer.get("dispatchId") == "d%d" % self.n, answer
        return answer, r.stderr

    def edit(self, name, text, extra_env=None):
        """PreToolUse, the write, PostToolUse: what one Edit does."""
        self.event("PreToolUse", "Edit", name, extra_env=extra_env)
        self.write(name, text)
        return self.event("PostToolUse", "Edit", name, extra_env=extra_env)

    def calls(self):
        return [l.rstrip("\n") for l in open(self.log)]

    def done(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def t_new_errors_are_shown_once_then_blocked_at_stop():
    r = Run()
    r.write("a.ts", "x\nERROR 2322 old error\n")
    r.event("UserPromptSubmit")
    a, _ = r.edit("a.ts", "x\nERROR 2322 old error\nERROR 2304 Cannot find name 'y'.\nWARN 6133 unused\n")
    check(a == {"effect": "inject", "dispatchId": "d3",
                "text": HEAD_EDIT + "\na.ts:3:1 TS2304 Cannot find name 'y'."}, a)
    # The same error again: already reported this turn.
    a, _ = r.edit("a.ts", "x\nERROR 2322 old error\nERROR 2304 Cannot find name 'y'.\n")
    check(a["effect"] == "noop", a)
    a, _ = r.event("Stop")
    check(a["effect"] == "decide" and a["verdict"] == "deny"
          and a["reason"] == HEAD_STOP + "\na.ts:3:1 TS2304 Cannot find name 'y'.", a)
    # At most one block per turn.
    a, _ = r.event("Stop", stop_hook_active=True)
    check(a["effect"] == "noop", a)
    r.done()


def t_a_fixed_error_passes_stop():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    r.edit("a.ts", "ERROR 2304 broken\n")
    a, _ = r.edit("a.ts", "fixed\n")
    check(a["effect"] == "noop", a)
    a, _ = r.event("Stop")
    check(a["effect"] == "noop", a)
    r.done()


def t_a_new_file_has_an_empty_baseline():
    r = Run()
    r.event("UserPromptSubmit")
    r.event("PreToolUse", "Write", "src/new.ts")
    check(r.calls() == [], "a file that doesn't exist needs no check: %r" % r.calls())
    r.write("src/new.ts", "ERROR 2551 multi\\nline message\n")
    a, _ = r.event("PostToolUse", "Write", "src/new.ts")
    check(a.get("text") == HEAD_EDIT + "\nsrc/new.ts:1:1 TS2551 multi line message", a)
    r.done()


def t_a_new_file_in_a_new_directory_through_a_linked_root():
    """macOS CI found it: the root resolves to its real path, so a new file
    in a directory that doesn't exist yet must resolve the same way, or its
    baseline lands under another key and its errors are never reported."""
    r = Run(via_link=True)
    r.event("UserPromptSubmit")
    r.event("PreToolUse", "Write", "deep/er/new.ts")
    r.write("deep/er/new.ts", "ERROR 2304 broken\n")
    a, _ = r.event("PostToolUse", "Write", "deep/er/new.ts")
    check(a.get("text") == HEAD_EDIT + "\ndeep/er/new.ts:1:1 TS2304 broken", a)
    a, _ = r.event("Stop")
    check(a["effect"] == "decide", a)
    r.done()


def t_a_path_with_escapes_reaches_pharos_intact():
    """#16: a path holding a space, `#`, a valid-looking escape (`%25`) and
    `\u00e9` goes to `pharos diagnostics` as the path itself (the CLI
    escapes it for the daemon), and its error is reported under it."""
    rel = "a b#c%25d-\u00e9/x.ts"
    r = Run()
    r.write(rel, "x\n")
    r.event("UserPromptSubmit")
    a, _ = r.edit(rel, "x\nERROR 2304 broken\n")
    check(a.get("text") == HEAD_EDIT + "\n" + rel + ":2:1 TS2304 broken", a)
    with open(r.log) as fh:
        calls = fh.read().splitlines()
    check(any(c.split(" ", 1)[0] == rel or c == rel for c in calls), calls)
    r.done()

def t_unsure_is_silent_and_logged():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    a, err = r.edit("a.ts", "ERROR 2304 broken\nUNSURE\n")
    check(a["effect"] == "noop", a)
    check("trial.unsure reason=unsure event=PostToolUse" in err.splitlines(), err)
    a, err = r.event("Stop")
    check(a["effect"] == "noop" and "trial.unsure reason=unsure event=Stop" in err.splitlines(), (a, err))
    r.done()


def t_an_unsure_baseline_means_no_reports():
    r = Run()
    r.write("a.ts", "UNSURE\n")
    r.event("UserPromptSubmit")
    _, err = r.event("PreToolUse", "Edit", "a.ts")
    check("trial.unsure reason=unsure event=baseline" in err.splitlines(), err)
    r.write("a.ts", "ERROR 2304 broken\n")
    a, err = r.event("PostToolUse", "Edit", "a.ts")
    check(a["effect"] == "noop" and "trial.unsure reason=no-baseline event=PostToolUse" in err.splitlines(),
          (a, err))
    r.done()


def t_an_answer_without_a_project_is_unsure_not_out_of_scope():
    """Review finding: projectInfo is best-effort. A baseline without a
    project must be unknown, or the next check, which names the project,
    reports the file's old errors as new."""
    r = Run()
    r.write("a.ts", "ERROR 2304 old error\nNOPROJECT\n")
    r.event("UserPromptSubmit")
    _, err = r.event("PreToolUse", "Edit", "a.ts")
    check("trial.unsure reason=unsure event=baseline" in err.splitlines(), err)
    r.write("a.ts", "ERROR 2304 old error\n")
    a, err = r.event("PostToolUse", "Edit", "a.ts")
    check(a["effect"] == "noop" and "trial.unsure reason=no-baseline event=PostToolUse" in err.splitlines(),
          (a, err))
    a, _ = r.event("Stop")
    check(a["effect"] == "noop", a)
    # And a later check without a project says nothing, logged.
    r.event("UserPromptSubmit")
    r.event("PreToolUse", "Edit", "a.ts")
    r.write("a.ts", "ERROR 2304 old error\nERROR 2552 new one\nNOPROJECT\n")
    a, err = r.event("PostToolUse", "Edit", "a.ts")
    check(a["effect"] == "noop" and "trial.unsure reason=unsure event=PostToolUse" in err.splitlines(),
          (a, err))
    r.done()


def t_a_touched_non_typescript_file_is_never_asked_about():
    """Contract amendment (arm 3's scope is the program's TypeScript files):
    a touched JSON file means no call to pharos (no cold JSON server) and no
    log line, at PostToolUse and at Stop."""
    r = Run()
    r.write("config/settings.json", "{}\n")
    r.event("UserPromptSubmit")
    a, err = r.edit("config/settings.json", '{"ERROR 2304 broken": 1}\n')
    check(a["effect"] == "noop" and "trial.unsure" not in err, (a, err))
    a, err = r.event("Stop")
    check(a["effect"] == "noop" and "trial.unsure" not in err, (a, err))
    check(r.calls() == [], "pharos was asked about a JSON file: %r" % r.calls())
    # A TypeScript file in the same turn is still checked.
    r.write("a.ts", "x\n")
    a, _ = r.edit("a.ts", "ERROR 2304 broken\n")
    check(a.get("text") == HEAD_EDIT + "\na.ts:1:1 TS2304 broken", a)
    check(all(c == "a.ts" for c in r.calls()), r.calls())
    r.done()


def t_out_of_scope_files_are_skipped_silently():
    r = Run()
    r.write("other/b.ts", "x\n")
    r.event("UserPromptSubmit")
    a, err = r.edit("other/b.ts", "ERROR 2304 broken\n")
    check(a["effect"] == "noop" and "trial.unsure" not in err, (a, err))
    a, err = r.event("Stop")
    check(a["effect"] == "noop" and "trial.unsure" not in err, (a, err))
    r.done()


def t_the_cap_shows_ten_then_counts_the_rest():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    a, _ = r.edit("a.ts", "".join("ERROR %d e%02d\n" % (2300 + i, i) for i in range(12)))
    lines = a["text"].split("\n")
    check(lines[0] == HEAD_EDIT and len(lines) == 12 and lines[-1] == "…and 2 more.", lines)
    # The two past the cap weren't shown, so they're reported on the next write.
    a, _ = r.edit("a.ts", "".join("ERROR %d e%02d\n" % (2300 + i, i) for i in range(12)) + "\n")
    check(a.get("text", "").split("\n")[1:] == ["a.ts:11:1 TS2310 e10", "a.ts:12:1 TS2311 e11"], a)
    r.done()


def t_stop_reuses_the_last_check_until_a_tool_call():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    r.edit("a.ts", "ERROR 2304 broken\n")
    before = len(r.calls())
    r.event("Stop")
    check(len(r.calls()) == before, "Stop should reuse the PostToolUse check: %r" % r.calls())
    r.event("Stop", stop_hook_active=True)

    # A Bash call in between moves the generation: Stop checks again.
    r.event("UserPromptSubmit")
    r.edit("a.ts", "ERROR 2304 broken\nERROR 2552 again\n")
    r.event("PreToolUse", "Bash", tool_input={"command": "ls"})
    before = len(r.calls())
    r.event("Stop")
    check(len(r.calls()) == before + 1, "Stop after a Bash call must check fresh: %r" % r.calls())
    r.done()


def t_a_subagent_call_moves_the_generation():
    # Claude Code 2.1 names the subagent tool Agent; older versions, Task.
    # Either may change files the hook doesn't see, so Stop checks fresh.
    for tool in ("Agent", "Task"):
        r = Run()
        r.write("a.ts", "x\n")
        r.event("UserPromptSubmit")
        r.edit("a.ts", "ERROR 2304 broken\n")
        r.event("PreToolUse", tool, tool_input={"description": "d", "prompt": "p"})
        before = len(r.calls())
        r.event("Stop")
        check(len(r.calls()) == before + 1, "Stop after an %s call must check fresh: %r" % (tool, r.calls()))
        r.done()


def t_a_baseline_never_reuses_a_check_from_a_writers_pretooluse():
    r = Run()
    r.write("a.ts", "x\n")
    r.write("b.ts", "y\n")
    r.event("UserPromptSubmit")
    r.event("PreToolUse", "Edit", "a.ts")     # baseline check of a.ts: never kept
    r.write("a.ts", "x\n")
    r.event("PreToolUse", "Edit", "b.ts")     # b.ts's baseline: its own check
    check(r.calls() == ["a.ts", "b.ts"], r.calls())
    r.done()


def t_background_bash_makes_every_check_fresh():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    r.event("PreToolUse", "Bash", tool_input={"command": "npm test", "run_in_background": True})
    r.edit("a.ts", "ERROR 2304 broken\n")
    before = len(r.calls())
    r.event("Stop")
    check(len(r.calls()) == before + 1, "after a background Bash, Stop checks fresh: %r" % r.calls())
    r.done()


def t_a_pharos_failure_is_silent():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    a, err = r.edit("a.ts", "ERROR 2304 broken\n", extra_env={"FAKE_PHAROS_FAIL": "1"})
    check(a["effect"] == "noop", a)
    check("trial.unsure reason=failed event=baseline" in err.splitlines()
          or "trial.unsure reason=failed event=PostToolUse" in err.splitlines(), err)
    r.done()


def t_a_new_turn_forgets_the_last():
    r = Run()
    r.write("a.ts", "x\n")
    r.event("UserPromptSubmit")
    r.edit("a.ts", "ERROR 2304 broken\n")
    r.event("UserPromptSubmit")              # the agent's error is now the baseline
    a, _ = r.edit("a.ts", "ERROR 2304 broken\n// more\n")
    check(a["effect"] == "noop", a)
    a, _ = r.event("Stop")
    check(a["effect"] == "noop", a)
    r.done()


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("t_")]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("FAIL", name, "::", e)
            print("  the hook's stderr on its last event:\n    " + LAST["stderr"].replace("\n", "\n    "))
    print("%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
