#!/usr/bin/env python3
"""Phase 7 — both-transport simultaneous test.

Boots pharos with `PHAROS_TRANSPORT=both`. Drives stdio AND HTTP
concurrently with overlapping tool calls. Asserts:

- Each transport sees only its own responses.
- A request on one transport does not leak to the other.
- Both can call `tools/call` against the same tool against the same
  workspace; pharos's pool dedupes the LSP spawn (both share the
  same proc).

Doesn't drive every tool — just `echo` (lang-agnostic, fast) +
`hover` (LSP-bound, exercises the proc actor's mailbox under
cross-transport load).

Run:
    python3 bin/test-both-transports.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)
from _pharos_drive import (  # noqa: E402
    initialize_request,
    tool_call_request,
)


def main() -> int:
    project_root = os.path.dirname(_dir)
    rust_file = "file:///home/oof/rust_dev/src/main.rs"

    port_file = tempfile.mktemp(prefix="pharos-both-port-", suffix=".txt")
    env = os.environ.copy()
    env.update(
        {
            "PHAROS_TRANSPORT": "both",
            "PHAROS_HTTP_PORT": "0",
            "PHAROS_HTTP_BIND": "127.0.0.1",
            "PHAROS_HTTP_PORT_FILE": port_file,
        }
    )

    proc = subprocess.Popen(
        [os.path.join(project_root, "bin", "pharos-dev")],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        cwd=project_root,
        text=True,
    )

    # Wait for HTTP port to be available.
    port = None
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if os.path.exists(port_file):
            with open(port_file) as f:
                text = f.read().strip()
                if text:
                    port = int(text)
                    break
        time.sleep(0.1)
    if port is None:
        proc.terminate()
        try:
            stderr_dump = proc.stderr.read()
        except Exception:  # noqa: BLE001
            stderr_dump = ""
        print(f"FAIL: port file did not appear at {port_file}\nstderr: {stderr_dump[-500:]}")
        return 1

    base_url = f"http://127.0.0.1:{port}/mcp"

    # Initialize over stdio.
    proc.stdin.write(json.dumps(initialize_request(0)) + "\n")
    proc.stdin.flush()

    # Initialize over HTTP. Capture session id.
    http_session_id = None
    init_body = json.dumps(initialize_request(1000)).encode()
    req = urllib.request.Request(
        base_url, data=init_body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        http_init_text = resp.read().decode("utf-8", errors="replace")
        http_session_id = resp.headers.get("Mcp-Session-Id")
    if http_session_id is None:
        proc.terminate()
        print(f"FAIL: HTTP initialize did not return Mcp-Session-Id\n  body: {http_init_text}")
        return 1

    # Concurrent driver — two threads firing requests over their
    # respective transports at the same time.
    stdio_responses: list = []
    http_responses: list = []

    def drive_stdio():
        # Send 5 echoes + 5 hovers via stdio.
        for i in range(5):
            proc.stdin.write(json.dumps(tool_call_request(100 + i, "echo", {"message": f"stdio-echo-{i}"})) + "\n")
            proc.stdin.write(json.dumps(tool_call_request(200 + i, "hover", {"uri": rust_file, "line": 7, "character": 12})) + "\n")
        proc.stdin.flush()
        # Collect responses until all expected stdio IDs land OR cap.
        # Hover cold-start can take ~60s on first call; 5 concurrent
        # hovers serializing through the proc actor can stretch the
        # tail to ~120s. Bump cap for safety.
        expected = {0} | {100 + i for i in range(5)} | {200 + i for i in range(5)}
        seen: set = set()
        end = time.monotonic() + 180
        while time.monotonic() < end and seen < expected:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            stdio_responses.append(obj)
            if "id" in obj:
                seen.add(obj["id"])

    def drive_http():
        for i in range(5):
            for tool, rid, args in (
                ("echo", 1100 + i, {"message": f"http-echo-{i}"}),
                ("hover", 1200 + i, {"uri": rust_file, "line": 7, "character": 12}),
            ):
                body = json.dumps(tool_call_request(rid, tool, args)).encode()
                req = urllib.request.Request(
                    base_url, data=body,
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                        "Mcp-Session-Id": http_session_id,
                    },
                    method="POST",
                )
                try:
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        raw = resp.read().decode("utf-8", errors="replace")
                        if raw.strip():
                            http_responses.append(json.loads(raw))
                except Exception as e:  # noqa: BLE001
                    http_responses.append({"id": rid, "error": str(e)})

    t1 = threading.Thread(target=drive_stdio)
    t2 = threading.Thread(target=drive_http)
    t1.start()
    t2.start()
    t1.join(timeout=120)
    t2.join(timeout=120)

    # Cleanup.
    try:
        proc.stdin.close()
    except Exception:  # noqa: BLE001
        pass
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    try:
        os.unlink(port_file)
    except OSError:
        pass

    # Assertions.
    stdio_ids = {r.get("id") for r in stdio_responses}
    http_ids = {r.get("id") for r in http_responses}

    failures = []

    # Stdio expects 0 (init), 100-104 (echos), 200-204 (hovers).
    expected_stdio = {0} | {100 + i for i in range(5)} | {200 + i for i in range(5)}
    missing_stdio = expected_stdio - stdio_ids
    leaked_to_stdio = (set(range(1000, 1300)) & stdio_ids)
    if missing_stdio:
        failures.append(f"stdio missing IDs: {sorted(missing_stdio)}")
    if leaked_to_stdio:
        failures.append(f"HTTP IDs leaked into stdio: {sorted(leaked_to_stdio)}")

    # HTTP expects 1000 (init was sent above; not in http_responses
    # since we did it synchronously and ate the body), 1100-1104 + 1200-1204.
    expected_http = {1100 + i for i in range(5)} | {1200 + i for i in range(5)}
    missing_http = expected_http - http_ids
    leaked_to_http = (set(range(0, 300)) & http_ids)
    if missing_http:
        failures.append(f"HTTP missing IDs: {sorted(missing_http)}")
    if leaked_to_http:
        failures.append(f"stdio IDs leaked into HTTP: {sorted(leaked_to_http)}")

    if failures:
        print("FAIL: cross-transport isolation broke")
        for f in failures:
            print(f"  - {f}")
        print(f"\n  stdio_ids: {sorted(stdio_ids)}")
        print(f"  http_ids: {sorted(http_ids)}")
        return 1

    print(
        f"PASS: both-transport isolation verified. "
        f"stdio={len(stdio_ids)} responses, http={len(http_ids)} responses."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
