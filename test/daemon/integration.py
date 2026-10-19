#!/usr/bin/env python3
"""ADR-034 daemon + shim integration tests.

Drives the real `pharos` shim against an assembled release, with the
stub LSP (bin/_stub_lsp.py) standing in for a language server, and
everything else sandboxed: each scenario gets its own runtime dir (so
its own daemon), state dir and config dir under one short temp root.

    python3 -I test/daemon/integration.py --release _build/prod/rel/pharos \\
        --shim shim/target/release/pharos [--only name,name]

Every scenario also asserts sacred invariant 1: every line any shim
writes to stdout parses as JSON. Exit status is the number of failed
scenarios.
"""

import argparse
import json
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
STUB = os.path.join(REPO, "bin", "_stub_lsp.py")
SECRET = "pharos-test-secret-%d" % os.getpid()

# A scenario that runs past this fails with its name instead of hanging the
# job (a pipe deadlock on macOS once burned a runner's 90 minutes).
SCENARIO_TIMEOUT_SECS = 90

INIT_PARAMS = {"protocolVersion": "2024-11-05", "capabilities": {},
               "clientInfo": {"name": "integration", "version": "0"}}


class Failure(Exception):
    pass


def check(cond, message):
    if not cond:
        raise Failure(message)


def wait_until(pred, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.05)
    raise Failure("timed out after %.0fs waiting for %s" % (timeout, what))


class Sandbox:
    """One scenario's dirs and env."""

    def __init__(self, root, name, release, shim, extra_env):
        self.dir = os.path.join(root, name)
        self.rt = os.path.join(self.dir, "rt")
        self.state = os.path.join(self.dir, "st")
        self.fixture = os.path.join(self.dir, "fx")
        self.release = release
        self.shim = shim
        for d in (self.state, self.fixture, os.path.join(self.dir, "cfg")):
            os.makedirs(d)
        open(os.path.join(self.fixture, "stub.root"), "w").close()
        with open(os.path.join(self.fixture, "main.stub"), "w") as f:
            f.write("hello\n")
        self.write_toml("")
        self.env = dict(os.environ)
        for name in list(self.env):
            if name.startswith(("PHAROS_", "STUB_LSP_")):
                del self.env[name]
        self.env.update({
            "PHAROS_RELEASE_ROOT": release,
            "PHAROS_RUNTIME_DIR": self.rt,
            "XDG_STATE_HOME": self.state,
            "XDG_CONFIG_HOME": os.path.join(self.dir, "cfg"),
            "PHAROS_MODE": "daemon",
            "STUB_LSP_LOG": os.path.join(self.fixture, "stub.log"),
            "PHAROS_TEST_SECRET": SECRET,
        })
        self.env.update(extra_env)
        self.shims = []

    def write_toml(self, extra):
        with open(os.path.join(self.fixture, ".pharos.toml"), "w") as f:
            f.write('[languages.stub]\nfile_extensions = [".stub"]\n'
                    'root_markers = ["stub.root"]\ncommand = "%s"\n%s' % (STUB, extra))

    @property
    def uri(self):
        return "file://" + os.path.join(self.fixture, "main.stub")

    def socket_path(self):
        socks = [f for f in os.listdir(self.rt) if f.endswith(".sock")] if os.path.isdir(self.rt) else []
        return os.path.join(self.rt, socks[0]) if len(socks) == 1 else None

    def daemon_pid(self):
        pids = [f for f in os.listdir(self.rt) if f.endswith(".pid")] if os.path.isdir(self.rt) else []
        if len(pids) != 1:
            return None
        try:
            return int(open(os.path.join(self.rt, pids[0])).read().strip())
        except (OSError, ValueError):
            return None

    def start(self, extra_env=None, **popen):
        s = Shim(self, extra_env or {}, **popen)
        self.shims.append(s)
        return s

    def cli(self, *args, extra_env=None, timeout=30):
        env = dict(self.env, **(extra_env or {}))
        return subprocess.run([self.shim, *args], env=env, capture_output=True,
                              text=True, timeout=timeout)

    def status(self):
        out = self.cli("daemon", "status")
        check(out.returncode == 0, "daemon status failed: %s" % out.stderr)
        return json.loads(out.stdout.splitlines()[0])

    def teardown(self):
        for s in self.shims:
            s.kill()
        self.cli("daemon", "stop")
        pid = self.daemon_pid()
        if pid and alive(pid):
            os.kill(pid, signal.SIGKILL)


class Shim:
    """One MCP client session: a shim with pipes on stdin/stdout."""

    def __init__(self, sandbox, extra_env, cwd=None, **popen):
        env = dict(sandbox.env, **extra_env)
        self.proc = subprocess.Popen([sandbox.shim], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env, cwd=cwd or sandbox.fixture, **popen)
        self.buf = b""
        self.lines = []

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def read_line(self, timeout):
        deadline = time.time() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.time()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.proc.stdout], [], [], left)
            if not ready:
                return None
            chunk = os.read(self.proc.stdout.fileno(), 1 << 20)
            if not chunk:
                if self.buf:
                    raise Failure("partial frame on stdout at EOF: %r" % self.buf[:200])
                return "EOF"
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        try:
            msg = json.loads(line)
        except ValueError:
            raise Failure("non-JSON line on stdout: %r" % line[:200])
        self.lines.append(msg)
        return msg

    def call(self, id_, method, params=None, timeout=60):
        msg = {"jsonrpc": "2.0", "id": id_, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        while True:
            r = self.read_line(timeout)
            if r is None or r == "EOF":
                raise Failure("no reply to %s (id %s): %s; stderr: %s"
                              % (method, id_, r, self.stderr_now()))
            if r.get("id") == id_:
                return r

    def initialize(self):
        r = self.call(1, "initialize", INIT_PARAMS)
        check("result" in r, "initialize failed: %r" % r)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r

    def tool(self, id_, name, args, timeout=60):
        r = self.call(id_, "tools/call", {"name": name, "arguments": args}, timeout)
        check("result" in r, "%s failed: %r" % (name, r))
        return r["result"]["content"][0]["text"]

    def close_stdin(self):
        self.proc.stdin.close()

    def drain(self, timeout):
        """Read stdout to EOF (every line must be JSON)."""
        while True:
            r = self.read_line(timeout)
            if r in (None, "EOF"):
                return r

    def stderr_now(self):
        if self.proc.poll() is None:
            return "(running)"
        return self.proc.stderr.read().decode(errors="replace")

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def daemons_for(socket_path):
    """Pids of beam processes serving `socket_path`."""
    out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "args="],
                         capture_output=True, text=True).stdout
    return [int(l.split(None, 1)[0]) for l in out.splitlines()
            if "beam" in l and "--socket " + socket_path in l]


def raw_hello(socket_path, hello):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(socket_path)
    s.sendall((json.dumps(hello) + "\n").encode())
    data = b""
    while b"\n" not in data:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data.split(b"\n")[0])


def hover(shim, sb, id_, timeout=60):
    return shim.tool(id_, "hover", {"uri": sb.uri, "line": 0, "character": 1}, timeout)


# -- Scenarios -------------------------------------------------------------

def t_share(sb):
    """Two shims share one daemon and one LSP; the joiner gets the
    starter's env."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "whoami", "STUB_LSP_TAG": "A"})
    a.initialize()
    b = sb.start({"STUB_LSP_HOVER_RESPONSES": "whoami", "STUB_LSP_TAG": "B"})
    b.initialize()
    ha, hb = hover(a, sb, 10), hover(b, sb, 11)
    check(ha == hb and "tag=A" in ha, "expected one shared stub started by A: %s / %s" % (ha, hb))
    st = sb.status()
    check(len(st["sessions"]) == 2, "expected 2 sessions: %r" % st["sessions"])
    check(len(st["lsps"]) == 1, "expected 1 LSP: %r" % st["lsps"])
    check(len(daemons_for(sb.socket_path())) == 1, "expected one daemon process")


def t_spawn_race(sb):
    """N shims starting at once get exactly one daemon."""
    shims = [sb.start() for _ in range(8)]
    for s in shims:
        s.initialize()
    check(len(daemons_for(sb.socket_path())) == 1,
          "expected one daemon, got %s" % daemons_for(sb.socket_path()))
    check(len(sb.status()["sessions"]) == 8, "expected 8 sessions")


def t_builds_isolated(sb):
    """Two builds get two sockets and two daemons; a wrong build is refused."""
    other = os.path.join(sb.dir, "rel2")
    os.makedirs(other)
    for entry in os.listdir(sb.release):
        if entry != "BUILD_ID":
            os.symlink(os.path.join(sb.release, entry), os.path.join(other, entry))
    with open(os.path.join(other, "BUILD_ID"), "w") as f:
        f.write("feedfacefeedface\n")
    a = sb.start()
    a.initialize()
    b = sb.start({"PHAROS_RELEASE_ROOT": other})
    b.initialize()
    socks = sorted(f for f in os.listdir(sb.rt) if f.endswith(".sock"))
    check(len(socks) == 2, "expected two sockets: %s" % socks)
    pids = [daemons_for(os.path.join(sb.rt, s)) for s in socks]
    check(all(len(p) == 1 for p in pids) and pids[0] != pids[1], "expected two daemons: %s" % pids)
    ack = raw_hello(os.path.join(sb.rt, socks[0]),
                    {"pharos_hello": 1, "op": "mcp", "build": "0000000000000000",
                     "cwd": "/", "env": {}})
    check("pharos_hello_error" in ack and "build mismatch" in ack["pharos_hello_error"],
          "expected a build-mismatch refusal: %r" % ack)
    sb.cli("daemon", "stop", extra_env={"PHAROS_RELEASE_ROOT": other})


def t_idle_exit(sb):
    """The daemon exits after the idle timeout; an idle LSP stops while
    its session stays connected."""
    env = {"PHAROS_DAEMON_IDLE_SECS": "2", "PHAROS_LSP_IDLE_SECS": "2",
           "STUB_LSP_HOVER_RESPONSES": "whoami"}
    a = sb.start(env)
    a.initialize()
    first = hover(a, sb, 10)
    sb.env.update({"PHAROS_DAEMON_IDLE_SECS": "2", "PHAROS_LSP_IDLE_SECS": "2"})
    wait_until(lambda: sb.status()["lsps"] == [], 10, "the idle LSP to stop")
    second = hover(a, sb, 11)
    check(first != second, "expected a fresh LSP after the idle stop: %s / %s" % (first, second))
    sock, pid = sb.socket_path(), sb.daemon_pid()
    a.close_stdin()
    a.drain(10)
    wait_until(lambda: not os.path.exists(sock), 15, "the socket to go after idle exit")
    wait_until(lambda: not alive(pid), 15, "the daemon process to exit")


def t_daemon_death(sb):
    """Killing the daemon mid-response: the shim exits 1 quickly with a
    stderr line, and stdout holds only complete frames."""
    a = sb.start()
    a.initialize()
    pid = sb.daemon_pid()
    big = "x" * (8 << 20)
    # Write from a thread while this one reads: the replies are as big as
    # the requests, and with nobody reading stdout the pipes and socket
    # buffers fill and the write blocks forever (macOS's small buffers hit
    # it; Linux's absorbed it).
    def send_all():
        try:
            for i in range(3):
                a.send({"jsonrpc": "2.0", "id": 100 + i, "method": "tools/call",
                        "params": {"name": "echo", "arguments": {"message": big}}})
        except (BrokenPipeError, OSError):
            pass  # the shim exited once the daemon died: expected
    threading.Thread(target=send_all, daemon=True).start()
    time.sleep(0.3)
    os.kill(pid, signal.SIGKILL)
    t0 = time.time()
    end = a.drain(10)  # raises on any partial / non-JSON line
    check(end == "EOF", "expected EOF on stdout, got %r" % end)
    code = a.proc.wait(5)
    check(code == 1, "expected exit 1, got %s" % code)
    check(time.time() - t0 < 3, "shim took %.1fs to exit" % (time.time() - t0))
    err = a.proc.stderr.read().decode()
    check("lost connection to the pharos daemon" in err, "missing stderr line: %r" % err)


def t_partial_frame(sb):
    """A daemon that dies mid-frame: the shim relays the whole frames
    before it, drops the partial one, and exits 1. A fake daemon makes
    the cut deterministic."""
    probe = sb.start()
    probe.initialize()
    path = sb.socket_path()
    probe.kill()
    sb.cli("daemon", "stop")
    wait_until(lambda: not os.path.exists(path), 15, "the real daemon's socket to go")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    a = sb.start()
    conn, _ = server.accept()
    conn.settimeout(10)
    hello = b""
    while b"\n" not in hello:
        hello += conn.recv(65536)
    conn.sendall(b'{"pharos_hello_ok":1,"session":"s1","daemon_pid":1}\n')
    conn.sendall(b'{"jsonrpc":"2.0","id":1,"result":{"whole":true}}\n{"jsonrpc":"2.0","id":2,"res')
    time.sleep(0.5)
    conn.close()
    server.close()
    os.unlink(path)
    first = a.read_line(5)
    check(isinstance(first, dict) and first.get("id") == 1, "expected the whole frame first: %r" % first)
    check(a.read_line(5) == "EOF", "expected EOF after the whole frame")  # a partial would fail as non-JSON
    check(a.proc.wait(5) == 1, "expected exit 1")
    check("lost connection" in a.proc.stderr.read().decode(), "missing stderr line")


def t_stdout_clean(sb):
    """Only JSON-RPC reaches stdout, with debug logging and stderr
    logging on and PHAROS_INSTALL_DIR set."""
    a = sb.start({"PHAROS_LOG": "debug", "PHAROS_LOG_STDERR": "1",
                  "PHAROS_INSTALL_DIR": os.path.join(sb.dir, "inst")})
    a.initialize()
    a.call(2, "tools/list")
    a.tool(3, "echo", {"message": "clean"})
    hover(a, sb, 4)
    a.close_stdin()
    check(a.drain(10) == "EOF", "expected EOF after stdin closed")
    check(a.proc.wait(10) == 0, "expected exit 0 after stdin EOF")


def t_isolation(sb):
    """Per-session tool filter, cancel scope, timeout overrides; the
    hello env never shows in logs, status or responses."""
    a = sb.start({"PHAROS_TOOLS": "read"})
    a.initialize()
    b = sb.start({"STUB_LSP_HOVER_DELAY_MS": "2000"})
    b.initialize()
    na = len(a.call(2, "tools/list")["result"]["tools"])
    nb = len(b.call(2, "tools/list")["result"]["tools"])
    check(na < nb, "PHAROS_TOOLS=read should list fewer tools: %d vs %d" % (na, nb))
    # Warm the stub, then a slow hover id 7 in B; A cancels *its* id 7.
    hover(b, sb, 6)
    b.send({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {
        "name": "hover", "arguments": {"uri": sb.uri, "line": 0, "character": 1}}})
    time.sleep(0.5)
    a.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7}})
    r = None
    while r is None or r.get("id") != 7:
        r = b.read_line(15)
        check(r not in (None, "EOF"), "B's id 7 got no reply: A's cancel crossed sessions")
    # Overrides stay in their session.
    b.tool(8, "runtime_set_tool_timeout", {"tool": "hover", "timeout_ms": 123456})
    c = sb.start()
    c.initialize()
    eff = c.tool(9, "runtime_effective_tool_config", {"tool": "hover"})
    check("123456" not in eff, "B's override leaked into C: %s" % eff)
    mine = b.tool(10, "runtime_effective_tool_config", {"tool": "hover"})
    check("123456" in mine, "B's override missing in B: %s" % mine)
    # The secret in every hello env appears nowhere.
    leaks = []
    if SECRET in json.dumps(sb.status()):
        leaks.append("status")
    for s in (a, b, c):
        if SECRET in json.dumps(s.lines):
            leaks.append("responses")
    for root, _, files in os.walk(sb.state):
        for f in files:
            if SECRET.encode() in open(os.path.join(root, f), "rb").read():
                leaks.append(f)
    check(not leaks, "the hello env leaked into: %s" % leaks)


def t_outlives_terminal(sb):
    """A daemon started from one terminal session survives that session
    being killed, and keeps serving another."""
    a = sb.start(start_new_session=True)
    a.initialize()
    pid = sb.daemon_pid()
    b = sb.start()
    b.initialize()
    os.killpg(a.proc.pid, signal.SIGKILL)
    a.proc.wait(5)
    time.sleep(1)
    check(alive(pid), "the daemon died with the terminal session that started it")
    check(b.tool(5, "echo", {"message": "still"}) == "still", "B stopped working")


def t_stale_and_slow(sb):
    """A stale socket (dead daemon) is replaced; a live but stopped
    daemon is waited for, never unlinked."""
    a = sb.start()
    a.initialize()
    first = sb.daemon_pid()
    a.kill()
    os.kill(first, signal.SIGKILL)
    wait_until(lambda: not alive(first), 5, "the daemon to die")
    check(sb.socket_path() is not None, "the stale socket should still be there")
    b = sb.start()
    b.initialize()
    second = sb.daemon_pid()
    check(second and second != first, "expected a new daemon, got %s (was %s)" % (second, first))
    os.kill(second, signal.SIGSTOP)
    try:
        c = sb.start()
        c.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": INIT_PARAMS})
        time.sleep(2)
        check(c.proc.poll() is None, "the shim gave up on a stopped daemon")
        check(sb.socket_path() is not None and sb.daemon_pid() == second,
              "the live daemon's socket was replaced")
    finally:
        os.kill(second, signal.SIGCONT)
    r = c.read_line(15)
    check(isinstance(r, dict) and r.get("id") == 1 and "result" in r, "no initialize after SIGCONT: %r" % r)
    check(sb.daemon_pid() == second, "a second daemon was started")


def t_fd_hygiene(sb):
    """A non-CLOEXEC fd the client hands down is not held by the daemon."""
    r, w = os.pipe()
    os.set_inheritable(w, True)
    a = sb.start(pass_fds=(w,))
    os.close(w)
    a.initialize()
    a.close_stdin()
    a.drain(10)
    a.proc.wait(10)
    # Every writer gone means EOF; a daemon still holding it would block.
    ready, _, _ = select.select([r], [], [], 5)
    check(ready and os.read(r, 1) == b"", "the daemon holds the client's inherited fd")
    os.close(r)


def t_cancel_lands(sb):
    """A cancel in daemon mode kills the dispatcher (no reply) and
    reaches the LSP as $/cancelRequest."""
    a = sb.start({"STUB_LSP_HOVER_DELAY_MS": "4000"})
    a.initialize()
    a.tool(5, "document_symbols", {"uri": sb.uri})
    a.send({"jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": {
        "name": "hover", "arguments": {"uri": sb.uri, "line": 0, "character": 1}}})
    time.sleep(1)
    a.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 20}})
    deadline = time.time() + 7
    while time.time() < deadline:
        r = a.read_line(deadline - time.time())
        if isinstance(r, dict):
            check(r.get("id") != 20, "a reply went out for the cancelled request")
    check(a.tool(21, "echo", {"message": "after"}) == "after", "session broken after cancel")
    log = open(os.path.join(sb.fixture, "stub.log")).read()
    check("$/cancelRequest" in log, "the stub never saw $/cancelRequest")


def t_restart_survives(sb):
    """Killing the daemon actor (not the process) keeps live sessions
    serving and counted: no idle exit under them."""
    env = {"PHAROS_DAEMON_TEST_OPS": "1", "PHAROS_DAEMON_IDLE_SECS": "2"}
    sb.env.update(env)
    a = sb.start()
    a.initialize()
    pid = sb.daemon_pid()
    ack = raw_hello(sb.socket_path(), {"pharos_hello": 1, "op": "test_crash_daemon"})
    check(ack.get("pharos_test") == 1, "test op refused: %r" % ack)
    time.sleep(5)
    check(a.tool(2, "echo", {"message": "alive"}) == "alive", "session died with the daemon actor")
    check(alive(pid) and sb.daemon_pid() == pid, "the daemon process changed or exited")
    check(len(sb.status()["sessions"]) == 1, "the restarted daemon lost the session")


SCENARIOS = [
    ("share", t_share),
    ("spawn_race", t_spawn_race),
    ("builds_isolated", t_builds_isolated),
    ("idle_exit", t_idle_exit),
    ("daemon_death", t_daemon_death),
    ("partial_frame", t_partial_frame),
    ("stdout_clean", t_stdout_clean),
    ("isolation", t_isolation),
    ("outlives_terminal", t_outlives_terminal),
    ("stale_and_slow", t_stale_and_slow),
    ("fd_hygiene", t_fd_hygiene),
    ("cancel_lands", t_cancel_lands),
    ("restart_survives", t_restart_survives),
]


def on_scenario_timeout(_signum, _frame):
    # What was running when it hung, for the CI log.
    ps = subprocess.run(["ps", "-A", "-o", "pid,ppid,stat,etime,args"],
                        capture_output=True, text=True).stdout
    print("  --- processes at the timeout (pharos, beam, python):", flush=True)
    for line in ps.splitlines():
        if any(k in line for k in ("pharos", "beam", "python", "PID")):
            print("  " + line[:200], flush=True)
    raise Failure("timed out after %ds (a hang)" % SCENARIO_TIMEOUT_SECS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", required=True)
    ap.add_argument("--shim", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true", help="keep the temp root")
    ap.add_argument("--env", action="append", default=[], metavar="K=V",
                    help="extra env for every shim, e.g. PHAROS_DAEMON_SYSTEMD=0")
    args = ap.parse_args()
    release = os.path.abspath(args.release)
    shim = os.path.abspath(args.shim)
    only = set(filter(None, args.only.split(",")))
    extra_env = dict(kv.split("=", 1) for kv in args.env)
    root = tempfile.mkdtemp(prefix="pd", dir="/tmp")
    failed = []
    try:
        for name, fn in SCENARIOS:
            if only and name not in only:
                continue
            sb = Sandbox(root, name, release, shim, extra_env)
            print("---- %s" % name, flush=True)
            t0 = time.time()
            signal.signal(signal.SIGALRM, on_scenario_timeout)
            signal.alarm(SCENARIO_TIMEOUT_SECS)
            try:
                fn(sb)
                signal.alarm(0)
                print("PASS %-18s %5.1fs" % (name, time.time() - t0), flush=True)
            except Exception as e:  # noqa: BLE001
                failed.append(name)
                print("FAIL %-18s %5.1fs  %s" % (name, time.time() - t0, e), flush=True)
                if not isinstance(e, Failure):
                    traceback.print_exc()
                logdir = os.path.join(sb.state, "pharos", "log")
                if os.path.isdir(logdir):
                    for f in sorted(os.listdir(logdir)):
                        if f.endswith(".boot.log"):
                            print("  --- %s (tail)" % f)
                            print("  " + "\n  ".join(open(os.path.join(logdir, f)).read().splitlines()[-15:]))
            finally:
                signal.alarm(0)
                sb.teardown()
    finally:
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print("kept", root)
    print("%d passed, %d failed" % (len([n for n, _ in SCENARIOS if (not only or n in only)]) - len(failed), len(failed)))
    sys.exit(len(failed))


if __name__ == "__main__":
    main()
