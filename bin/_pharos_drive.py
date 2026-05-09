"""Helper to drive pharos via stdio + NDJSON for ad-hoc tests.

Spawns `bin/pharos-dev` (the dev wrapper), sends a list of JSON-RPC
requests on stdin, streams responses on stdout until every expected
id has been seen (or timeout). Used by sibling `test-*` scripts that
exercise boot-time behavior the Claude Code MCP host can't reach
(PATH-stripped LSP-binary resolution, [languages.<id>] overrides, etc.).

Why streaming: closing stdin too early triggers stdio_worker's drain
path, and an LSP-bound request that has not yet responded races
against pool teardown. Streaming lets us wait for every expected
response before sending EOF, with a hard wall-clock cap as the
escape hatch.
"""

import json
import os
import select
import subprocess
import sys
import time


def drive(env_overrides, requests, timeout=20, expected_ids=None):
    """Send `requests` to pharos, stream NDJSON responses until every
    `expected_ids` has been seen (default: all `id` fields from
    `requests`). Returns (responses, stderr_string).

    Closing stdin before all responses arrive triggers stdio_worker's
    drain path; rust-analyzer cold-start (~30-60s) plus 3-4 in-flight
    requests can lose responses if the actor stops mid-flight. Streaming
    + late EOF avoids that.
    """
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = os.environ.copy()
    env.update(env_overrides)

    if expected_ids is None:
        expected_ids = [r["id"] for r in requests if "id" in r]

    # PHAROS_TEST_BIN override — Phase 8 dogfood points this at the
    # burrito-built binary (`burrito_out/pharos_linux_x64`) so the
    # entire harness re-runs against the release runtime. Default is
    # bin/pharos-dev which uses raw `_build/dev/lib/*/ebin`.
    bin_path = os.environ.get(
        "PHAROS_TEST_BIN", os.path.join(project_root, "bin", "pharos-dev")
    )

    proc = subprocess.Popen(
        [bin_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        cwd=project_root,
    )

    for r in requests:
        proc.stdin.write(json.dumps(r) + "\n")
    proc.stdin.flush()

    responses = []
    seen_ids = set()
    deadline = time.monotonic() + timeout
    out_buf = ""
    err_chunks = []

    while time.monotonic() < deadline:
        if expected_ids and seen_ids >= set(expected_ids):
            break
        remaining = deadline - time.monotonic()
        rlist, _, _ = select.select(
            [proc.stdout, proc.stderr], [], [], min(0.5, remaining)
        )
        if proc.stderr in rlist:
            chunk = os.read(proc.stderr.fileno(), 65536).decode(
                "utf-8", errors="replace"
            )
            if chunk:
                err_chunks.append(chunk)
        if proc.stdout in rlist:
            chunk = os.read(proc.stdout.fileno(), 65536).decode(
                "utf-8", errors="replace"
            )
            if not chunk:
                break  # stdout EOF (proc exited)
            out_buf += chunk
            while "\n" in out_buf:
                line, out_buf = out_buf.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                responses.append(obj)
                if "id" in obj:
                    seen_ids.add(obj["id"])

    try:
        proc.stdin.close()
    except (BrokenPipeError, OSError):
        pass

    try:
        tail_out, tail_err = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        tail_out, tail_err = proc.communicate()

    out_buf += tail_out or ""
    err_chunks.append(tail_err or "")
    for line in out_buf.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        responses.append(obj)

    return responses, "".join(err_chunks)


def initialize_request(rid=1):
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "pharos-test", "version": "0.0.1"},
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


if __name__ == "__main__":
    print("This module is a helper. Use bin/test-*.py scripts.", file=sys.stderr)
    sys.exit(2)
