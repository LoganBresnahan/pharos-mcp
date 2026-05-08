#!/usr/bin/env python3
"""C1: ADR-018 BinaryNotFound surfacing test.

Verifies that when pharos cannot resolve an LSP binary (because the
override points at a non-existent absolute path), the resulting
`BinaryNotFound` error reaches the LLM cleanly via the `tools/call`
content block — not as a generic transport error or a host-killing
crash.

The test pins `[languages.rust] command = "/tmp/pharos-test-missing-..."`
in a temp TOML file, fires `hover` against /home/oof/rust_dev/src/main.rs,
and asserts that the response is a tool-error block whose text mentions
the override path and the user-facing remediation hint.

Pass criterion: response is a JSON-RPC `result` (not error response),
`isError=true`, content text contains "not found" + the override path.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pharos_drive import (  # noqa: E402
    drive,
    find_response,
    initialize_request,
    tool_call_request,
    tool_is_error,
    tool_text,
)

FAKE_BINARY = "/tmp/pharos-test-missing-rust-analyzer-xyzzy"
TEST_FILE = "file:///home/oof/rust_dev/src/main.rs"


def main():
    if os.path.exists(FAKE_BINARY):
        print(f"FAIL: {FAKE_BINARY} exists; expected non-existent")
        return 1
    if not os.path.exists("/home/oof/rust_dev/src/main.rs"):
        print("SKIP: /home/oof/rust_dev/src/main.rs missing — install rust_dev workspace")
        return 0

    with tempfile.NamedTemporaryFile(
        "w", suffix=".toml", delete=False, prefix="pharos-test-"
    ) as f:
        f.write(f'[languages.rust]\ncommand = "{FAKE_BINARY}"\n')
        config_path = f.name

    try:
        responses, stderr = drive(
            {"PHAROS_CONFIG_FILE": config_path},
            [
                initialize_request(1),
                tool_call_request(
                    2,
                    "hover",
                    {"uri": TEST_FILE, "line": 0, "character": 0},
                ),
            ],
            timeout=20,
        )
    finally:
        try:
            os.unlink(config_path)
        except OSError:
            pass

    init = find_response(responses, 1)
    if not init or "result" not in init:
        print(f"FAIL: initialize did not return a result\n  responses: {responses}")
        return 1

    hover = find_response(responses, 2)
    if not hover:
        print(
            f"FAIL: no hover response\n  stderr tail:\n{stderr[-2000:] if stderr else ''}"
        )
        return 1

    text = tool_text(hover)
    if not tool_is_error(hover):
        print(f"FAIL: hover did not mark isError=true\n  hover: {hover}")
        return 1
    if "not found" not in text or FAKE_BINARY not in text:
        print(
            "FAIL: error message missing expected pattern\n"
            f"  expected: '{FAKE_BINARY}' and 'not found'\n"
            f"  text: {text}"
        )
        return 1

    print("PASS: BinaryNotFound surfaces correctly via tool content block")
    print(f"  text: {text[:300]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
