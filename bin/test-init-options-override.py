#!/usr/bin/env python3
"""D-side-quest 5: verify initialization_options_json override path.

Pins `[languages.rust] initialization_options_json` to a known
sentinel JSON, drives pharos, calls the new `runtime_language_config`
MCP tool to introspect the merged registry, asserts the rendered TOML
contains the override values.

End-to-end: TOML decoder → ServerOverride → registry.merge_server →
parse_init_options_or → json_passthrough FFI → registry.cached →
registry_toml.render_language → MCP tool response.

Pass criterion: response text contains the sentinel field name AND
omits the bundled-default field name (whole-blob replace, not merge).
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

OVERRIDE_JSON = '{"checkOnSave":false,"sentinelField":"override-applied"}'
BUNDLED_DEFAULT_FIELD = "procMacro"


def main():
    with tempfile.NamedTemporaryFile(
        "w", suffix=".toml", delete=False, prefix="pharos-test-"
    ) as f:
        f.write(
            "[languages.rust]\n"
            f"initialization_options_json = '''\n{OVERRIDE_JSON}\n'''\n"
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
                    {"language": "rust"},
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
    if "sentinelField" not in text:
        print(
            "FAIL: override sentinel field absent — "
            "init_options_json did not thread through merge\n"
            f"  text: {text[:600]}"
        )
        return 1
    if BUNDLED_DEFAULT_FIELD in text:
        print(
            "FAIL: bundled default field present — whole-blob replace "
            "should have removed it\n"
            f"  text: {text[:600]}"
        )
        return 1
    if '"checkOnSave":false' not in text:
        print(
            "FAIL: explicit false value not preserved through passthrough\n"
            f"  text: {text[:600]}"
        )
        return 1

    print("PASS: initialization_options_json whole-blob replace verified")
    print("  sentinel found, bundled-default field gone, false value preserved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
