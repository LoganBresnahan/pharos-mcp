"""HTTP-transport analogue of `_pharos_drive.py`.

Spawns pharos with `PHAROS_TRANSPORT=http PHAROS_HTTP_PORT=0
PHAROS_HTTP_PORT_FILE=...`. Polls the port-file for the bound port,
then drives JSON-RPC requests via `POST http://127.0.0.1:<port>/mcp`.
Captures `Mcp-Session-Id` from the initialize response and includes
it on every subsequent request (M8 stage 0 session routing).

Same return shape as `_pharos_drive.drive` so existing test harnesses
can swap transports by importing from here instead.

Required: Python `requests` (stdlib `urllib.request` would also work
but requests is cleaner for headers + retries; if `requests` is not
installed, fall back to urllib).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def drive(env_overrides, requests_list, timeout=60, expected_ids=None):
    """Run pharos with HTTP transport and drive JSON-RPC over HTTP.

    Returns (responses, stderr_string) — same shape as the stdio
    drive() so existing harness code can switch transports by
    swapping the import.
    """
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = os.environ.copy()
    env.update(env_overrides)
    port_file = tempfile.mktemp(prefix="pharos-http-port-", suffix=".txt")
    env.update(
        {
            "PHAROS_TRANSPORT": "http",
            "PHAROS_HTTP_PORT": "0",  # auto-assign
            "PHAROS_HTTP_BIND": "127.0.0.1",
            "PHAROS_HTTP_PORT_FILE": port_file,
        }
    )

    if expected_ids is None:
        expected_ids = [r["id"] for r in requests_list if "id" in r]

    bin_path = os.environ.get(
        "PHAROS_TEST_BIN", os.path.join(project_root, "bin", "pharos-dev")
    )
    proc = subprocess.Popen(
        [bin_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,  # HTTP transport doesn't use stdout
        stderr=subprocess.PIPE,
        env=env,
        cwd=project_root,
    )

    # Wait for port file to appear (mist's after_start writes it).
    port = None
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if os.path.exists(port_file):
            try:
                with open(port_file) as f:
                    text = f.read().strip()
                    if text:
                        port = int(text)
                        break
            except (OSError, ValueError):
                pass
        time.sleep(0.1)
    if port is None:
        proc.terminate()
        try:
            stderr = proc.stderr.read().decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            stderr = ""
        return [], f"port file did not appear at {port_file}\n--stderr--\n{stderr}"

    base_url = f"http://127.0.0.1:{port}/mcp"
    responses = []
    session_id = None
    try:
        for req in requests_list:
            headers = {"Content-Type": "application/json", "Accept": "application/json"}
            if session_id is not None:
                headers["Mcp-Session-Id"] = session_id
            body = json.dumps(req).encode("utf-8")
            try:
                http_req = urllib.request.Request(
                    base_url, data=body, headers=headers, method="POST"
                )
                with urllib.request.urlopen(http_req, timeout=timeout) as resp:
                    raw = resp.read().decode("utf-8", errors="replace")
                    # Capture session id from the initialize response.
                    sid = resp.headers.get("Mcp-Session-Id")
                    if sid and session_id is None:
                        session_id = sid
                    if raw.strip():
                        try:
                            responses.append(json.loads(raw))
                        except json.JSONDecodeError:
                            pass
            except urllib.error.HTTPError as e:
                body_text = e.read().decode("utf-8", errors="replace") if e.fp else ""
                responses.append(
                    {
                        "jsonrpc": "2.0",
                        "id": req.get("id"),
                        "error": {
                            "code": -32000,
                            "message": f"HTTP {e.code}: {body_text[:300]}",
                        },
                    }
                )
            except Exception as e:  # noqa: BLE001
                responses.append(
                    {
                        "jsonrpc": "2.0",
                        "id": req.get("id"),
                        "error": {
                            "code": -32001,
                            "message": f"transport: {type(e).__name__}: {e}",
                        },
                    }
                )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        try:
            stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
        except Exception:  # noqa: BLE001
            stderr = ""
        try:
            os.unlink(port_file)
        except OSError:
            pass

    return responses, stderr


# Re-export the helpers so HTTP harnesses can import from here OR
# from _pharos_drive depending on transport.
def initialize_request(rid=1):
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "pharos-test-http", "version": "0.0.1"},
        },
    }


def tool_call_request(rid, name, arguments):
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }


def find_response(responses, rid):
    return next((r for r in responses if r.get("id") == rid), None)


def tool_text(response):
    if not response or "result" not in response:
        return ""
    content = response.get("result", {}).get("content", [])
    return "\n".join(
        c.get("text", "") for c in content if c.get("type") == "text"
    )


def tool_is_error(response):
    if not response:
        return False
    return bool(response.get("result", {}).get("isError"))
