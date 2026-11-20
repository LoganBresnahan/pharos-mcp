#!/usr/bin/env python3
"""bin/pharos-dev keeps stdout to JSON-RPC frames (invariant 1, #9).

Runs the wrapper as an MCP stdio server with SASL's reports on (the
default) and off, and with its stdio as pipes and as socketpairs, the way
Claude Code's libuv runs MCP servers. In every case stdout must be
exactly the three responses, the server must stay up while stdin is
open, and, with SASL on, the progress reports must reach stderr. The
socket case matters: a SASL handler writing to /dev/stderr couldn't open
it (ENXIO), and the node shut down.

    python3 -I test/dev_wrapper_stdio.py [path/to/bin/pharos-dev]
"""
import os
import select
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(HERE), "bin", "pharos-dev")
MESSAGES = [
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}',
    '{"jsonrpc":"2.0","method":"initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"smoke"}}}',
]


def run(sasl, sockets, timeout=180):
    env = dict(os.environ, PHAROS_SASL=sasl)
    if sockets:
        pairs = [socket.socketpair() for _ in range(3)]
        p = subprocess.Popen([WRAPPER], stdin=pairs[0][1].fileno(), stdout=pairs[1][1].fileno(),
                             stderr=pairs[2][1].fileno(), env=env)
        for s in pairs:
            s[1].close()
        stdin, out_r, err_r = pairs[0][0], pairs[1][0], pairs[2][0]
        stdin.sendall(("\n".join(MESSAGES) + "\n").encode())
        recv = lambda s: s.recv(65536)
    else:
        p = subprocess.Popen([WRAPPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        p.stdin.write(("\n".join(MESSAGES) + "\n").encode())
        p.stdin.flush()
        out_r, err_r = p.stdout, p.stderr
        recv = lambda f: os.read(f.fileno(), 65536)
    out, err, t0 = b"", b"", time.time()
    # Wait for the three responses, then a moment more for stray output.
    deadline = None
    while time.time() - t0 < timeout:
        if out.count(b"\n") >= 3 and deadline is None:
            deadline = time.time() + 2
        if deadline and time.time() > deadline:
            break
        r, _, _ = select.select([out_r, err_r], [], [], 0.5)
        for s in r:
            d = recv(s)
            if s is out_r:
                out += d
            else:
                err += d
    alive = p.poll() is None
    p.kill()
    p.wait()
    lines = [l for l in out.decode(errors="replace").split("\n") if l]
    return lines, alive, err


def main():
    failed = 0
    for sasl in ("1", "0"):
        for sockets in (False, True):
            lines, alive, err = run(sasl, sockets)
            json_lines = [l for l in lines if l.startswith('{"jsonrpc"')]
            progress = err.count(b"PROGRESS REPORT")
            ok = len(lines) == 3 and len(json_lines) == 3 and alive and (progress > 0) == (sasl == "1")
            print("%s PHAROS_SASL=%s %-7s stdout %d lines (%d JSON-RPC), alive %s, stderr PROGRESS %d" % (
                "PASS" if ok else "FAIL", sasl, "sockets" if sockets else "pipes", len(lines), len(json_lines), alive, progress))
            if not ok:
                failed += 1
                print("  stdout: %r" % lines[:5])
                print("  stderr tail: %r" % err[-400:])
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
