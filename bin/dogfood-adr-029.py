#!/usr/bin/env python3
"""ADR-029 dogfood harness — validates pharos's custom-URI machinery
against a real jdtls + Java fixture.

See doc/dogfood-adr-029.md for the plan. This script implements the
nine v1.0-blocking cells (plus the runtime_server_capabilities
content check) from the gating matrix. The ambiguity cell and the
negative-config cell are out of scope here; they live behind
flags or sibling fixtures.

Usage:
    python3 bin/dogfood-adr-029.py             # full run
    python3 bin/dogfood-adr-029.py --skip-on-no-jdtls  # quiet exit if jdtls missing

Exit codes:
    0   all cells passed
    1   one or more cells failed
    2   setup failure (jdtls / java missing without --skip-on-no-jdtls)

The harness drives `bin/pharos-dev` over stdio (HTTP transport is
covered by a sibling script if/when added). jdtls cold-start is
heavy — the script uses `drive_serial` with generous per-request
timeouts.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pharos_drive import (  # noqa: E402
    drive_serial,
    find_response,
    initialize_request,
    tool_call_request,
    tool_is_error,
    tool_text,
)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE_DIR = os.path.join(PROJECT_ROOT, "bench", "fixtures", "java-jdt-uri")
PROBE_PATH = os.path.join(FIXTURE_DIR, "src/main/java/com/example/Probe.java")
PROBE_URI = "file://" + PROBE_PATH

# Heavy LSP — jdtls cold start can be 30-360s on first call. Bump
# per-request to 360s so workspace/symbol indexing has air.
PER_REQ_TIMEOUT_S = 360


# -- cells ---------------------------------------------------------------


def cell(name):
    """Decorator: register a cell and capture exceptions as failures."""

    def inner(fn):
        fn._cell_name = name
        return fn

    return inner


@cell("1. initialize → instructions string contains jdt://")
def cell_initialize_advertises_jdt(responses):
    init = find_response(responses, 1)
    if not init or "result" not in init:
        return False, "no initialize result"
    instructions = init["result"].get("instructions", "")
    if "jdt://" not in instructions:
        return False, "instructions missing jdt:// (got: " + instructions[:200] + ")"
    return True, "OK — instructions advertises jdt://"


@cell("2. tools/list → fetch_uri_contents + runtime_server_capabilities present")
def cell_tools_list_has_new_tools(responses):
    rsp = find_response(responses, 2)
    if not rsp or "result" not in rsp:
        return False, "no tools/list result"
    names = {t["name"] for t in rsp["result"].get("tools", [])}
    missing = []
    for required in ("fetch_uri_contents", "runtime_server_capabilities"):
        if required not in names:
            missing.append(required)
    if missing:
        return False, "missing tools: " + ", ".join(missing)
    return True, "OK — both tools registered"


@cell("3. hover on Probe.java → spawns jdtls, no error")
def cell_hover_file_uri(responses):
    rsp = find_response(responses, 3)
    if tool_is_error(rsp):
        return False, "hover errored: " + tool_text(rsp)[:200]
    if not rsp:
        return False, "no hover response"
    return True, "OK — hover succeeded"


@cell("4. runtime_server_capabilities → java/jdtls with expected providers")
def cell_capabilities_after_hover(responses):
    rsp = find_response(responses, 4)
    if tool_is_error(rsp):
        return False, "capabilities errored: " + tool_text(rsp)[:200]
    body = tool_text(rsp)
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return False, "capabilities body not JSON: " + body[:200]
    sessions = parsed.get("sessions", [])
    java_session = next(
        (s for s in sessions if s.get("language") == "java"), None
    )
    if not java_session:
        return False, "no java session in capabilities snapshot"
    caps = java_session.get("capabilities", {})
    required_keys = (
        "hoverProvider",
        "definitionProvider",
        "referencesProvider",
        "documentSymbolProvider",
    )
    missing = [k for k in required_keys if k not in caps]
    if missing:
        return False, "java caps missing keys: " + ", ".join(missing)
    return True, "OK — java session has expected providers"


@cell("5. goto_definition on ArrayList → returns jdt:// URI")
def cell_goto_definition_returns_jdt(responses):
    rsp = find_response(responses, 5)
    if tool_is_error(rsp):
        return False, "goto_definition errored: " + tool_text(rsp)[:200]
    body = tool_text(rsp)
    if "jdt://" not in body:
        return False, "no jdt:// URI in response (got: " + body[:300] + ")"
    # Extract the first jdt:// URI for downstream cells.
    start = body.find("jdt://")
    # Walk forward until we hit a quote / whitespace / close paren.
    end = start
    for c in body[start:]:
        if c in '"\\ \t\n\r':
            break
        end += 1
    return True, "OK — jdt:// URI: " + body[start:end][:120]


def extract_jdt_uri(responses):
    """Pull the first jdt:// URI out of the goto_definition response.

    Used to thread the URI into cells 6-9. Returns None if not found.
    """
    rsp = find_response(responses, 5)
    if not rsp:
        return None
    body = tool_text(rsp)
    start = body.find("jdt://")
    if start < 0:
        return None
    end = start
    for c in body[start:]:
        if c in '"\\ \t\n\r':
            break
        end += 1
    return body[start:end]


@cell("6. hover on jdt:// URI → succeeds (assumption 1)")
def cell_hover_jdt_uri(responses):
    rsp = find_response(responses, 6)
    if not rsp:
        return False, "no hover response for jdt://"
    if tool_is_error(rsp):
        return False, "hover on jdt:// errored: " + tool_text(rsp)[:200]
    body = tool_text(rsp)
    if not body or body == "null":
        return False, "hover on jdt:// returned empty/null"
    return True, "OK — jdt:// passthrough works for hover"


@cell("7. find_references on jdt:// URI → succeeds (assumption 1)")
def cell_find_references_jdt_uri(responses):
    rsp = find_response(responses, 7)
    if not rsp:
        return False, "no find_references response for jdt://"
    if tool_is_error(rsp):
        return False, "find_references on jdt:// errored: " + tool_text(rsp)[:200]
    return True, "OK — find_references accepts jdt://"


@cell("8. fetch_uri_contents on jdt:// → returns content (assumption 2 partial)")
def cell_fetch_uri_contents_jdt(responses):
    rsp = find_response(responses, 8)
    if not rsp:
        return False, "no fetch_uri_contents response"
    if tool_is_error(rsp):
        return False, "fetch_uri_contents errored: " + tool_text(rsp)[:300]
    body = tool_text(rsp)
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return False, "fetch body not JSON: " + body[:200]
    content = parsed.get("content", "")
    if not content:
        return False, "fetch returned empty content"
    if len(content) < 50:
        return False, "fetch returned suspiciously short content: " + content
    return True, "OK — got " + str(len(content)) + " bytes of content"


@cell("9. apply_workspace_edit on jdt:// → rejected with teaching phrase (assumption 4)")
def cell_apply_workspace_edit_rejects_jdt(responses):
    rsp = find_response(responses, 9)
    if not rsp:
        return False, "no apply_workspace_edit response"
    if not tool_is_error(rsp):
        return False, "apply_workspace_edit did NOT reject jdt:// — should have"
    msg = tool_text(rsp)
    expected_phrases = ("virtual URI", "project override")
    missing = [p for p in expected_phrases if p not in msg]
    if missing:
        return False, "rejection message missing phrases " + str(missing) + ": " + msg[:200]
    return True, "OK — rejected with virtual-URI teaching message"


CELLS = [
    cell_initialize_advertises_jdt,
    cell_tools_list_has_new_tools,
    cell_hover_file_uri,
    cell_capabilities_after_hover,
    cell_goto_definition_returns_jdt,
    cell_hover_jdt_uri,
    cell_find_references_jdt_uri,
    cell_fetch_uri_contents_jdt,
    cell_apply_workspace_edit_rejects_jdt,
]


# -- request builders ---------------------------------------------------


def build_requests(jdt_uri_for_downstream=None):
    """Build the request batch. Cells 6-9 need the jdt:// URI from cell
    5; on the first pass we send a placeholder and rebuild after cell
    5 returns. drive_serial returns responses in order, so a two-pass
    approach is fine — first run gathers cells 1-5, second run reuses
    the same pharos-dev process for 6-9. To keep state across calls
    we instead run all cells in one drive_serial call, but cells 6-9
    use a URI string we extract from cell 5's response AFTER the
    fact. drive_serial supports this: the requests list is built
    once, but for cells 6-9 we use a sentinel that we replace before
    serializing each request. Since drive_serial doesn't support
    that pattern directly, we split into two batches.
    """
    # Cells 1-5 in batch A.
    batch_a = [
        initialize_request(rid=1),
        tool_call_request(rid=2, name="tools/list", arguments={}),
        # tools/list is actually method, not tool call. Use raw form:
    ]
    # Actually: tools/list is a method, not a tool. Build manually.
    batch_a = [
        initialize_request(rid=1),
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        },
        tool_call_request(
            rid=3,
            name="hover",
            arguments={
                "uri": PROBE_URI,
                "line": 10,  # `  public static void main(String[] args) {`
                "character": 25,  # cursor inside `main`
            },
        ),
        tool_call_request(
            rid=4, name="runtime_server_capabilities", arguments={}
        ),
        tool_call_request(
            rid=5,
            name="goto_definition",
            arguments={
                "uri": PROBE_URI,
                # Line 11 is `    List<String> items = new ArrayList<>();`
                # ArrayList sits at chars 29-37; pick 32 (middle).
                # JDK class usage in body → goto-def hits the class
                # file in `java.base` → `jdt://contents/...`.
                "line": 11,
                "character": 32,
            },
        ),
    ]
    if jdt_uri_for_downstream is None:
        return batch_a
    # Batch B — cells 6-9 use the extracted jdt:// URI.
    return [
        initialize_request(rid=1),
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        },
        # Re-spawn jdtls cheaply by hovering on Probe.java again. drive_serial
        # starts a fresh pharos-dev process, so we need the java session to
        # come back up before the jdt:// cells fire.
        tool_call_request(
            rid=99,
            name="hover",
            arguments={
                "uri": PROBE_URI,
                "line": 10,
                "character": 25,
            },
        ),
        tool_call_request(
            rid=6,
            name="hover",
            arguments={
                "uri": jdt_uri_for_downstream,
                "line": 0,
                "character": 0,
            },
        ),
        tool_call_request(
            rid=7,
            name="find_references",
            arguments={
                "uri": jdt_uri_for_downstream,
                "line": 0,
                "character": 0,
                "include_declaration": True,
            },
        ),
        tool_call_request(
            rid=8,
            name="fetch_uri_contents",
            arguments={"uri": jdt_uri_for_downstream},
        ),
        tool_call_request(
            rid=9,
            name="apply_workspace_edit",
            arguments={
                "edit": {
                    "changes": {
                        jdt_uri_for_downstream: [
                            {
                                "range": {
                                    "start": {"line": 0, "character": 0},
                                    "end": {"line": 0, "character": 1},
                                },
                                "newText": "X",
                            }
                        ]
                    }
                },
                "dry_run": True,
            },
        ),
    ]


# -- main ---------------------------------------------------------------


def check_prereqs(skip_on_no_jdtls):
    if not shutil.which("java"):
        msg = "java not on PATH"
        if skip_on_no_jdtls:
            print("SKIPPED:", msg, file=sys.stderr)
            return False
        print("FAIL setup:", msg, file=sys.stderr)
        sys.exit(2)
    if not shutil.which("jdtls"):
        msg = "jdtls not on PATH — install per bench/fixtures/java-jdt-uri/README.md"
        if skip_on_no_jdtls:
            print("SKIPPED:", msg, file=sys.stderr)
            return False
        print("FAIL setup:", msg, file=sys.stderr)
        sys.exit(2)
    if not os.path.isfile(PROBE_PATH):
        print("FAIL setup: Probe.java missing at", PROBE_PATH, file=sys.stderr)
        sys.exit(2)
    return True


def run_cells(cells, responses):
    failures = 0
    for fn in cells:
        passed, detail = fn(responses)
        marker = "PASS" if passed else "FAIL"
        print(f"  [{marker}] {fn._cell_name}", file=sys.stderr)
        print(f"         {detail}", file=sys.stderr)
        if not passed:
            failures += 1
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--skip-on-no-jdtls",
        action="store_true",
        help="Exit 0 with SKIPPED message if jdtls/java missing.",
    )
    args = parser.parse_args()

    if not check_prereqs(args.skip_on_no_jdtls):
        return 0

    print("== ADR-029 dogfood — batch A (cells 1-5) ==", file=sys.stderr)
    batch_a = build_requests()
    responses_a, stderr_a = drive_serial(
        env_overrides={}, requests=batch_a, per_request_timeout=PER_REQ_TIMEOUT_S
    )
    failures_a = run_cells(CELLS[:5], responses_a)

    jdt_uri = extract_jdt_uri(responses_a)
    if not jdt_uri:
        print(
            "ABORT: cell 5 did not yield a jdt:// URI; cells 6-9 cannot run.",
            file=sys.stderr,
        )
        return 1 if failures_a == 0 else failures_a

    print(
        "== ADR-029 dogfood — batch B (cells 6-9) using URI",
        jdt_uri[:80],
        "==",
        file=sys.stderr,
    )
    batch_b = build_requests(jdt_uri_for_downstream=jdt_uri)
    responses_b, stderr_b = drive_serial(
        env_overrides={}, requests=batch_b, per_request_timeout=PER_REQ_TIMEOUT_S
    )
    failures_b = run_cells(CELLS[5:], responses_b)

    total = failures_a + failures_b
    if total == 0:
        print("== ALL CELLS PASSED ==", file=sys.stderr)
        return 0
    print(f"== {total} CELL(S) FAILED ==", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
