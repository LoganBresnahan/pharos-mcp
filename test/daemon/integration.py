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
import re
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
from urllib.parse import quote

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
            # Its own HOME: the ADR-030 instance dirs live under it, and a
            # daemon's boot-time reap (ADR-037) must only see this sandbox's.
            "HOME": self.dir,
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

    def cli(self, *args, extra_env=None, timeout=30, cwd=None):
        env = dict(self.env, **(extra_env or {}))
        return subprocess.run([self.shim, *args], env=env, capture_output=True,
                              text=True, timeout=timeout, cwd=cwd)

    def status(self):
        out = self.cli("daemon", "status")
        check(out.returncode == 0, "daemon status failed: %s" % out.stderr)
        return json.loads(out.stdout.splitlines()[0])

    def teardown(self):
        for s in self.shims:
            s.kill()
        # A scenario that failed may leave the stub's grandchild (ADR-037).
        log = os.path.join(self.fixture, "grandchild.pids")
        if os.path.exists(log):
            for line in open(log).read().split():
                try:
                    os.kill(int(line), signal.SIGKILL)
                except (OSError, ValueError):
                    pass
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
    # The client hasn't left: stdin stays open, so the shim must report a
    # lost daemon (exit 1), not a clean end of session (exit 0), however
    # its stdin copy and its socket read happen to order around the kill.
    check(not a.proc.stdin.closed and a.proc.poll() is None, "the shim should still be serving")
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


def grandchild_of_stub(sb):
    """Start a session whose stub LSP leaves a long-lived grandchild in its
    process group (ADR-037), and return (shim, grandchild pid)."""
    log = os.path.join(sb.fixture, "grandchild.pids")
    a = sb.start({"STUB_LSP_GRANDCHILD": log})
    a.initialize()
    hover(a, sb, 10)
    wait_until(lambda: os.path.exists(log) and open(log).read().strip(), 10, "the stub's grandchild")
    pid = int(open(log).read().split()[0])
    check(alive(pid), "the grandchild isn't running")
    return a, pid


def t_cli_new_language(sb):
    """`--print-language-config` sees a language pharos.toml adds (it read
    only the bundled defaults through 0.2.1, being a pre-boot meta flag)."""
    out = sb.cli("--print-language-config", "stub",
                 extra_env={"PHAROS_CONFIG_FILE": os.path.join(sb.fixture, ".pharos.toml")})
    check(out.returncode == 0 and "[languages.stub]" in out.stdout and ".stub" in out.stdout,
          "the stub language wasn't printed: %r %r" % (out.stdout[:300], out.stderr[:300]))


def t_process_id(sb):
    """initialize carries the daemon's OS pid as processId (ADR-037), so
    servers that watch their client exit by themselves when it dies."""
    a = sb.start()
    a.initialize()
    hover(a, sb, 10)
    log = open(os.path.join(sb.fixture, "stub.log")).read()
    check("initialize processId=%d" % sb.daemon_pid() in log,
          "processId isn't the daemon pid %s: %s" % (sb.daemon_pid(), log))


def t_reap_on_stop(sb):
    """`pharos daemon stop` takes what an LSP left in its process group
    with it (rust-analyzer's in-flight cargo check, measured surviving)."""
    _a, grandchild = grandchild_of_stub(sb)
    pid = sb.daemon_pid()
    out = sb.cli("daemon", "stop")
    check(out.returncode == 0, "daemon stop failed: %s" % out.stderr)
    wait_until(lambda: not alive(pid), 15, "the daemon to exit")
    wait_until(lambda: not alive(grandchild), 10, "the grandchild to be reaped at stop")


def t_reap_on_idle(sb):
    """An idle-stopped LSP's leftover grandchild is reaped while the
    daemon and the session carry on."""
    sb.env.update({"PHAROS_LSP_IDLE_SECS": "2"})
    a, grandchild = grandchild_of_stub(sb)
    wait_until(lambda: sb.status()["lsps"] == [], 15, "the idle LSP to stop")
    wait_until(lambda: not alive(grandchild), 15, "the grandchild to be reaped after the idle stop")
    check(a.tool(20, "echo", {"message": "still here"}) == "still here", "the session died")


def t_reap_after_death(sb):
    """SIGKILL the daemon: the grandchild outlives it (nothing in the dead
    VM can act), and the next daemon's boot-time reap takes it."""
    a, grandchild = grandchild_of_stub(sb)
    pid = sb.daemon_pid()
    os.kill(pid, signal.SIGKILL)
    a.drain(10)
    wait_until(lambda: not alive(pid), 10, "the daemon to die")
    time.sleep(1)
    check(alive(grandchild), "the grandchild died with the daemon: nothing to test")
    b = sb.start()
    b.initialize()
    wait_until(lambda: not alive(grandchild), 20, "the next daemon to reap the grandchild")


# -- ADR-038: documents follow the disk -------------------------------------

def stub_file(sb, name, text):
    path = os.path.join(sb.fixture, name)
    with open(path, "w") as f:
        f.write(text)
    return "file://" + path


def sync_lines(sb, method=None):
    path = os.path.join(sb.fixture, "stub.log")
    if not os.path.exists(path):
        return []
    lines = [l.split(None, 1)[1].strip() for l in open(path) if " textDocument/did" in l]
    return [l for l in lines if method is None or l.startswith(method)]


def hover_line(shim, uri, id_, line=0):
    return shim.tool(id_, "hover", {"uri": uri, "line": line, "character": 0})


def t_resync_follows_disk(sb):
    """A file saved between two questions gets the second answer about the
    new text: one full-text didChange at the next version, then didSave; an
    unchanged file sends nothing."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line", "STUB_LSP_SYNC_KIND": "2",
                  "STUB_LSP_SYNC_SAVE": "true"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "first\n")
    check("line 0: first" in hover_line(a, uri, 10), "first answer")
    stub_file(sb, "main.stub", "second\n")
    h = hover_line(a, uri, 11)
    check("line 0: second" in h, "answer did not follow the disk: %s" % h)
    check("line 0: second" in hover_line(a, uri, 12), "unchanged re-ask")
    changes = sync_lines(sb, "textDocument/didChange")
    check(len(changes) == 1 and "v=2" in changes[0] and "changes=1" in changes[0]
          and "range=False" in changes[0], "expected one full-text didChange v=2: %r" % changes)
    saves = sync_lines(sb, "textDocument/didSave")
    check(len(saves) == 1 and "save_text=False" in saves[0], "expected one plain didSave: %r" % saves)
    check(len(sync_lines(sb, "textDocument/didOpen")) == 1, "reopened: %r" % sync_lines(sb))


def t_resync_shared_sessions(sb):
    """One session's first question doesn't pin the text for the others."""
    env = {"STUB_LSP_HOVER_RESPONSES": "line"}
    a = sb.start(env)
    a.initialize()
    b = sb.start(env)
    b.initialize()
    uri = stub_file(sb, "main.stub", "old\n")
    check("line 0: old" in hover_line(a, uri, 10), "A's first answer")
    stub_file(sb, "main.stub", "new\n")
    h = hover_line(b, uri, 11)
    check("line 0: new" in h, "B got the text A's question pinned: %s" % h)


def t_resync_other_open_documents(sb):
    """A question about one file re-syncs every other document open on that
    server: B changed on disk is re-sent before the question about A."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    ua = stub_file(sb, "a.stub", "a1\n")
    ub = stub_file(sb, "b.stub", "b1\n")
    hover_line(a, ua, 10)
    hover_line(a, ub, 11)
    stub_file(sb, "b.stub", "b2\n")
    hover_line(a, ua, 12)
    changes = sync_lines(sb, "textDocument/didChange")
    check(any("b.stub v=2" in c for c in changes), "b.stub was not re-synced: %r" % sync_lines(sb))
    check(not any("a.stub" in c for c in changes), "a.stub didn't change: %r" % changes)
    os.remove(os.path.join(sb.fixture, "b.stub"))
    hover_line(a, ua, 13)
    check(any("didClose b.stub" in c for c in sync_lines(sb)),
          "a deleted file was not closed: %r" % sync_lines(sb))


def t_resync_sync_kind_none(sb):
    """A server that syncs nothing (TextDocumentSyncKind None) still gets a
    balanced close + reopen at the next version, never a second didOpen."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line", "STUB_LSP_SYNC_KIND": "0"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "one\n")
    hover_line(a, uri, 10)
    stub_file(sb, "main.stub", "two\n")
    check("line 0: two" in hover_line(a, uri, 11), "reopen didn't carry the new text")
    lines = sync_lines(sb)
    check(not any(l.startswith("textDocument/didChange") for l in lines), "didChange sent: %r" % lines)
    check(any("didClose main.stub" in l for l in lines) and any("didOpen main.stub v=2" in l for l in lines),
          "expected didClose then didOpen v=2: %r" % lines)


def t_resync_unchanged_diagnostics(sb):
    """A server that skips a publish when a file's diagnostics didn't change
    (rust-analyzer's behaviour) costs the settle window, not the timeout, and
    the answer is marked carried over."""
    a = sb.start({"STUB_LSP_DIAGNOSTICS": "push-suppress"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    d1 = a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    check("stub error on line 1" in d1, "first diagnostics: %s" % d1)
    stub_file(sb, "main.stub", "still ok\nERROR one\n")
    t0 = time.time()
    d2 = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    took = time.time() - t0
    check("stub error on line 1" in d2 and "carried_over" in d2, "expected the carried-over set: %s" % d2)
    check(took < 6, "took %.1fs: waited the timeout, not the settle window" % took)
    # The window runs from the sync, so asking again doesn't wait again.
    # The file's own change was never answered, so it stays marked.
    t0 = time.time()
    d2b = a.tool(13, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    took = time.time() - t0
    check("stub error on line 1" in d2b and "carried_over" in d2b, "re-ask: %s" % d2b)
    check(took < 1, "re-ask took %.1fs: waited out the window again" % took)
    stub_file(sb, "main.stub", "fixed\n")
    d3 = a.tool(12, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    check("stub error" not in d3 and "carried_over" not in d3, "expected a fresh empty set: %s" % d3)


def t_resync_settles_after_window(sb):
    """A server that never republishes an unchanged set (gopls,
    rust-analyzer): after another document opens or changes, an unchanged
    file's diagnostics are carried over for the settle window only. A call
    that waits the window out, or comes after it, gets them fresh; only a
    call whose own timeout ends inside the window gets them marked."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line", "STUB_LSP_DIAGNOSTICS": "push-suppress"})
    a.initialize()
    ua = stub_file(sb, "a.stub", "ERROR a\n")
    ub = stub_file(sb, "b.stub", "b1\n")
    d = a.tool(10, "get_diagnostics", {"uri": ua, "timeout_ms": 20000})
    check("stub error on line 0" in d and "carried_over" not in d, "first: %s" % d)

    def inside_then_after(what, id_):
        # A call whose own timeout ends inside the window: marked.
        t0 = time.time()
        cut = a.tool(id_, "get_diagnostics", {"uri": ua, "timeout_ms": 400})
        took = time.time() - t0
        check("stub error on line 0" in cut and "carried_over" in cut,
              "%s, cut short inside the window: %s" % (what, cut))
        check(took < 1.5, "%s: the cut-short call took %.1fs" % (what, took))
        # A call that waits the window out: the server stayed quiet, so
        # the set stands, unmarked.
        t0 = time.time()
        rest = a.tool(id_ + 1, "get_diagnostics", {"uri": ua, "timeout_ms": 20000})
        took = time.time() - t0
        check("stub error on line 0" in rest and "carried_over" not in rest,
              "%s, waited out the window: %s" % (what, rest))
        check(took < 3, "%s: waiting out the window took %.1fs" % (what, took))
        # After the window: at once.
        t0 = time.time()
        after = a.tool(id_ + 2, "get_diagnostics", {"uri": ua, "timeout_ms": 20000})
        took = time.time() - t0
        check("stub error on line 0" in after and "carried_over" not in after,
              "%s, after the window: %s" % (what, after))
        check(took < 1, "%s: after the window took %.1fs" % (what, took))

    hover_line(a, ub, 11)               # opens b.stub on the same server
    inside_then_after("another file opened", 12)
    stub_file(sb, "b.stub", "b2\n")      # and now changes
    inside_then_after("another file changed", 15)


def t_resync_subject_deleted(sb):
    """The file asked about is deleted: pharos closes it, never reopens it,
    and neither hover nor get_diagnostics answers from the old text."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line", "STUB_LSP_DIAGNOSTICS": "push"})
    a.initialize()
    uri = stub_file(sb, "gone.stub", "oldtext ERROR\n")
    d1 = a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    check("stub error on line 0" in d1, "first diagnostics: %s" % d1)
    os.remove(os.path.join(sb.fixture, "gone.stub"))
    h = hover_line(a, uri, 11)
    check("oldtext" not in h, "hover answered from the deleted text: %s" % h)
    check(any(l == "textDocument/didClose gone.stub" for l in sync_lines(sb)),
          "the deleted file was not closed: %r" % sync_lines(sb))
    d2 = a.tool(12, "get_diagnostics", {"uri": uri, "timeout_ms": 1500})
    check("stub error" not in d2, "diagnostics of the deleted text: %s" % d2)
    opens = [l for l in sync_lines(sb, "textDocument/didOpen") if "gone.stub" in l]
    check(len(opens) == 1, "a gone file was opened again: %r" % opens)


def t_tsserver_answers_new_text(sb):
    """ADR-039: with diagnostics_mode = "tsserver", get_diagnostics asks
    the server for the file's diagnostics instead of reading publishes. The
    stub plays tsserver's race (ADR-038 F4): after a change it publishes the
    OLD text's set, without a version, and the right one later. The answer
    must describe the new text anyway, at once."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    a = sb.start({"STUB_LSP_DIAGNOSTICS": "push-stale", "STUB_LSP_TSSERVER": "answer",
                  "STUB_LSP_STALE_DELAY_MS": "1500"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    d1 = a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    check("tsserver error on line 1" in d1 and '"code":9001' in d1, "first answer: %s" % d1)
    check('"line":0' in d1 and '"relatedInformation"' in d1 and '"severity":1' in d1,
          "tsserver's 1-based positions and related info must map to LSP: %s" % d1)
    stub_file(sb, "main.stub", "fixed\n")
    t0 = time.time()
    d2 = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    took = time.time() - t0
    check("error" not in d2 and "carried_over" not in d2, "answered from the old text: %s" % d2)
    check(took < 1, "took %.1fs: waited for publishes instead of asking" % took)
    asks = [l for l in open(os.path.join(sb.fixture, "stub.log")) if "workspace/executeCommand" in l]
    check(any("semanticDiagnosticsSync main.stub" in l for l in asks)
          and any("syntacticDiagnosticsSync main.stub" in l for l in asks)
          and any("suggestionDiagnosticsSync main.stub" in l for l in asks),
          "expected the three *DiagnosticsSync requests: %r" % asks[-6:])


def t_tsserver_falls_back_to_push(sb):
    """ADR-039: when the tsserver request fails, get_diagnostics answers
    from the push cache, marked carried over: a publish carries no version,
    so it may describe the text before a change."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    a = sb.start({"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_TSSERVER": "fail"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    d = a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    check("stub error on line 1" in d and "carried_over" in d, "expected the pushed set, marked: %s" % d)


def tsserver_fallback_is_marked(sb, mode, extra, timeout):
    """ADR-039, review finding: a fallback can serve F4's stale set (the
    stub publishes the OLD text's diagnostics after a change), so the
    answer must be marked."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    env = {"STUB_LSP_DIAGNOSTICS": "push-stale", "STUB_LSP_TSSERVER": mode,
           "STUB_LSP_STALE_DELAY_MS": "5000"}
    env.update(extra)
    a = sb.start(env)
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": timeout})
    stub_file(sb, "main.stub", "fixed\n")
    d = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": timeout})
    check("stub error on line 1" in d and "carried_over" in d,
          "%s: expected the stale set, marked carried over: %s" % (mode, d))


def t_tsserver_failed_fallback_is_marked(sb):
    """The tsserver request fails: the push-cache answer is marked."""
    tsserver_fallback_is_marked(sb, "fail", {}, 20000)


def t_tsserver_timed_out_fallback_is_marked(sb):
    """The tsserver request outlasts the call's timeout: the push-cache
    answer is marked."""
    tsserver_fallback_is_marked(sb, "slow", {"STUB_LSP_TSSERVER_DELAY_MS": "4000"}, 1500)


def t_diagnostics_cli(sb):
    """#6: `pharos diagnostics` asks the shared daemon for files'
    diagnostics without an MCP client: ok with the diagnostics and, in
    tsserver mode, the file's project; a human form; exit 0 once the daemon
    answered, 2 on bad usage. (How a marked answer reads as unsure is the
    shim's unit tests: a second call here would reuse the first's stub.)"""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    env = {"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_TSSERVER": "answer",
           "STUB_LSP_TSSERVER_PROJECT": os.path.join(sb.fixture, "tsconfig.json")}
    bad = os.path.join(sb.fixture, "bad.stub")
    good = os.path.join(sb.fixture, "good.stub")
    with open(bad, "w") as f:
        f.write("ok\nERROR one\nok\n")
    with open(good, "w") as f:
        f.write("fine\n")
    out = sb.cli("diagnostics", "--json", bad, good, extra_env=env, timeout=60, cwd=sb.fixture)
    check(out.returncode == 0, "exit %d: %s" % (out.returncode, out.stderr[-400:]))
    files = json.loads(out.stdout)["files"]
    check([f["status"] for f in files] == ["ok", "ok"], "statuses: %s" % out.stdout)
    check(files[0]["project"] == env["STUB_LSP_TSSERVER_PROJECT"], "project: %s" % files[0])
    check([d["code"] for d in files[0]["diagnostics"]] == [9001] and files[1]["diagnostics"] == [],
          "diagnostics: %s" % out.stdout)
    human = sb.cli("diagnostics", bad, extra_env=env, timeout=60, cwd=sb.fixture)
    check(human.returncode == 0 and human.stdout.strip() == "%s:2:1 error 9001 tsserver error on line 1" % bad,
          "human form: %r" % human.stdout)
    usage = sb.cli("diagnostics", extra_env=env, cwd=sb.fixture)
    check(usage.returncode == 2 and "usage" in usage.stderr, "usage: %r" % usage.stderr)


def t_diagnostics_cli_unknown_project(sb):
    """#6, review finding: when tsserver can't name the file's project,
    pharos says so (`pharos.project_unknown`) and the CLI reports the file
    as unsure, never as an ok answer a hook would read as out of scope."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    env = {"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_TSSERVER": "answer"}   # no project
    f = os.path.join(sb.fixture, "a.stub")
    with open(f, "w") as fh:
        fh.write("ERROR one\n")
    out = sb.cli("diagnostics", "--json", f, extra_env=env, timeout=60, cwd=sb.fixture)
    check(out.returncode == 0, "exit %d: %s" % (out.returncode, out.stderr[-400:]))
    entry = json.loads(out.stdout)["files"][0]
    check(entry["status"] == "unsure" and entry.get("reason") == "project_unknown" and "project" not in entry,
          "expected unsure/project_unknown: %s" % entry)


def t_diagnostics_cli_busy_tsserver(sb):
    """#7's dry run: tsserver answers in order, and the first request after
    an edit waits for the program update. projectInfo went first under a
    2 s cap, ran out, and the file read as unsure. Now the diagnostics go
    first and absorb the wait; the project comes back named."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    env = {"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_TSSERVER": "busy",
           "STUB_LSP_TSSERVER_DELAY_MS": "3000",
           "STUB_LSP_TSSERVER_PROJECT": os.path.join(sb.fixture, "tsconfig.json")}
    f = os.path.join(sb.fixture, "busy.stub")
    with open(f, "w") as fh:
        fh.write("ERROR one\n")
    out = sb.cli("diagnostics", "--json", "--timeout-ms", "20000", f, extra_env=env, timeout=60,
                 cwd=sb.fixture)
    check(out.returncode == 0, "exit %d: %s" % (out.returncode, out.stderr[-400:]))
    entry = json.loads(out.stdout)["files"][0]
    check(entry["status"] == "ok" and entry.get("project") == env["STUB_LSP_TSSERVER_PROJECT"],
          "a busy tsserver must still name the project: %s" % entry)
    check([d["code"] for d in entry["diagnostics"]] == [9001], "diagnostics: %s" % entry)


def t_diagnostics_cli_project_timeout(sb):
    """#7: when projectInfo doesn't answer within the call's deadline, the
    diagnostics still come back, and the file is unsure with the reason
    project_unknown (not a missing project), within the deadline."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    env = {"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_TSSERVER": "answer",
           "STUB_LSP_TSSERVER_PROJECT_DELAY_MS": "30000",
           "STUB_LSP_TSSERVER_PROJECT": os.path.join(sb.fixture, "tsconfig.json")}
    f = os.path.join(sb.fixture, "late.stub")
    with open(f, "w") as fh:
        fh.write("ERROR one\n")
    t0 = time.time()
    out = sb.cli("diagnostics", "--json", "--timeout-ms", "4000", f, extra_env=env, timeout=60,
                 cwd=sb.fixture)
    took = time.time() - t0
    check(out.returncode == 0, "exit %d: %s" % (out.returncode, out.stderr[-400:]))
    entry = json.loads(out.stdout)["files"][0]
    check(entry["status"] == "unsure" and entry.get("reason") == "project_unknown" and "project" not in entry,
          "expected unsure/project_unknown: %s" % entry)
    check(took < 15, "the call must end near its deadline, took %.1f s" % took)


def t_document_language_id(sb):
    """#17: one language entry can cover dialects its server parses
    differently, and didOpen's languageId follows the file's extension
    (`document_language_ids`), the language's id otherwise. Sent as the
    language's id, a .tsx file reached tsserver as plain TypeScript."""
    with open(os.path.join(sb.fixture, ".pharos.toml"), "w") as f:
        f.write('[languages.stub]\nfile_extensions = [".stub", ".stubx"]\n'
                'document_language_ids = { ".stubx" = "stubreact" }\n'
                'root_markers = ["stub.root"]\ncommand = "%s"\n' % STUB)
    env = {"STUB_LSP_DIAGNOSTICS": "push"}
    for name in ("plain.stub", "dialect.stubx"):
        with open(os.path.join(sb.fixture, name), "w") as fh:
            fh.write("fine\n")
    out = sb.cli("diagnostics", "--json", os.path.join(sb.fixture, "plain.stub"),
                 os.path.join(sb.fixture, "dialect.stubx"), extra_env=env, timeout=60, cwd=sb.fixture)
    check(out.returncode == 0, "exit %d: %s" % (out.returncode, out.stderr[-400:]))
    opens = sync_lines(sb, "textDocument/didOpen")
    langs = {l.split()[1]: l.rsplit("lang=", 1)[-1] for l in opens}
    check(langs.get("plain.stub") == "stub" and langs.get("dialect.stubx") == "stubreact",
          "didOpen languageIds: %r" % opens)


def escaped_project(sb):
    """#16: a workspace whose path has a space, `#`, `%` and a non-ASCII
    character. Returns its file's path and three spellings of its URI:
    escaped as vscode-uri does (pharos's canonical form), raw, and escaped
    as Rust's `url` does."""
    proj = os.path.join(sb.fixture, "my proj #1 100% \u00e9")
    os.makedirs(proj, exist_ok=True)
    open(os.path.join(proj, "stub.root"), "w").close()
    path = os.path.join(proj, "main.stub")
    with open(path, "w") as f:
        f.write("ok\nERROR one\n")
    return path, ["file://" + quote(path, safe="/"), "file://" + path,
                  "file://" + quote(path, safe="/!$&'()*+,;=:@")]


def uri_escapes_push(sb, style):
    a = sb.start({"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_URI_STYLE": style})
    a.initialize()
    _, spellings = escaped_project(sb)
    for i, uri in enumerate(spellings):
        t0 = time.time()
        d = a.tool(10 + i, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
        took = time.time() - t0
        check("stub error on line 1" in d, "%s: %s" % (uri, d[-400:]))
        check(took < 10, "%s took %.1fs: the publish never matched the question" % (uri, took))
    opens = [l for l in sync_lines(sb, "textDocument/didOpen") if "main.stub" in l]
    check(len(opens) == 1 and opens[0].endswith(" uri=" + spellings[0]),
          "expected one didOpen, of the canonical URI %s: %r" % (spellings[0], opens))


def t_uri_escapes_push_vscode(sb):
    """#16: a Push server that escapes as vscode-uri does
    (typescript-language-server) publishes `%20`; questions asked with any
    spelling of the URI match that publish, and the server sees one
    document, opened under the canonical URI. Before, an escaped URI found
    no workspace root, and a raw one waited out the timeout."""
    uri_escapes_push(sb, "vscode")


def t_uri_escapes_push_rust(sb):
    """#16: the same with a server that escapes as Rust's `url` does
    (rust-analyzer), leaving sub-delims raw: the cache key can't be the
    publish's own string."""
    uri_escapes_push(sb, "rust")


def t_uri_escapes_tsserver(sb):
    """#16: Tsserver mode (ADR-039) with the same workspace: tsserver finds
    the file by its path, and relatedInformation, which tsserver names by
    path, comes back as the escaped URI."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    a = sb.start({"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_TSSERVER": "answer",
                  "STUB_LSP_URI_STYLE": "vscode"})
    a.initialize()
    _, spellings = escaped_project(sb)
    for i, uri in enumerate(spellings):
        d = a.tool(10 + i, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
        check("tsserver error on line 1" in d, "%s: %s" % (uri, d[-400:]))
        check('"uri":"%s"' % spellings[0] in d,
              "relatedInformation must name the file by its canonical URI: %s" % d[-600:])


def t_uri_escapes_cli(sb):
    """#16: `pharos diagnostics` on a workspace whose name holds a valid
    escape (`%25`) as well as a space, `#` and a non-ASCII character. The
    daemon decodes every uri argument, so the CLI must escape the path, or
    `%25` reads as `%` and names another folder. Relative and absolute
    paths both work, and the printed uri is the canonical one. A relative
    path resolves against the working directory as the OS reports it (on
    macOS /tmp is /private/tmp), which the hook relies on: its root is a
    real path too."""
    proj = os.path.join(sb.fixture, "a b#c%25d-\u00e9")
    os.makedirs(proj)
    open(os.path.join(proj, "stub.root"), "w").close()
    path = os.path.join(proj, "main.stub")
    with open(path, "w") as f:
        f.write("ok\nERROR one\n")
    env = {"STUB_LSP_DIAGNOSTICS": "push"}
    real = os.path.join(os.path.realpath(proj), "main.stub")
    for arg, cwd, want in (("main.stub", proj, real), (path, sb.fixture, path)):
        out = sb.cli("diagnostics", "--json", arg, extra_env=env, timeout=60, cwd=cwd)
        check(out.returncode == 0, "%s: exit %d: %s" % (arg, out.returncode, out.stderr[-400:]))
        f = json.loads(out.stdout)["files"][0]
        check(f["status"] == "ok" and any("stub error on line 1" in d["message"] for d in f["diagnostics"]),
              "%s: %s" % (arg, out.stdout[-400:]))
        check(f["path"] == want and f["uri"] == "file://" + quote(want, safe="/"),
              "%s: path and canonical uri: %s" % (arg, f))
def t_apply_edit_failure_is_an_error(sb):
    """#22: apply_workspace_edit marks the result an error when a file
    fails, and says what landed: before, every file failing still read
    "Applied edits." with isError false."""
    a = sb.start({})
    a.initialize()
    ok = os.path.join(sb.fixture, "ok.txt")
    with open(ok, "w") as f:
        f.write("hello world")
    missing = os.path.join(sb.fixture, "missing.txt")
    rng = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}

    def apply(id_, paths):
        r = a.call(id_, "tools/call", {"name": "apply_workspace_edit", "arguments": {
            "edit": {"changes": {"file://" + p: [{"range": rng, "newText": "HELLO"}] for p in paths}},
            "dry_run": False}}, 60)
        return r["result"]["content"][0]["text"], r["result"].get("isError")

    text, err = apply(10, [missing])
    check(err is True and text.startswith("No edits applied"), "all failed: %r %s" % (err, text))
    text, err = apply(11, [ok, missing])
    check(err is True and text.startswith("Applied edits to 1 of 2 file(s)")
          and text.split("\n")[2].startswith("  fail  "), "partial: %r %s" % (err, text))
    check(open(ok).read() == "HELLO world", "the ok file must still be written")
    text, err = apply(12, [ok])
    check(err is False and text.startswith("Applied edits."), "all ok: %r %s" % (err, text))

def t_find_symbol_cold_session(sb):
    """#21: on a fresh session, find_symbol asks workspace/symbol before
    anything is open. tsserver answers that only from loaded projects and
    loads one when a file is opened, so it threw "No Project."; and right
    after the didOpen its navto still sees only the opened file. find_symbol
    now opens scope_uri and, on a tsserver-mode server, asks projectInfo
    first. The scope (b) only calls `helper`; a defines it."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "tsserver", "STUB_LSP_TSSERVER": "answer",
                  "STUB_LSP_TSSERVER_PROJECT": os.path.join(sb.fixture, "tsconfig.json")})
    a.initialize()
    stub_file(sb, "a.stub", "function helper() {\n  return 1;\n}\n")
    uri = stub_file(sb, "b.stub", "helper();\n")
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    check("No Project" not in out and '"status":"single"' in out and 'a.stub' in out,
          "first find_symbol on a cold session: %s" % out[-400:])

def t_long_runtime_dir(sb):
    """#14: a PHAROS_RUNTIME_DIR whose socket path won't fit falls back to
    /tmp/pharos-<uid>/, and used to merge every such session into one
    daemon there, silently. Now the requested dir is hashed into the socket
    name, so two sessions asking for different long dirs get two daemons
    (one's stop leaves the other running), and the fallback is reported on
    stderr."""
    long_a = os.path.join(sb.dir, "a" * 70)
    long_b = os.path.join(sb.dir, "b" * 70)
    env_a, env_b = {"PHAROS_RUNTIME_DIR": long_a}, {"PHAROS_RUNTIME_DIR": long_b}
    try:
        long_runtime_dir_checks(sb, env_a, env_b)
    finally:
        # These daemons live in the shared /tmp/pharos-<uid>/, outside the
        # sandbox teardown cleans: stop them whatever happened.
        for env in (env_a, env_b):
            sb.cli("daemon", "stop", extra_env=env)


def long_runtime_dir_checks(sb, env_a, env_b):
    for env in (env_a, env_b):
        s = sb.start(env)
        s.initialize()
    st_a = sb.cli("daemon", "status", extra_env=env_a)
    st_b = sb.cli("daemon", "status", extra_env=env_b)
    check(st_a.returncode == 0 and st_b.returncode == 0, "status: %r %r" % (st_a.stderr, st_b.stderr))
    check("too long for a socket path" in st_a.stderr, "the fallback must be reported: %r" % st_a.stderr)
    pid_a = json.loads(st_a.stdout.splitlines()[0])["daemon_pid"]
    pid_b = json.loads(st_b.stdout.splitlines()[0])["daemon_pid"]
    check(pid_a != pid_b, "two long runtime dirs shared daemon %s" % pid_a)
    check(sb.cli("daemon", "stop", extra_env=env_a).returncode == 0, "stop a")
    wait_until(lambda: not alive(pid_a), 15, "daemon a to exit")
    check(alive(pid_b), "stopping a's daemon stopped b's")
    check(sb.cli("daemon", "stop", extra_env=env_b).returncode == 0, "stop b")
    wait_until(lambda: not alive(pid_b), 15, "daemon b to exit")
def t_non_ascii_home_and_server_path(sb):
    """#20: a daemon whose HOME holds non-ASCII characters, with its
    language server installed under a non-ASCII path, still answers, and
    its instance-tracking dir (ADR-030) lands under that HOME. Environment
    values, HOME and `which` went through binary_to_list / list_to_binary,
    which read each UTF-8 byte as a character."""
    home = os.path.join(sb.dir, "h\u00f6m\u00e9 \u6f22")
    bindir = os.path.join(sb.dir, "bin \u00e9 \u6f22")
    os.makedirs(home)
    os.makedirs(bindir)
    server = os.path.join(bindir, "stub-lsp")
    shutil.copy(STUB, server)
    os.chmod(server, 0o755)
    with open(os.path.join(sb.fixture, ".pharos.toml"), "w") as f:
        f.write('[languages.stub]\nfile_extensions = [".stub"]\n'
                'root_markers = ["stub.root"]\ncommand = "stub-lsp"\n')
    sb.env.update({"HOME": home, "PATH": bindir + os.pathsep + sb.env["PATH"]})
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "hello\n")
    check("line 0: hello" in hover_line(a, uri, 10), "the server under a non-ASCII path must answer")
    instances = os.path.join(home, ".local", "share", "pharos", "instances")
    check(os.path.isdir(instances) and os.listdir(instances),
          "instance dir under the non-ASCII HOME: %r" % (os.listdir(home),))
    # The stop removes it. On 0.3.5 the stop raised (list_to_binary of
    # the HOME path) and left it behind.
    pid = sb.daemon_pid()
    out = sb.cli("daemon", "stop")
    check(out.returncode == 0, "daemon stop failed: %s" % out.stderr)
    wait_until(lambda: not alive(pid), 15, "the daemon to exit")
    check(os.listdir(instances) == [], "the instance dir must be removed at stop: %r" % os.listdir(instances))


def non_ascii_daemon(sb, extra_env):
    """A daemon whose HOME holds non-ASCII characters, with XDG_STATE_HOME
    and XDG_CONFIG_HOME unset (the usual setup: logs go under HOME), and a
    server configured by its absolute path under a non-ASCII folder. It
    must boot, answer, and clean up its instance dir at stop."""
    home = os.path.join(sb.dir, "h\u00f6m\u00e9 \u6f22")
    bindir = os.path.join(sb.dir, "srv \u00e9 \u6f22")
    os.makedirs(home)
    os.makedirs(bindir)
    server = os.path.join(bindir, "stub-lsp")
    shutil.copy(STUB, server)
    os.chmod(server, 0o755)
    with open(os.path.join(sb.fixture, ".pharos.toml"), "w") as f:
        f.write('[languages.stub]\nfile_extensions = [".stub"]\n'
                'root_markers = ["stub.root"]\ncommand = "%s"\n' % server)
    sb.env.pop("XDG_STATE_HOME", None)
    sb.env.pop("XDG_CONFIG_HOME", None)
    sb.env.update(dict(extra_env, HOME=home))
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "hello\n")
    check("line 0: hello" in hover_line(a, uri, 10), "the server under a non-ASCII path must answer")
    logs = os.path.join(home, ".local", "state", "pharos", "log")
    check(os.path.isdir(logs) and os.listdir(logs), "logs under the non-ASCII HOME: %r" % (os.listdir(home),))
    instances = os.path.join(home, ".local", "share", "pharos", "instances")
    check(os.path.isdir(instances) and os.listdir(instances),
          "the instance dir must exist under the non-ASCII HOME: %r" % (os.listdir(home),))
    pid = sb.daemon_pid()
    check(sb.cli("daemon", "stop").returncode == 0, "daemon stop")
    wait_until(lambda: not alive(pid), 15, "the daemon to exit")
    check(os.listdir(instances) == [], "the instance dir must be removed at stop: %r" % os.listdir(instances))


def t_non_ascii_home_default_state(sb):
    """#20: with XDG_STATE_HOME unset, a non-ASCII HOME crashed the
    daemon's boot (the log dir went through list_to_binary), and an
    absolute server command under a non-ASCII folder was "not found"."""
    non_ascii_daemon(sb, {})


def t_non_ascii_c_locale(sb):
    """#20: under the C locale the VM's file names are latin1, and the
    spawn path decoded UTF-8 anyway, so a server under a non-ASCII path
    wasn't found. Conversions now follow file:native_name_encoding()."""
    non_ascii_daemon(sb, {"LC_ALL": "C", "LANG": "C"})
def t_find_symbol_bad_scope(sb):
    """#24: a scope_uri naming a directory failed as "unsupported file
    type", and one naming a missing file reached tsserver and came back as
    its raw "No Project." stack trace. Both now say what's wrong with the
    scope, as a tool error."""
    sb.write_toml('diagnostics_mode = "tsserver"\n')
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "tsserver", "STUB_LSP_TSSERVER": "answer"})
    a.initialize()
    stub_file(sb, "a.stub", "function helper() {\n  return 1;\n}\n")

    def ask(id_, scope):
        r = a.call(id_, "tools/call", {"name": "find_symbol",
                                       "arguments": {"name_path": "helper", "scope_uri": scope}}, 60)
        return r["result"]["content"][0]["text"], r["result"].get("isError")

    text, err = ask(10, "file://" + sb.fixture)
    check(err is True and "not a directory" in text and "unsupported file type" not in text,
          "directory scope: %r %s" % (err, text))
    text, err = ask(11, "file://" + os.path.join(sb.fixture, "nope.stub"))
    check(err is True and "scope file not found" in text and "No Project" not in text,
          "missing scope: %r %s" % (err, text))
    text, err = ask(12, "file://" + os.path.join(sb.fixture, "a.stub"))
    check(not err and '"status":"single"' in text, "a file scope still answers: %r %s" % (err, text))
    # RFC 8089's localhost authority is the same local file; another host
    # is refused as not local.
    text, err = ask(13, "file://localhost" + os.path.join(sb.fixture, "a.stub"))
    check(not err and '"status":"single"' in text, "file://localhost scope: %r %s" % (err, text))
    text, err = ask(14, "file://elsewhere" + os.path.join(sb.fixture, "a.stub"))
    check(err is True and "names the host `elsewhere`" in text and "file:///absolute/path" in text,
          "a remote host must teach the fix: %r %s" % (err, text))
    # A relative path reads as a host (RFC 8089); the message says how to
    # write it. A bare file:// says it has no path, not "unsupported file
    # type".
    text, err = ask(15, "file://a.stub")
    check(err is True and "names the host `a.stub`" not in text, "file://a.stub (no slash after it): %r %s" % (err, text))
    text, err = ask(16, "file://src/a.stub")
    check(err is True and "names the host `src`" in text, "a relative path: %r %s" % (err, text))
    text, err = ask(17, "file://")
    check(err is True and "has no path" in text and "unsupported file type" not in text,
          "a bare file://: %r %s" % (err, text))
    # file://// is the same file, the same server: no second LSP.
    text, err = ask(18, "file:///" + os.path.join(sb.fixture, "a.stub"))
    check(not err and '"status":"single"' in text, "file:////abs: %r %s" % (err, text))
    lsps = sb.status()["lsps"]
    check(len(lsps) == 1, "file:////abs must reuse the one server: %r" % lsps)


def t_pull_capability_follows_mode(sb):
    """#8: pull diagnostics (textDocument.diagnostic) are advertised only to
    a server pharos runs in Pull mode. Advertised to rust-analyzer (Push),
    they moved its own diagnostics to pull, which pharos never asked for."""
    with open(os.path.join(sb.fixture, ".pharos.toml"), "w") as f:
        f.write('[languages.stub]\nfile_extensions = [".stub"]\n'
                'root_markers = ["stub.root"]\ncommand = "%s"\n'
                '[languages.stubpull]\nfile_extensions = [".stubpull"]\n'
                'root_markers = ["stub.root"]\ncommand = "%s"\ndiagnostics_mode = "pull"\n' % (STUB, STUB))
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    hover_line(a, stub_file(sb, "a.stub", "one\n"), 10)
    hover_line(a, stub_file(sb, "b.stubpull", "two\n"), 11)
    inits = [l for l in open(os.path.join(sb.fixture, "stub.log")) if " initialize " in l]
    pulls = sorted(l.rsplit("pull=", 1)[-1].strip() for l in inits)
    check(pulls == ["False", "True"], "expected one Push (pull=False) and one Pull (pull=True) initialize: %r" % inits)
def readiness_toml(sb):
    sb.write_toml('readiness_token = "stub/index"\nready_timeout_ms = 30000\n')


def t_readiness_split_publish_is_kept(sb):
    """#33 (verifier's scenario): during the readiness wait pharos reads in
    200 ms windows, and one that timed out dropped the part of a frame read
    so far. A startup publish split across windows was lost. It's kept
    now, and the stream stays aligned."""
    readiness_toml(sb)
    path = os.path.join(sb.fixture, "c.stub")
    with open(path, "w") as f:
        f.write("three\n")
    a = sb.start({"STUB_LSP_EARLY_PUBLISH_SPLIT": path + ":500", "STUB_LSP_PROGRESS": "stub/index:1500",
                  "STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    d = a.tool(10, "get_diagnostics", {"uri": "file://" + path, "timeout_ms": 5000})
    check("early split publish" in d, "the split startup publish was lost: %s" % d[-300:])
    h = hover_line(a, stub_file(sb, "a.stub", "one\n"), 11)
    check("line 0: one" in h, "the stream desynced after the split publish: %s" % h[-300:])


def t_readiness_without_progress(sb):
    """#12: a server that reports no progress is ready after a short grace.
    The old wait read its remaining budget to decide the grace was over, so
    it waited out the whole ready_timeout_ms (about 59 s for every cold
    rust-analyzer, gopls and pyright)."""
    readiness_toml(sb)
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    t0 = time.time()
    check("line 0: one" in hover_line(a, stub_file(sb, "a.stub", "one\n"), 10), "hover")
    took = time.time() - t0
    check(took < 6, "cold hover took %.1fs: the readiness wait ran to its budget" % took)


def t_readiness_any_token(sb):
    """#12: progress under a token other than the configured one (rust-
    analyzer renamed its indexing token) still holds readiness until it
    ends, and pharos advertises window.workDoneProgress so servers report
    it at all."""
    readiness_toml(sb)
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line", "STUB_LSP_PROGRESS": "renamed/cachePriming:3000"})
    a.initialize()
    t0 = time.time()
    check("line 0: two" in hover_line(a, stub_file(sb, "b.stub", "two\n"), 10), "hover")
    took = time.time() - t0
    check(3.0 <= took < 10, "cold hover took %.1fs: expected to wait for the progress to end (3 s), not the budget" % took)


def t_readiness_keeps_early_publish(sb):
    """#12: a publishDiagnostics that arrives during the readiness wait,
    before pharos opens the file (cargo check's does), is cached, not
    dropped."""
    readiness_toml(sb)
    path = os.path.join(sb.fixture, "c.stub")
    with open(path, "w") as f:
        f.write("three\n")
    a = sb.start({"STUB_LSP_EARLY_PUBLISH": path})
    a.initialize()
    d = a.tool(10, "get_diagnostics", {"uri": "file://" + path, "timeout_ms": 5000})
    check("early publish" in d, "the early publish must be kept: %s" % d[-300:])


def t_cli_no_reply_is_unsure(sb):
    """#12: when the daemon can't answer within --timeout-ms (a server still
    starting), `pharos diagnostics` reports the file unsure, reason
    no_reply, instead of exiting with a raw EAGAIN."""
    path = os.path.join(sb.fixture, "d.stub")
    with open(path, "w") as f:
        f.write("four\n")
    t0 = time.time()
    out = sb.cli("diagnostics", "--json", "--timeout-ms", "1000", path,
                 extra_env={"STUB_LSP_INIT_DELAY_MS": "20000"}, timeout=60, cwd=sb.fixture)
    took = time.time() - t0
    check(out.returncode == 0, "exit %d: %s" % (out.returncode, out.stderr[-300:]))
    f = json.loads(out.stdout)["files"][0]
    check(f["status"] == "unsure" and f["reason"] == "no_reply", "expected unsure/no_reply: %s" % f)
    check(took < 18, "took %.1fs" % took)


def t_frames_after_a_reply_are_handled(sb):
    """#25: a publish that reaches pharos in the same read as a reply (zls
    often sends them together) was left in the buffer until the server sent
    something else; a quiet server doesn't, so get_diagnostics waited out
    its timeout. Frames left after a reply are handled at once."""
    a = sb.start({"STUB_LSP_PUBLISH_WITH_REPLY": "1", "STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "one\n")
    hover_line(a, uri, 10)
    t0 = time.time()
    d = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 8000})
    took = time.time() - t0
    check("published with the reply" in d, "the publish read with the reply was lost: %s" % d[-300:])
    check(took < 3, "took %.1fs" % took)


def t_check_on_save_answers_the_new_text(sb):
    """#30: rust-analyzer republishes cargo check's old results at the new
    version until the check it reruns on save ends. get_diagnostics waits
    while a progress that began after the sync is still running, so a fixed
    file isn't answered with its old error as fresh."""
    # The server is configured like rust-analyzer: a save's check gets
    # 500 ms to begin.
    sb.write_toml("save_check_grace_ms = 500\n")
    a = sb.start({"STUB_LSP_CHECK_ON_SAVE": "1500", "STUB_LSP_SYNC_SAVE": "true",
                  "STUB_LSP_PROGRESS": "stub/priming:200"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    d1 = a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    check("stub error on line 1" in d1, "first answer: %s" % d1[-300:])
    stub_file(sb, "main.stub", "ok\nfixed\n")
    t0 = time.time()
    d2 = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    took = time.time() - t0
    check("stub error" not in d2 and "carried_over" not in d2, "answered the old error after the fix: %s" % d2[-300:])
    check(1.0 <= took < 6, "took %.1fs: expected to wait for the check (1.5 s)" % took)


def t_check_that_never_ends_is_bounded(sb):
    """#30: a check that doesn't end within the call's timeout doesn't hold
    the answer past it, and what's cached then is answered as carried over
    (unsure), not as fresh."""
    # No startup progress: the save's check is the server's first. Before
    # save_check_grace_ms its begin could land after the answer was taken
    # as fresh, 3 runs in 600 (verifier); the grace now applies whether or
    # not the server reported progress before.
    sb.write_toml("save_check_grace_ms = 500\n")
    a = sb.start({"STUB_LSP_CHECK_ON_SAVE": "600000", "STUB_LSP_SYNC_SAVE": "true"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 20000})
    stub_file(sb, "main.stub", "ok\nfixed\n")
    t0 = time.time()
    d = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 2000})
    took = time.time() - t0
    check(took < 4, "took %.1fs: the wait passed the call's timeout" % took)
    check("carried_over" in d, "an answer during an unfinished check must be marked: %s" % d[-300:])


def t_frames_after_an_error_reply_are_kept(sb):
    """#31: a publish in the same read as an error reply was discarded:
    the proc continued with the client from before the request. It's kept
    now, like one behind a success (#25)."""
    a = sb.start({"STUB_LSP_ERROR_WITH_PUBLISH": "-32603", "STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "one\n")
    hover_line(a, uri, 10)
    d = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 5000})
    check("published behind an error" in d, "the publish behind the error was lost: %s" % d[-300:])


def t_split_frame_after_an_error_keeps_the_stream(sb):
    """#31: with half a frame behind an error reply (ContentModified, which
    pharos retries), dropping the read bytes desynced the stream: the next
    request failed with a framing error. Now the publish arrives whole and
    the next request answers."""
    a = sb.start({"STUB_LSP_ERROR_WITH_PUBLISH": "-32801:split", "STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "one\ntwo\n")
    hover_line(a, uri, 10)
    time.sleep(0.6)
    d = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 5000})
    check("published behind an error" in d, "the split publish was lost: %s" % d[-300:])
    h = hover_line(a, uri, 12, line=1)
    check("line 1: two" in h and "framing" not in h, "the stream desynced: %s" % h[-300:])


def t_find_symbol_null_result(sb):
    """#26: a `null` workspace/symbol result (perlnavigator, lua-ls) is no
    matches: find_symbol still drills scope_uri, and workspace_symbols
    answers an empty list, not a decode error or `null`."""
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "null"})
    a.initialize()
    uri = stub_file(sb, "a.stub", "function helper() {\n}\n")
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    check('"status":"single"' in out and "decode failed" not in out, "find_symbol: %s" % out[-300:])
    out = a.tool(11, "workspace_symbols", {"workspace_uri_hint": uri, "query": "helper"})
    check('"matches":[]' in out.replace(" ", ""), "workspace_symbols: %s" % out[-300:])


def t_find_symbol_prefers_the_workspace(sb):
    """#29: with jdtls, find_symbol "helper" answered "single" with a JDK
    class `Helper`: the server matches case-insensitively, names methods
    `helper(int)` (so no exact match), and library results weren't ranked
    below workspace ones. Now a parameter list is stripped for the exact
    match, scope_uri is always drilled, and workspace files beat
    dependencies."""
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "all", "STUB_LSP_SYMBOL_PARAMS": "1"})
    a.initialize()
    lib = os.path.join(sb.fixture, "node_modules", "lib")
    os.makedirs(lib)
    with open(os.path.join(lib, "dep.stub"), "w") as f:
        f.write("function Helper() {\n}\nfunction helper() {\n}\n")
    uri = stub_file(sb, "util.stub", "function helper() {\n}\n")
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    check('"status":"single"' in out and "util.stub" in out and "node_modules" not in out,
          "expected the workspace helper alone: %s" % out[-400:])


def t_find_symbol_library_guess_is_a_near_miss(sb):
    """#29: a match only in another case, and only outside the workspace,
    is a near miss, not "single": a lowercase `helper` must not resolve to
    a dependency's `Helper` class."""
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "all"})
    a.initialize()
    lib = os.path.join(sb.fixture, "node_modules", "lib")
    os.makedirs(lib)
    with open(os.path.join(lib, "dep.stub"), "w") as f:
        f.write("function Helper() {\n}\n")
    uri = stub_file(sb, "main.stub", "function other() {\n}\n")
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    check('"status":"not_found"' in out and "Helper" in out and "near misses" in out,
          "expected a near miss, not an answer: %s" % out[-400:])


def t_find_symbol_library_outside_the_root(sb):
    """#29 (verifier): a library outside the workspace root, at a path no
    dependency-dir list names (a GOROOT, /usr/include), isn't a workspace
    match: a case-only or partial match there is a near miss. gopls answered
    `println` with fmt's Fprintln, Println and Sprintln as matches."""
    lib = os.path.join(sb.dir, "goroot", "src", "fmt")
    os.makedirs(lib)
    with open(os.path.join(lib, "print.stub"), "w") as f:
        f.write("function Println() {\n}\nfunction Sprintln() {\n}\n")
    # A real GOROOT has its own go.mod: pharos can open its files.
    open(os.path.join(sb.dir, "goroot", "stub.root"), "w").close()
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "all", "STUB_LSP_EXTRA_SYMBOL_DIR": os.path.join(sb.dir, "goroot")})
    a.initialize()
    uri = stub_file(sb, "main.stub", "function main() {\n}\n")
    out = a.tool(10, "find_symbol", {"name_path": "println", "scope_uri": uri})
    check('"status":"not_found"' in out and "Println" in out, "expected near misses, not matches: %s" % out[-400:])


def t_find_symbol_says_why_it_was_narrow(sb):
    """#28: on a server that can't search the workspace (zls, gleam),
    not_found means "not in scope_uri", and the answer says so."""
    a = sb.start({"STUB_LSP_WORKSPACE_SYMBOL": "none"})
    a.initialize()
    uri = stub_file(sb, "b.stub", "function other() {\n}\n")
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    check('"status":"not_found"' in out and "only scope_uri was searched" in out, "not_found: %s" % out[-300:])


def _cold_find(sb, env, toml=""):
    # The helper is defined in another file, so only workspace/symbol can
    # find it: find_symbol drills scope_uri's own symbols first.
    sb.write_toml('diagnostics_mode = "push"\n' + toml)
    a = sb.start(dict({"STUB_LSP_WORKSPACE_SYMBOL": "all"}, **env))
    a.initialize()
    stub_file(sb, "a.stub", "function helper() {\n  return 1;\n}\n")
    uri = stub_file(sb, "b.stub", "helper();\n")
    return a, uri


def t_find_symbol_cold_index_while_indexing(sb):
    """#27: a server that indexes in the background (clangd, HLS) answers a
    cold session's first searches empty. While its indexing progress runs,
    an empty search is asked again, so the symbol is found."""
    a, uri = _cold_find(sb, {"STUB_LSP_INDEX_DELAY_MS": "4000", "STUB_LSP_INDEX_PROGRESS": "1"})
    t0 = time.time()
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    took = time.time() - t0
    check('"status":"single"' in out, "cold find_symbol: %s" % out[-300:])
    check(took < 10, "took %.1fs" % took)


def t_find_symbol_cold_index_lazy_flag(sb):
    """#27: a server that indexes without reporting progress (clangd, HLS,
    bash-ls, next-ls) has a lazy_workspace_index_ms window; an empty search
    in it is retried."""
    a, uri = _cold_find(sb, {"STUB_LSP_INDEX_DELAY_MS": "3000"}, "lazy_workspace_index_ms = 20000\n")
    out = a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    check('"status":"single"' in out, "cold find_symbol, lazy flag: %s" % out[-300:])


def t_find_symbol_cold_miss_is_prompt(sb):
    """#27 (verifier-two): a first-call typo on a server with no window that
    isn't indexing answers at once. Rev 1 retried every miss in a
    session's first 20 s, about 14 s each."""
    a, uri = _cold_find(sb, {})
    t0 = time.time()
    out = a.tool(10, "find_symbol", {"name_path": "absent_zz9", "scope_uri": uri})
    took = time.time() - t0
    check('"status":"not_found"' in out, "cold miss: %s" % out[-200:])
    check(took < 2, "a first-call miss took %.1fs: it was retried" % took)


def t_find_symbol_lazy_retry_is_a_deadline(sb):
    """#27: a server with a long window that never indexes gives up within the cap
    (15 s), not 15 s plus a full request timeout."""
    a, uri = _cold_find(sb, {"STUB_LSP_INDEX_DELAY_MS": "600000"}, "lazy_workspace_index_ms = 20000\n")
    t0 = time.time()
    out = a.tool(10, "find_symbol", {"name_path": "absent_zz9", "scope_uri": uri})
    took = time.time() - t0
    check('"status":"not_found"' in out, "never-indexing: %s" % out[-200:])
    check(took < 16.5, "took %.1fs" % took)


def t_find_symbol_warm_miss_is_prompt(sb):
    """#27: once a session is older than its window, a miss answers
    at once, not after retries."""
    a, uri = _cold_find(sb, {}, "lazy_workspace_index_ms = 20000\n")
    a.tool(10, "find_symbol", {"name_path": "helper", "scope_uri": uri})
    time.sleep(21)
    t0 = time.time()
    out = a.tool(11, "find_symbol", {"name_path": "absent", "scope_uri": uri})
    took = time.time() - t0
    check('"status":"not_found"' in out, "warm miss: %s" % out[-200:])
    check(took < 2, "a warm miss took %.1fs: it was retried" % took)
def t_reply_split_across_a_timeout(sb):
    """#33: a request timed out with half its reply read. The bytes read
    were dropped, so the reply's tail arrived alone and sat, unparseable,
    in front of every later frame: the next request on the healthy server
    timed out too, and the server was restarted. The half is kept now, the
    tail completes the late reply, and the next request answers."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line", "STUB_LSP_SPLIT_FIRST_REPLY": "2000"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "zero\n")
    a.tool(10, "hover", {"uri": uri, "line": 0, "character": 0, "timeout_ms": 1000})
    time.sleep(3)  # every half reply's tail has landed
    pids_before = {l.split()[0] for l in open(os.path.join(sb.fixture, "stub.log")) if l.strip()}
    t0 = time.time()
    h = a.tool(11, "hover", {"uri": uri, "line": 0, "character": 0, "timeout_ms": 5000})
    took = time.time() - t0
    check("line 0: zero" in h, "the request after the split reply failed: %s" % h[-300:])
    pids_after = {l.split()[0] for l in open(os.path.join(sb.fixture, "stub.log")) if l.strip()}
    check(pids_after == pids_before, "the healthy server was restarted: %r -> %r" % (pids_before, pids_after))
    check(took < 2, "took %.1fs" % took)


def t_progress_without_save_check_answers_at_once(sb):
    """#30 follow-up: a server that reports progress but starts no check on
    save (gopls) has no grace, so the first question after an edit doesn't
    wait 500 ms for a check that never comes (0.515 s against 0.003 s)."""
    a = sb.start({"STUB_LSP_DIAGNOSTICS": "push", "STUB_LSP_PROGRESS": "stub/priming:200"})
    a.initialize()
    uri = stub_file(sb, "main.stub", "ok\nERROR one\n")
    d1 = a.tool(10, "get_diagnostics", {"uri": uri, "timeout_ms": 10000})
    check("ERROR one" in d1 or "line 1" in d1, "first answer: %s" % d1[-300:])
    stub_file(sb, "main.stub", "ok\nfine\nERROR two\n")
    t0 = time.time()
    d2 = a.tool(11, "get_diagnostics", {"uri": uri, "timeout_ms": 10000})
    took = time.time() - t0
    check("carried_over" not in d2 and "line 2" in d2, "answer after the edit: %s" % d2[-300:])
    check(took < 0.4, "took %.2fs: waited for a save check the server doesn't run" % took)


def t_server_exit_at_initialize_says_why(sb):
    """#36: a server that exits during its handshake was reported only as
    "client transport failure". Its own reason is written to its stderr,
    which pharos doesn't capture: the error now gives the exit status and
    names where that output went, the daemon's boot log."""
    a = sb.start({"STUB_LSP_EXIT_AT_INITIALIZE": "78"})
    a.initialize()
    out = hover_line(a, sb.uri, 10)
    check("exited with status 78" in out, "no exit status in the error: %s" % out[-300:])
    m = re.search(r"went to (\S+\.boot\.log)", out)
    check(m is not None, "the error doesn't name the boot log: %s" % out[-300:])
    with open(m.group(1)) as f:
        check("refusing to start (test)" in f.read(), "the server's reason isn't in %s" % m.group(1))


def t_resync_open_cap(sb):
    """At most 32 documents stay open per server; the least recently asked
    about is closed."""
    a = sb.start({"STUB_LSP_HOVER_RESPONSES": "line"})
    a.initialize()
    uris = [stub_file(sb, "f%02d.stub" % i, "f%d\n" % i) for i in range(33)]
    for i, uri in enumerate(uris):
        hover_line(a, uri, 100 + i)
    closes = [l for l in sync_lines(sb) if l.startswith("textDocument/didClose")]
    check(closes == ["textDocument/didClose f00.stub"], "expected only f00 closed: %r" % closes)
    check("line 0: f0" in hover_line(a, uris[0], 200), "reopen after close")
    check(any("didOpen f00.stub v=2" in l for l in sync_lines(sb)),
          "a reopen must go out at the next version: %r" % sync_lines(sb)[-5:])


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
    ("cli_new_language", t_cli_new_language),
    ("process_id", t_process_id),
    ("reap_on_stop", t_reap_on_stop),
    ("reap_on_idle", t_reap_on_idle),
    ("reap_after_death", t_reap_after_death),
    ("resync_follows_disk", t_resync_follows_disk),
    ("resync_shared_sessions", t_resync_shared_sessions),
    ("resync_other_open_documents", t_resync_other_open_documents),
    ("resync_sync_kind_none", t_resync_sync_kind_none),
    ("resync_unchanged_diagnostics", t_resync_unchanged_diagnostics),
    ("resync_open_cap", t_resync_open_cap),
    ("resync_settles_after_window", t_resync_settles_after_window),
    ("resync_subject_deleted", t_resync_subject_deleted),
    ("tsserver_answers_new_text", t_tsserver_answers_new_text),
    ("tsserver_falls_back_to_push", t_tsserver_falls_back_to_push),
    ("tsserver_failed_fallback_is_marked", t_tsserver_failed_fallback_is_marked),
    ("tsserver_timed_out_fallback_is_marked", t_tsserver_timed_out_fallback_is_marked),
    ("diagnostics_cli", t_diagnostics_cli),
    ("diagnostics_cli_unknown_project", t_diagnostics_cli_unknown_project),
    ("diagnostics_cli_busy_tsserver", t_diagnostics_cli_busy_tsserver),
    ("diagnostics_cli_project_timeout", t_diagnostics_cli_project_timeout),
    ("document_language_id", t_document_language_id),
    ("frames_after_an_error_reply_are_kept", t_frames_after_an_error_reply_are_kept),
    ("reply_split_across_a_timeout", t_reply_split_across_a_timeout),
    ("server_exit_at_initialize_says_why", t_server_exit_at_initialize_says_why),
    ("readiness_split_publish_is_kept", t_readiness_split_publish_is_kept),
    ("split_frame_after_an_error_keeps_the_stream", t_split_frame_after_an_error_keeps_the_stream),
    ("frames_after_a_reply_are_handled", t_frames_after_a_reply_are_handled),
    ("check_on_save_answers_the_new_text", t_check_on_save_answers_the_new_text),
    ("check_that_never_ends_is_bounded", t_check_that_never_ends_is_bounded),
    ("progress_without_save_check_answers_at_once", t_progress_without_save_check_answers_at_once),
    ("find_symbol_null_result", t_find_symbol_null_result),
    ("find_symbol_prefers_the_workspace", t_find_symbol_prefers_the_workspace),
    ("find_symbol_says_why_it_was_narrow", t_find_symbol_says_why_it_was_narrow),
    ("find_symbol_library_outside_the_root", t_find_symbol_library_outside_the_root),
    ("find_symbol_library_guess_is_a_near_miss", t_find_symbol_library_guess_is_a_near_miss),
    ("find_symbol_cold_index_while_indexing", t_find_symbol_cold_index_while_indexing),
    ("find_symbol_cold_index_lazy_flag", t_find_symbol_cold_index_lazy_flag),
    ("find_symbol_cold_miss_is_prompt", t_find_symbol_cold_miss_is_prompt),
    ("find_symbol_lazy_retry_is_a_deadline", t_find_symbol_lazy_retry_is_a_deadline),
    ("find_symbol_warm_miss_is_prompt", t_find_symbol_warm_miss_is_prompt),
    ("pull_capability_follows_mode", t_pull_capability_follows_mode),
    ("readiness_without_progress", t_readiness_without_progress),
    ("readiness_any_token", t_readiness_any_token),
    ("readiness_keeps_early_publish", t_readiness_keeps_early_publish),
    ("cli_no_reply_is_unsure", t_cli_no_reply_is_unsure),
    ("long_runtime_dir", t_long_runtime_dir),
    ("non_ascii_home_and_server_path", t_non_ascii_home_and_server_path),
    ("non_ascii_home_default_state", t_non_ascii_home_default_state),
    ("non_ascii_c_locale", t_non_ascii_c_locale),
    ("uri_escapes_push_vscode", t_uri_escapes_push_vscode),
    ("uri_escapes_push_rust", t_uri_escapes_push_rust),
    ("uri_escapes_tsserver", t_uri_escapes_tsserver),
    ("uri_escapes_cli", t_uri_escapes_cli),
    ("apply_edit_failure_is_an_error", t_apply_edit_failure_is_an_error),
    ("find_symbol_cold_session", t_find_symbol_cold_session),
    ("find_symbol_bad_scope", t_find_symbol_bad_scope),
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
