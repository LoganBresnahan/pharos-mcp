#!/usr/bin/env python3
"""Drive an installed pharos the way an MCP client does (ADR-035 §7).

    python3 -I rel/smoke_mcp.py --pharos PATH [--direct] [--lsp pyright]
                                [--expect-native] [--idle-exit]

Checks, each printed as `smoke: ok: …` or failing the run:

- MCP initialize and tools/list answer, and every stdout line is JSON;
- with --lsp pyright: a hover on a fixture Python file comes back from
  pyright (`pyright-langserver` must be on PATH);
- unless --direct: a second session joins the same daemon
  (`pharos daemon status` shows both);
- with --expect-native: no node process in the MCP server's process tree
  (the npm postinstall made `pharos` the native shim), checked before
  any language server starts (pyright is itself a node program);
- with --idle-exit: the daemon exits once its sessions are gone
  (PHAROS_DAEMON_IDLE_SECS is set short here, before anything starts).

Without --direct it sets PHAROS_MODE=daemon, so a fallback to direct mode
fails the run instead of hiding a broken daemon.
"""

import argparse
import json
import os
import select
import subprocess
import sys
import tempfile
import time

INIT = {"protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "0"}}


def fail(msg):
    print("smoke: FAIL: " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def ok(msg):
    print("smoke: ok: " + msg, flush=True)


class Session:
    def __init__(self, pharos, env, cwd):
        self.proc = subprocess.Popen([pharos], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, cwd=cwd)
        self.buf = b""

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def call(self, id_, method, params=None, timeout=120):
        msg = {"jsonrpc": "2.0", "id": id_, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        deadline = time.time() + timeout
        while True:
            while b"\n" not in self.buf:
                left = deadline - time.time()
                if left <= 0:
                    fail("no reply to %s within %ds" % (method, timeout))
                ready, _, _ = select.select([self.proc.stdout], [], [], left)
                if ready:
                    chunk = os.read(self.proc.stdout.fileno(), 1 << 20)
                    if not chunk:
                        fail("pharos closed stdout during %s; stderr: %s"
                             % (method, self.proc.stderr.read().decode(errors="replace")))
                    self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            try:
                reply = json.loads(line)
            except ValueError:
                fail("a non-JSON line on stdout: %r" % line[:200])
            if reply.get("id") == id_:
                return reply

    def initialize(self):
        r = self.call(1, "initialize", INIT)
        if "result" not in r:
            fail("initialize failed: %r" % r)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            fail("pharos didn't exit after stdin closed")


def status(pharos, env):
    out = subprocess.run([pharos, "daemon", "status"], env=env, capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return json.loads(out.stdout.splitlines()[0])


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def process_tree(pid):
    """(pid, command) for pid and every descendant."""
    out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "comm="],
                         capture_output=True, text=True).stdout
    rows = [l.split(None, 2) for l in out.splitlines() if l.strip()]
    children = {}
    comm = {}
    for p, pp, c in rows:
        children.setdefault(int(pp), []).append(int(p))
        comm[int(p)] = c
    tree, todo = [], [pid]
    while todo:
        p = todo.pop()
        tree.append((p, comm.get(p, "?")))
        todo.extend(children.get(p, []))
    return tree


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pharos", required=True)
    ap.add_argument("--direct", action="store_true")
    ap.add_argument("--lsp", choices=["pyright"])
    ap.add_argument("--expect-native", action="store_true")
    ap.add_argument("--idle-exit", action="store_true")
    args = ap.parse_args()

    env = dict(os.environ)
    if args.direct:
        env["PHAROS_MODE"] = "direct"
    else:
        env["PHAROS_MODE"] = "daemon"
    if args.idle_exit:
        env["PHAROS_DAEMON_IDLE_SECS"] = "5"

    work = tempfile.mkdtemp(prefix="pharos-smoke-")
    with open(os.path.join(work, "pyproject.toml"), "w") as f:
        f.write('[project]\nname = "smoke"\nversion = "0"\n')
    with open(os.path.join(work, "main.py"), "w") as f:
        f.write("def greet(name: str) -> str:\n    return 'hi ' + name\n\n\ngreet('pharos')\n")

    a = Session(args.pharos, env, work)
    info = a.initialize()["result"]["serverInfo"]
    ok("initialize: %s %s" % (info["name"], info["version"]))
    tools = a.call(2, "tools/list")["result"]["tools"]
    if not tools:
        fail("tools/list is empty")
    ok("tools/list: %d tools" % len(tools))

    if args.expect_native:
        tree = process_tree(a.proc.pid)
        nodes = [t for t in tree if "node" in os.path.basename(t[1])]
        if nodes:
            fail("node in the MCP server's process tree: %r" % tree)
        ok("no node in the process tree: %s" % ", ".join("%s" % c for _, c in tree))

    if args.lsp == "pyright":
        uri = "file://" + os.path.join(os.path.realpath(work), "main.py")
        r = a.call(3, "tools/call", {"name": "hover", "arguments": {
            "uri": uri, "line": 4, "character": 1}}, timeout=180)
        text = json.dumps(r.get("result", r))
        if "greet" not in text or "str" not in text:
            fail("pyright hover didn't describe greet: %s" % text[:400])
        ok("pyright answered a hover through pharos")

    if not args.direct:
        b = Session(args.pharos, env, work)
        b.initialize()
        st = status(args.pharos, env)
        if st is None or len(st["sessions"]) != 2:
            fail("a second session didn't join the daemon: %r" % st)
        ok("a second session joined daemon %d (%d sessions)" % (st["daemon_pid"], len(st["sessions"])))
        daemon_pid = st["daemon_pid"]
        b.close()
    a.close()
    ok("sessions closed cleanly")

    if args.idle_exit:
        deadline = time.time() + 40
        while time.time() < deadline and alive(daemon_pid):
            time.sleep(0.5)
        if alive(daemon_pid):
            fail("the daemon (pid %d) was still running 40 s after its last session" % daemon_pid)
        if status(args.pharos, env) is not None:
            fail("`pharos daemon status` still finds a daemon")
        ok("the daemon exited when idle")


if __name__ == "__main__":
    main()
