#!/usr/bin/env python3
"""C2-extension: verify [[languages.<id>.servers]] per-sub-server override.

Pharos's TOML override layer supports two shapes:

  (a) Flat — [languages.python] command = "..." patches ONLY the primary
      (first-listed) server. Already dogfooded by test-config-override.py.

  (b) Per-server array — [[languages.python.servers]] id = "ruff" command =
      "..." patches the ruff sub-server inside python without touching
      pyright. Used for multi-server languages (python = pyright + ruff,
      future typescript + eslint, etc.). Not yet dogfooded.

This test pins ruff's command to a non-existent absolute path and
expects:

  - python's primary server (pyright) still runs against /home/oof/python_dev
    OR fails with pyright's own BinaryNotFound (depending on whether
    pyright is on PATH);
  - any tool routed to ruff (e.g. format_document) surfaces
    BinaryNotFound for the OVERRIDE path, NOT the default `ruff`.

PASS criterion: format_document attempt returns isError=true with the
override path mentioned. That confirms (1) the per-server override
threaded through merge_server, (2) ADR-019 routing picked ruff for
formatting, (3) ADR-018 BinaryNotFound surfaced the override path.
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

OVERRIDE_BINARY = "/tmp/pharos-test-fake-ruff-xyzzy"
TEST_FILE = "file:///home/oof/python_dev/main.py"


def main():
    if os.path.exists(OVERRIDE_BINARY):
        print(f"FAIL: {OVERRIDE_BINARY} exists; expected non-existent")
        return 1
    if not os.path.exists("/home/oof/python_dev/main.py"):
        print("SKIP: /home/oof/python_dev/main.py missing")
        return 0

    with tempfile.NamedTemporaryFile(
        "w", suffix=".toml", delete=False, prefix="pharos-test-"
    ) as f:
        # [[languages.python.servers]] array-of-tables — id = "ruff"
        # selects the ruff sub-server inside python's default config.
        f.write(
            "[[languages.python.servers]]\n"
            f'id = "ruff"\n'
            f'command = "{OVERRIDE_BINARY}"\n'
        )
        config_path = f.name

    try:
        responses, stderr = drive(
            {"PHAROS_CONFIG_FILE": config_path},
            [
                initialize_request(0),
                # format_document routes to ruff per ADR-019 (pyright
                # returns -32601 for textDocument/formatting).
                tool_call_request(
                    100,
                    "format_document",
                    {"uri": TEST_FILE},
                ),
            ],
            timeout=30,
        )
    finally:
        try:
            os.unlink(config_path)
        except OSError:
            pass

    init = find_response(responses, 0)
    if not init or "result" not in init:
        print(f"FAIL: initialize did not return a result\n  responses: {responses}")
        return 1

    fmt = find_response(responses, 100)
    if not fmt:
        print(
            f"FAIL: no format_document response\n"
            f"  stderr tail:\n{stderr[-1500:] if stderr else ''}"
        )
        return 1

    text = tool_text(fmt)
    if not tool_is_error(fmt):
        print(
            f"FAIL: expected isError=true (override binary missing)\n  text: {text}"
        )
        return 1
    if OVERRIDE_BINARY not in text:
        print(
            "FAIL: override path not surfaced — sub-server merge may have ignored ruff entry\n"
            f"  expected '{OVERRIDE_BINARY}' in error text\n"
            f"  text: {text}"
        )
        return 1

    print(
        "PASS: per-server override threaded through merge_server + "
        "ADR-019 routed format_document to overridden ruff"
    )
    print(f"  text: {text[:300]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
