"""Helper to drive pharos via stdio + NDJSON for ad-hoc tests.

Spawns `bin/pharos-dev` (the dev wrapper), sends a list of JSON-RPC
requests on stdin, collects all NDJSON responses on stdout, returns
the parsed list. Used by sibling `test-*` scripts that exercise
boot-time behavior the Claude Code MCP host can't reach (PATH-stripped
LSP-binary resolution, [languages.<id>] overrides, etc.).
"""

import json
import os
import subprocess
import sys


def drive(env_overrides, requests, timeout=20):
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = os.environ.copy()
    env.update(env_overrides)
    proc = subprocess.Popen(
        [os.path.join(project_root, "bin", "pharos-dev")],
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
    proc.stdin.close()
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
    responses = []
    for line in out.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            responses.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return responses, err


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
