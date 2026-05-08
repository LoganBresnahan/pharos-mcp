#!/usr/bin/env python3
"""Phase 2 — lsp_request_raw escape hatch test.

Sends a raw `textDocument/hover` against rust via lsp_request_raw,
asserts the response shape mirrors what the wrapped `hover` tool
would return. Verifies pharos's raw-passthrough doesn't mangle params
or response decoding for the known-working hover method.

Run:
    python3 bin/test-raw.py        # exit 0 = pass
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pharos_drive import (  # noqa: E402
    drive,
    find_response,
    initialize_request,
    tool_call_request,
    tool_is_error,
    tool_text,
)


def main() -> int:
    rust_file = "file:///home/oof/rust_dev/src/main.rs"
    if not os.path.exists("/home/oof/rust_dev/src/main.rs"):
        print("SKIP: /home/oof/rust_dev/src/main.rs missing")
        return 0

    raw_params = {
        "textDocument": {"uri": rust_file},
        "position": {"line": 7, "character": 12},
    }

    requests = [
        initialize_request(0),
        # Wrapped hover for comparison.
        tool_call_request(
            1,
            "hover",
            {"uri": rust_file, "line": 7, "character": 12},
        ),
        # Raw lsp_request_raw with the same target.
        tool_call_request(
            2,
            "lsp_request_raw",
            {
                "uri": rust_file,
                "method": "textDocument/hover",
                "params": raw_params,
            },
        ),
    ]
    responses, stderr = drive({}, requests, timeout=180)

    init = find_response(responses, 0)
    if not init or "result" not in init:
        print(f"FAIL: initialize did not return a result\n  {init}")
        return 1

    wrapped = find_response(responses, 1)
    raw = find_response(responses, 2)

    if not wrapped:
        print(f"FAIL: no wrapped-hover response. stderr tail:\n{stderr[-1000:]}")
        return 1
    if not raw:
        print(f"FAIL: no lsp_request_raw response. stderr tail:\n{stderr[-1000:]}")
        return 1
    if tool_is_error(raw):
        print(f"FAIL: lsp_request_raw marked isError=true: {tool_text(raw)[:300]}")
        return 1

    raw_text = tool_text(raw)
    wrapped_text = tool_text(wrapped)

    # The raw response is the LSP's verbatim result — for hover, that's
    # `{"contents": ..., "range": ...}` or `null`. The wrapped tool's
    # text content is also the LSP body (pharos doesn't re-render
    # hover). Both should contain the same key landmarks if a token is
    # under the cursor; otherwise both should be `null`.
    if raw_text.strip() == "null" and wrapped_text.strip() == "null":
        print("PASS: lsp_request_raw + hover both null at given position; plumbing fine")
        return 0
    if "contents" in raw_text and "contents" in wrapped_text:
        print("PASS: lsp_request_raw returned `contents` key matching wrapped hover shape")
        print(f"  raw text: {raw_text[:200]}")
        return 0

    print(f"FAIL: raw and wrapped responses diverge.\n  raw: {raw_text[:200]}\n  wrapped: {wrapped_text[:200]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
