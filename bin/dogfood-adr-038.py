#!/usr/bin/env python3
"""ADR-038 dogfood harness: documents follow the disk, against real
rust-analyzer, pyright + ruff, typescript-language-server and gopls.

The gleeunit suite covers the planning (what each document needs sent)
and the stamp bookkeeping, and test/daemon/integration.py drives the
whole path against bin/_stub_lsp.py. Neither can show that a real
server answers about the text on disk after pharos re-syncs it. This
harness does: it edits files on disk between questions and checks that
the answers follow.

Usage:
    mix release.dev                                   # build first
    python3 -I bin/dogfood-adr-038.py <scratch-dir>   # all four
    python3 -I bin/dogfood-adr-038.py <scratch-dir> go,ts
    python3 -I bin/dogfood-adr-038.py <scratch-dir> --shim path/to/bin/pharos

<scratch-dir> holds everything a run creates: the fixtures (ra/, py/,
ts/, go/), the private daemon's runtime dir (rt/) and its logs
(state/pharos/log/). Each run deletes and rewrites the fixture dirs
inside it, so the script only takes a new or empty directory, or one it
made before (it leaves a .dogfood-adr-038 marker).

The run starts its own daemon (PHAROS_MODE=daemon,
PHAROS_RUNTIME_DIR=<scratch-dir>/rt) and stops only that one at the
end, so it never touches the daemon your MCP clients use. Don't clean
up with `pharos daemon stop --all`: that drops pharos in every session
on the machine.

The servers are whatever is first on PATH; the run prints their
versions first. rust-analyzer's cold-open check waits out a 120 s
timeout (see R1 below), and pyright and gopls take about a minute each
to start, so a full run takes about six minutes.

Exit codes: 0 every check passed, 1 a check failed, 2 setup failure.

Checks (PASS/FAIL):
    rust    comment-only edit keeps the error, well under 20 s
    rust    fixing the error clears it
    rust    reintroducing the error shows it
    rust    lib.rs sees b.rs's new signature (E0061)
    rust    hover in lib.rs shows b.rs's new signature
    rust    shared daemon: session A hovers in a loop while session B
            edits; A never sees -32801 ContentModified
    python  diagnostics follow the save (the #3 repro)
    python  hover on a line that only exists in the new text
    python  comment-only edit: both servers report (no
            pharos.not_reported)
    ts      comment-only edit keeps the error
    ts      a.ts sees b.ts's new signature (TS2554)
    ts      a deleted file asked about: hover no longer describes it
    ts      a deleted file asked about: no diagnostics from its old text
    go      after another file is opened, an unchanged file is answered
            unmarked once the settle window has passed, and at once
            after that (review finding F2)
    go      the same after a change in another package (F2)
    go      a.go sees b.go's new signature

OBSERVE rows print without asserting:
    R1/R1b  rust-analyzer's cold open. pharos-mcp#8: no diagnostics
            arrive until the first re-sync's didSave starts cargo check.
            When #8 is fixed, R1 should answer quickly, with
            rust-analyzer's own diagnostics.
    every diagnostics line says whether the answer was fresh or
    carried over (pharos.carried_over).
    python and go: a deleted file asked about. pyright and gopls don't
            watch the disk (pharos-mcp#10), so they may still answer from
            what they read before.

What the checks don't prove (doc/dogfood-adr-038.md has the detail):
    - The carried-over path on a real server. On these fixtures every
      answer comes back fresh (the go checks assert only that it is
      unmarked once the settle window has passed). Only the stub
      scenarios resync_unchanged_diagnostics and
      resync_settles_after_window in test/daemon/integration.py run it.
    - On rust-analyzer, E0061 comes from cargo check, which reads the
      disk whatever rust-analyzer holds in memory. There the hover
      check is the evidence that other open documents re-sync.
      TS2554 does prove it for TypeScript: tsserver answers from its
      in-memory program.
"""
from __future__ import annotations

import argparse
import json
import os
import select
import shutil
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARKER = ".dogfood-adr-038"

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("root", help="scratch directory for fixtures, runtime dir and logs")
parser.add_argument("only", nargs="?", default="rust,python,ts,go",
                    help="comma-separated subset of rust,python,ts,go")
parser.add_argument("--shim", default=os.path.join(REPO, "_build/prod/rel/pharos/bin/pharos"),
                    help="the pharos binary to run (default: this checkout's release)")
args = parser.parse_args()

ROOT = os.path.abspath(args.root)
ONLY = set(args.only.split(","))
SHIM = args.shim
RT = os.path.join(ROOT, "rt")
ENV = {k: v for k, v in os.environ.items() if not k.startswith("PHAROS_")}
ENV.update({"PHAROS_MODE": "daemon", "PHAROS_RUNTIME_DIR": RT,
            "XDG_STATE_HOME": os.path.join(ROOT, "state"), "PHAROS_DAEMON_SYSTEMD": "0"})


def setup_failure(message):
    print("setup: " + message, file=sys.stderr)
    sys.exit(2)


def setup():
    # Every check before anything is created, so a failed setup leaves
    # no marked directory behind.
    unknown = ONLY - {"rust", "python", "ts", "go"}
    if unknown:
        setup_failure("unknown section(s) %s" % ",".join(sorted(unknown)))
    if not os.access(SHIM, os.X_OK):
        setup_failure("no pharos binary at %s (run `mix release.dev`, or pass --shim)" % SHIM)
    if os.path.isdir(ROOT) and os.listdir(ROOT) and not os.path.exists(os.path.join(ROOT, MARKER)):
        setup_failure("%s is not empty and was not made by this script; "
                      "use a new or empty directory" % ROOT)
    try:
        os.makedirs(ROOT, exist_ok=True)
        open(os.path.join(ROOT, MARKER), "w").close()
    except OSError as e:
        setup_failure("can't use %s as the scratch directory: %s" % (ROOT, e))


def versions():
    for cmd in (["rust-analyzer", "--version"], ["cargo", "--version"],
                ["pyright", "--version"], ["ruff", "--version"],
                ["typescript-language-server", "--version"], ["tsc", "--version"],
                ["node", "--version"], ["gopls", "version"], ["go", "version"]):
        path = shutil.which(cmd[0])
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip()
            out = out.splitlines()[0] if out else "?"
        except Exception as e:
            out = "unavailable (%s)" % e.__class__.__name__
        print("   %-28s %s  [%s]" % (cmd[0], out, path or "not on PATH"), flush=True)


class Session:
    def __init__(self, cwd):
        self.p = subprocess.Popen([SHIM], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=ENV, cwd=cwd)
        self.buf = b""
        self.lock = threading.Lock()
        self.nid = 100
        r = self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "dogfood-adr-038", "version": "0"}}, 120)
        if "result" not in r:
            raise RuntimeError("initialize failed: %s" % json.dumps(r)[:300])

    def call(self, method, params, timeout):
        with self.lock:
            self.nid += 1
            rid = self.nid
            frame = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
            self.p.stdin.write((json.dumps(frame) + "\n").encode())
            self.p.stdin.flush()
            deadline = time.time() + timeout
            while True:
                while b"\n" not in self.buf:
                    left = deadline - time.time()
                    if left <= 0:
                        return {"error": "client timeout"}
                    r, _, _ = select.select([self.p.stdout], [], [], left)
                    if r:
                        chunk = os.read(self.p.stdout.fileno(), 1 << 20)
                        if not chunk:
                            return {"error": "EOF"}
                        self.buf += chunk
                line, self.buf = self.buf.split(b"\n", 1)
                # stdout must carry JSON-RPC only (invariant 1); a stray
                # line fails loudly here.
                msg = json.loads(line)
                if msg.get("id") == rid:
                    return msg

    def tool(self, name, arguments, timeout=180):
        t0 = time.time()
        r = self.call("tools/call", {"name": name, "arguments": arguments}, timeout)
        dt = time.time() - t0
        try:
            text = r["result"]["content"][0]["text"]
        except Exception:
            text = json.dumps(r)
        return text, dt

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(10)
        except Exception:
            self.p.kill()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def diag_messages(text):
    try:
        d = json.loads(text)
    except Exception:
        return None, text[:200]
    items = d.get("params", {}).get("diagnostics", [])
    note = d.get("pharos")
    return [(i.get("source"), i.get("code"), i.get("message", "").splitlines()[0][:90])
            for i in items], note


results = []


def record(name, ok, detail):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + " :: " + detail, flush=True)


def show(label, text, dt):
    msgs, note = diag_messages(text)
    if msgs is None:
        freshness = "no answer"
    elif isinstance(note, dict) and note.get("carried_over"):
        freshness = "carried over"
    else:
        freshness = "fresh"
    print("   %-34s %6.2fs %-12s %s%s" % (
        label, dt, freshness, msgs,
        ("  pharos=" + json.dumps(note)[:160]) if note else ""), flush=True)
    return msgs, note


def print_caps(s, language):
    """Each server's textDocumentSync and diagnosticProvider, as pharos
    recorded them from `initialize`."""
    text, _ = s.tool("runtime_server_capabilities", {})
    try:
        d = json.loads(text)
    except Exception:
        print("   caps(%s): %s" % (language, text[:300]), flush=True)
        return
    out = []

    def walk(x):
        if isinstance(x, dict):
            c = x.get("capabilities")
            if isinstance(c, dict) and x.get("language") == language:
                out.append({"server_id": x.get("server_id"),
                            "textDocumentSync": c.get("textDocumentSync"),
                            "diagnosticProvider": c.get("diagnosticProvider")})
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(d)
    for row in out or [text[:300]]:
        print("   caps(%s): %s" % (language, json.dumps(row)), flush=True)


# ------------------------------------------------------------------ rust
def rust():
    fx = os.path.join(ROOT, "ra")
    shutil.rmtree(fx, ignore_errors=True)
    write(fx + "/Cargo.toml", '[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n')
    write(fx + "/src/b.rs", "pub fn helper(x: i32) -> i32 {\n    x + 1\n}\n")
    lib = fx + "/src/lib.rs"
    body = "mod b;\n\npub fn a() -> i32 {\n    b::helper(1)\n}\n\npub fn broken() -> i32 {\n    %s\n}\n"
    write(lib, body % '"s"')
    u_lib = "file://" + lib
    u_b = "file://" + fx + "/src/b.rs"
    has_err = lambda m: m and any("mismatch" in (x[2] or "").lower() or x[1] in ("E0308", "type-mismatch") for x in m)
    argc = lambda m: m and any("argument" in (x[2] or "").lower() or x[1] in ("E0061", "mismatched-arg-count") for x in m)

    s = Session(fx)
    # OBSERVE (#8): a never-edited file. Nothing has been saved, so
    # cargo check hasn't run, and rust-analyzer's own diagnostics go
    # by pull, which pharos doesn't ask a Push-mode server for.
    t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 120000}, 200)
    show("R1 OBSERVE cold open (#8)", t, dt)
    print_caps(s, "rust")
    time.sleep(8)
    t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
    show("R1b OBSERVE asked again (#8)", t, dt)

    write(lib, open(lib).read() + "// a comment\n")
    t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
    m2, _ = show("R2 comment-only edit", t, dt)
    record("rust: comment-only edit keeps the error, well under 20 s", bool(has_err(m2)) and dt < 10, "%.2fs" % dt)

    write(lib, body % "1")
    time.sleep(1)
    t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
    m3, _ = show("R3 error fixed", t, dt)
    if has_err(m3):
        time.sleep(6)
        t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
        m3, _ = show("R3 asked again", t, dt)
    record("rust: fixing the error clears it", m3 is not None and not has_err(m3), str(m3))

    write(lib, body % '"back"')
    time.sleep(1)
    t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
    m4, _ = show("R3b error reintroduced", t, dt)
    if not has_err(m4):
        time.sleep(6)
        t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
        m4, _ = show("R3b asked again", t, dt)
    record("rust: reintroducing the error shows it", bool(has_err(m4)), str(m4))

    # b.rs is opened by the hover, then changed on disk; the questions
    # are about lib.rs, so b.rs re-syncs as another open document.
    h, _ = s.tool("hover", {"uri": u_b, "line": 0, "character": 8})
    print("   hover b.rs before:", h[:120].replace("\n", " "), flush=True)
    write(fx + "/src/b.rs", "pub fn helper(x: i32, y: i32) -> i32 {\n    x + y\n}\n")
    time.sleep(1)
    t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
    m5, _ = show("R4 b.rs signature changed", t, dt)
    if not argc(m5):
        time.sleep(6)
        t, dt = s.tool("get_diagnostics", {"uri": u_lib, "timeout_ms": 20000})
        m5, _ = show("R4 asked again", t, dt)
    record("rust: lib.rs sees b.rs's new signature (E0061, via cargo check)", bool(argc(m5)), str(m5))
    h, _ = s.tool("hover", {"uri": u_lib, "line": 3, "character": 8})
    record("rust: hover in lib.rs shows b.rs's new signature", "y: i32" in h, h[:160].replace("\n", " "))

    # Shared daemon (ADR-034): a second session hovers lib.rs in a loop
    # while the first edits b.rs and asks about it.
    a2 = Session(fx)
    errors = []
    stop = [False]

    took = []

    def loop():
        while not stop[0]:
            txt, dt = a2.tool("hover", {"uri": u_lib, "line": 3, "character": 8}, 60)
            took.append(dt)
            if "32801" in txt or "content modified" in txt.lower() or '"error"' in txt[:20]:
                errors.append(txt[:200])
        errors.append("hovers=%d" % len(took))

    th = threading.Thread(target=loop)
    th.start()
    for i in range(6):
        write(fx + "/src/b.rs", "pub fn helper(x: i32, y: i32) -> i32 {\n    x + y + %d\n}\n" % i)
        s.tool("get_diagnostics", {"uri": u_b, "timeout_ms": 10000})
        time.sleep(0.3)
    stop[0] = True
    th.join()
    # A hover that lands while rust-analyzer re-analyses gets -32801 and
    # is retried after 1 s (session.request_with_content_modified_retry),
    # so slow hovers count the retries the agent never saw.
    took.sort()
    if took:
        print("   OBSERVE shared-daemon hovers: n=%d median=%.3fs max=%.2fs over_0.5s=%d" % (
            len(took), took[len(took) // 2], took[-1], sum(1 for t in took if t > 0.5)), flush=True)
    record("rust: shared daemon, A never surfaces -32801 while B edits", len(errors) == 1, str(errors))
    a2.close()
    s.close()


# ---------------------------------------------------------------- python
def python():
    fx = os.path.join(ROOT, "py")
    shutil.rmtree(fx, ignore_errors=True)
    write(fx + "/pyproject.toml", '[project]\nname = "fx"\nversion = "0"\n')
    a = fx + "/a.py"
    write(a, "def f() -> int:\n    return 1\n")
    u = "file://" + a
    s = Session(fx)
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 60000}, 120)
    show("P1 clean file, cold start", t, dt)
    print_caps(s, "python")

    write(a, 'def f() -> int:\n    return "not an int"\n\nundefined_name\n')
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 30000})
    m2, _ = show("P2 saved with errors", t, dt)
    record("python: #3 repro, diagnostics follow the save",
           bool(m2) and any("undefined" in (x[2] or "").lower() for x in m2), str(m2))
    h, _ = s.tool("hover", {"uri": u, "line": 3, "character": 2})
    record("python: hover on a line that only exists in the new text",
           h.strip() not in ("null", "") and "undefined_name" in h, h[:120].replace("\n", " "))

    write(a, 'def f() -> int:\n    return "not an int"\n\nundefined_name\n# comment\n')
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 30000})
    m3, n3 = show("P3 comment-only edit", t, dt)
    record("python merge: comment-only edit, both servers report",
           bool(m3) and not (n3 or {}).get("not_reported"), str(n3))

    os.remove(a)
    h, _ = s.tool("hover", {"uri": u, "line": 3, "character": 2})
    print("   P4 OBSERVE deleted, hover:", h[:140].replace("\n", " "), flush=True)
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 5000})
    show("P4 OBSERVE deleted, diagnostics", t, dt)
    s.close()


# -------------------------------------------------------------------- ts
def ts():
    fx = os.path.join(ROOT, "ts")
    shutil.rmtree(fx, ignore_errors=True)
    write(fx + "/package.json", '{"name":"fx","version":"0.0.0"}\n')
    write(fx + "/tsconfig.json",
          '{"compilerOptions":{"strict":true,"target":"es2020","module":"commonjs"},"include":["*.ts"]}\n')
    write(fx + "/b.ts", "export function helper(x: number): number { return x + 1 }\n")
    a = fx + "/a.ts"
    write(a, 'import { helper } from "./b"\nexport const v: number = helper(1)\nexport const bad: number = "s"\n')
    u = "file://" + a
    ub = "file://" + fx + "/b.ts"
    s = Session(fx)
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 60000}, 120)
    show("T1 known error", t, dt)
    print_caps(s, "typescript")

    write(a, open(a).read() + "// c\n")
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 20000})
    m2, _ = show("T2 comment-only edit", t, dt)
    record("ts: comment-only edit keeps the error", bool(m2) and dt < 10, "%.2fs %s" % (dt, m2))

    # b.ts is opened by the hover, then changed on disk; the question
    # is about a.ts, so b.ts re-syncs as another open document.
    s.tool("hover", {"uri": ub, "line": 0, "character": 17})
    write(fx + "/b.ts", "export function helper(x: number, y: number): number { return x + y }\n")
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 20000})
    m3, _ = show("T3 b.ts signature changed", t, dt)
    record("ts: a.ts sees b.ts's new signature (TS2554)",
           bool(m3) and any("argument" in (x[2] or "").lower() for x in m3), str(m3))

    # a.ts is deleted: pharos closes it and serves nothing about its old
    # text; tsserver watches the disk, so it drops the file too.
    os.remove(a)
    h, _ = s.tool("hover", {"uri": u, "line": 2, "character": 14})
    record("ts: a deleted file asked about, hover no longer describes it",
           "bad" not in h, h[:160].replace("\n", " "))
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 5000})
    m4, _ = show("T4 a.ts deleted", t, dt)
    record("ts: a deleted file asked about, no diagnostics from its old text",
           not m4 or not any(x[1] in (2322, 2554) for x in m4), "%.2fs %s" % (dt, m4))
    s.close()


# -------------------------------------------------------------------- go
def go():
    fx = os.path.join(ROOT, "go")
    shutil.rmtree(fx, ignore_errors=True)
    write(fx + "/go.mod", "module fx\n\ngo 1.21\n")
    write(fx + "/b/b.go", "package b\n\nfunc Helper(x int) int { return x + 1 }\n")
    write(fx + "/c/c.go", "package c\n\nfunc C() int { return 3 }\n")
    a = fx + "/a/a.go"
    write(a, 'package a\n\nimport "fx/b"\n\nfunc A() int {\n\tunused := 1\n\treturn b.Helper(1)\n}\n')
    u = "file://" + a
    uc = "file://" + fx + "/c/c.go"
    ub = "file://" + fx + "/b/b.go"
    unused = lambda m: m and any("unused" in (x[2] or "").lower() or x[1] == "UnusedVar" for x in m)
    s = Session(fx)
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 60000}, 120)
    m1, _ = show("G1 known error, cold", t, dt)
    print_caps(s, "go")
    if not unused(m1):
        time.sleep(3)
        t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 20000})
        m1, _ = show("G1 asked again", t, dt)

    def settles(what):
        # gopls doesn't re-publish a.go (its diagnostics didn't change):
        # the first question waits out what is left of the window, the
        # next is immediate; neither is marked.
        t, dt1 = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 20000})
        m, n1 = show("   %s, first" % what, t, dt1)
        t, dt2 = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 20000})
        m2, n2 = show("   %s, again" % what, t, dt2)
        ok = (unused(m) and unused(m2) and not (n1 or {}).get("carried_over")
              and not (n2 or {}).get("carried_over") and dt1 < 3 and dt2 < 0.5)
        record("go: after %s, the unchanged file is answered unmarked, at once the second time" % what,
               bool(ok), "first %.2fs, again %.2fs" % (dt1, dt2))

    s.tool("hover", {"uri": uc, "line": 2, "character": 5})
    settles("another file opened")
    write(fx + "/c/c.go", "package c\n\n// changed\nfunc C() int { return 4 }\n")
    settles("a change in another package")

    s.tool("hover", {"uri": ub, "line": 2, "character": 5})
    write(fx + "/b/b.go", "package b\n\nfunc Helper(x, y int) int { return x + y }\n")
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 20000})
    m3, _ = show("G3 b.go signature changed", t, dt)
    record("go: a.go sees b.go's new signature",
           bool(m3) and any("argument" in (x[2] or "").lower() for x in m3), str(m3))

    os.remove(a)
    h, _ = s.tool("hover", {"uri": u, "line": 6, "character": 10})
    print("   G4 OBSERVE deleted, hover:", h[:140].replace("\n", " "), flush=True)
    t, dt = s.tool("get_diagnostics", {"uri": u, "timeout_ms": 5000})
    show("G4 OBSERVE deleted, diagnostics", t, dt)
    s.close()


def main():
    setup()
    print("==== versions (first on PATH)", flush=True)
    versions()
    try:
        for name, fn in (("rust", rust), ("python", python), ("ts", ts), ("go", go)):
            if name not in ONLY:
                continue
            print("==== " + name, flush=True)
            try:
                fn()
            except Exception as e:
                import traceback
                traceback.print_exc()
                record(name + ": crashed", False, repr(e))
    finally:
        # Only the private daemon under ROOT/rt.
        subprocess.run([SHIM, "daemon", "stop"], env=ENV, capture_output=True, timeout=30)
    passed = sum(1 for r in results if r[1])
    failed = len(results) - passed
    print("\n%d passed, %d failed  (logs: %s)" % (passed, failed, os.path.join(ROOT, "state/pharos/log")))
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
