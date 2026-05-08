#!/usr/bin/env python3
"""D-side-quest 6: verify workspace_configuration_json override path.

Pins `[languages.typescript] workspace_configuration_json` to a known
sentinel JSON, drives pharos, calls `runtime_language_config` to read
back the merged registry, asserts the override threaded through the
ETS FFI's object-split logic.

The workspace_configuration_json shape requires a top-level OBJECT
(section→settings); each value passes through gleam_json verbatim
via pharos_json_passthrough_ffi:parse_object_to_raw_pairs/1.

Pass criterion: response text contains the sentinel section name +
the override's nested values, and omits at least one bundled-default
section (whole-blob replace).
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pharos_drive import (  # noqa: E402
    drive,
    find_response,
    initialize_request,
    tool_call_request,
    tool_text,
)

OVERRIDE_JSON = (
    '{"sentinelSection":{"sentinelField":"override-applied","enabled":true}}'
)
# The bundled typescript default has both `typescript` AND `javascript`
# section keys; whole-blob replace should drop both.
BUNDLED_DEFAULT_SECTION = "javascript"


def main():
    with tempfile.NamedTemporaryFile(
        "w", suffix=".toml", delete=False, prefix="pharos-test-"
    ) as f:
        f.write(
            "[languages.typescript]\n"
            f"workspace_configuration_json = '''\n{OVERRIDE_JSON}\n'''\n"
        )
        config_path = f.name

    try:
        responses, stderr = drive(
            {"PHAROS_CONFIG_FILE": config_path},
            [
                initialize_request(0),
                tool_call_request(
                    1,
                    "runtime_language_config",
                    {"language": "typescript"},
                ),
            ],
            timeout=15,
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

    config_resp = find_response(responses, 1)
    if not config_resp:
        print(
            f"FAIL: no runtime_language_config response\n"
            f"  stderr tail:\n{stderr[-1500:] if stderr else ''}"
        )
        return 1

    text = tool_text(config_resp)
    if "sentinelSection" not in text:
        print(
            "FAIL: override sentinel section absent — "
            "workspace_configuration_json did not thread through merge\n"
            f"  text: {text[:800]}"
        )
        return 1
    if "sentinelField" not in text:
        print(
            "FAIL: nested sentinel field absent — passthrough lost the inner JSON\n"
            f"  text: {text[:800]}"
        )
        return 1
    if BUNDLED_DEFAULT_SECTION + '"' in text or BUNDLED_DEFAULT_SECTION + ":" in text:
        # Match the section name as a key (followed by `:` in the
        # rendered JSON value). The phrase 'javascript' may legitimately
        # appear in unrelated comments; only flag if it looks like a
        # surviving section key.
        print(
            f"FAIL: bundled-default `{BUNDLED_DEFAULT_SECTION}` section "
            "still present — whole-blob replace should have removed it\n"
            f"  text: {text[:800]}"
        )
        return 1

    print("PASS: workspace_configuration_json whole-blob replace verified")
    print("  sentinel section + field present, bundled-default sections gone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
