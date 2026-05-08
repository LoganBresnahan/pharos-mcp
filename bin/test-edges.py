#!/usr/bin/env python3
"""Phase 5 — edge-case harness. Stub-LSP-driven for determinism.

Pins pharos to the bin/_stub_lsp.py via a temp pharos.toml that
defines a `stub` language with file_extensions=[".stub"] and
command = bin/_stub_lsp.py. Stub LSP behavior is controlled by
STUB_LSP_* env vars; harness sets the appropriate vars per cell.

Tests:
  1. content-modified retry — stub returns -32801 on first hover,
     real result on second. Pharos's
     `request_with_content_modified_retry` should land the second
     attempt; harness gets the real result.
  2. handshake delay — stub delays initialize by 5s; pharos's 90s
     init budget covers; harness completes successfully.

Run:
    python3 bin/test-edges.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)
from _pharos_drive import (  # noqa: E402
    drive,
    find_response,
    initialize_request,
    tool_call_request,
    tool_text,
)


STUB_LSP = os.path.join(_dir, "_stub_lsp.py")


def _toml(stub_lsp: str) -> str:
    # NEW-language overrides only honor FLAT fields per pharos's
    # `partial_to_full` path in registry.gleam. The nested
    # `[[languages.<id>.servers]]` shape is for PATCHING servers in
    # bundled languages. For a brand-new language like `stub`, command
    # must be at the top level.
    return f"""[languages.stub]
file_extensions = [".stub"]
root_markers = [".git"]
command = "{stub_lsp}"
"""


def _run_with_overrides(env_overrides, requests, timeout=60):
    cfg = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False)
    try:
        cfg.write(_toml(STUB_LSP))
        cfg.close()
        env = dict(env_overrides or {})
        env["PHAROS_CONFIG_FILE"] = cfg.name
        responses, stderr = drive(env, requests, timeout=timeout)
        return responses, stderr
    finally:
        try:
            os.unlink(cfg.name)
        except OSError:
            pass


def test_content_modified_retry() -> tuple[bool, str]:
    workspace = "/home/oof/stub_dev"
    if not os.path.isdir(workspace):
        return False, f"setup: {workspace} missing (run mkdir + git init beforehand)"

    file_uri = f"file://{workspace}/main.stub"
    requests = [
        initialize_request(0),
        tool_call_request(
            1, "hover",
            {"uri": file_uri, "line": 0, "character": 0},
        ),
    ]
    responses, stderr = _run_with_overrides(
        {"STUB_LSP_HOVER_RESPONSES": "content_modified"},
        requests,
        timeout=30,
    )
    init = find_response(responses, 0)
    if not init or "result" not in init:
        return False, f"init failed: stderr {stderr[-300:]}"
    r = find_response(responses, 1)
    if r is None:
        return False, f"hover: no response. stderr {stderr[-300:]}"
    text = tool_text(r)
    if "stub hover (after retry)" in text:
        return True, "content-modified retry landed on attempt 2 (text from stub_lsp's retry branch)"
    return False, f"hover did not surface retry-success text: {text[:300]}"


def test_handshake_delay() -> tuple[bool, str]:
    workspace = "/home/oof/stub_dev"
    if not os.path.isdir(workspace):
        return False, f"setup: {workspace} missing"

    file_uri = f"file://{workspace}/main.stub"
    requests = [
        initialize_request(0),
        tool_call_request(
            1, "hover",
            {"uri": file_uri, "line": 0, "character": 0},
        ),
    ]
    responses, stderr = _run_with_overrides(
        {"STUB_LSP_INIT_DELAY_MS": "5000"},
        requests,
        timeout=60,
    )
    init = find_response(responses, 0)
    if not init or "result" not in init:
        return False, f"init failed: stderr {stderr[-300:]}"
    r = find_response(responses, 1)
    if r is None:
        return False, "hover: no response after delayed handshake"
    return True, "5s init delay tolerated; hover landed"


def main() -> int:
    cells = [
        ("content_modified_retry", *test_content_modified_retry()),
        ("handshake_delay", *test_handshake_delay()),
    ]
    passed = sum(1 for _, ok, _ in cells if ok)
    total = len(cells)
    for name, ok, msg in cells:
        marker = "PASS" if ok else "FAIL"
        print(f"  {marker} {name}: {msg}")
    print(f"\n=== {passed}/{total} cells PASS ===")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
