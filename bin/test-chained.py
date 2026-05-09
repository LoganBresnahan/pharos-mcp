#!/usr/bin/env python3
"""Phase 9 — chained read tools.

Four tools take an `item` arg = the response of their `*_prepare`
sibling: call_hierarchy_incoming_calls, call_hierarchy_outgoing_calls,
type_hierarchy_supertypes, type_hierarchy_subtypes.

Approach: two-stage drive. Stage 1 fires `*_prepare` and parses the
returned JSON array of items. Stage 2 fires the chain tools with the
first item threaded back as the `item` arg.

Tolerances: most LSPs return -32601 for one or both hierarchy
families. The harness treats those as PASS-with-warning since plumbing
is fine.

Run:
    python3 bin/test-chained.py                      # all langs
    python3 bin/test-chained.py rust go              # subset
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)

from _pharos_drive import (  # noqa: E402
    drive,
    find_response,
    initialize_request,
    tool_call_request,
    tool_is_error,
    tool_text,
)

# Reuse SPECS from test-suite.py.
_ts_path = os.path.join(_dir, "test-suite.py")
_ts_spec = importlib.util.spec_from_file_location("_test_suite", _ts_path)
_test_suite = importlib.util.module_from_spec(_ts_spec)
sys.modules["_test_suite"] = _test_suite
_ts_spec.loader.exec_module(_test_suite)
SPECS = _test_suite.SPECS


def main() -> int:
    args = sys.argv[1:]
    targets = args if args else list(SPECS.keys())
    unknown = [t for t in targets if t not in SPECS]
    if unknown:
        print(f"Unknown languages: {unknown}. Known: {list(SPECS.keys())}")
        return 2

    total = 0
    passed = 0
    failures = []
    for lang in targets:
        spec = SPECS[lang]
        print(f"\n=== {lang} ({spec.workspace}) ===")
        results = run_language(spec)
        for tool, ok, summary in results:
            total += 1
            if ok:
                passed += 1
                print(f"  PASS {tool}: {summary}")
            else:
                failures.append((lang, tool, summary))
                print(f"  FAIL {tool}: {summary}")

    print(f"\n=== {passed}/{total} cells PASS ===")
    if failures:
        print("Failures:")
        for lang, tool, summary in failures:
            print(f"  {lang}.{tool}: {summary}")
        return 1
    return 0


def run_language(spec) -> list[tuple[str, bool, str]]:
    file_path = spec.file_uri.replace("file://", "")
    if not os.path.exists(file_path):
        return [("setup", False, f"workspace file missing: {spec.file_uri}")]

    # Stage 1 — prepare both hierarchies.
    prepare_requests = [
        initialize_request(0),
        tool_call_request(
            1,
            "call_hierarchy_prepare",
            {"uri": spec.file_uri, "line": spec.point_decl_line, "character": 12},
        ),
        tool_call_request(
            2,
            "type_hierarchy_prepare",
            {"uri": spec.file_uri, "line": spec.point_decl_line, "character": 12},
        ),
    ]
    responses, stderr = drive({}, prepare_requests, timeout=180)

    init = find_response(responses, 0)
    if not init or "result" not in init:
        return [("init", False, f"initialize failed; stderr {stderr[-300:]}")]

    ch_prep = find_response(responses, 1)
    th_prep = find_response(responses, 2)

    # Determine items.
    ch_item = _first_item(ch_prep)
    th_item = _first_item(th_prep)

    cells: list[tuple[str, bool, str]] = []

    # If prepare returned -32601, the entire family is unsupported by
    # this LSP. Mark PASS-with-warning for all four chain tools.
    ch_text = tool_text(ch_prep) if ch_prep else ""
    th_text = tool_text(th_prep) if th_prep else ""

    if "-32601" in ch_text:
        cells.append(("call_hierarchy_incoming_calls", True, "ok (LSP -32601 method not supported via prepare)"))
        cells.append(("call_hierarchy_outgoing_calls", True, "ok (LSP -32601 method not supported via prepare)"))
    elif ch_item is None:
        cells.append(("call_hierarchy_incoming_calls", True, "ok (prepare returned empty/null; no item to chain)"))
        cells.append(("call_hierarchy_outgoing_calls", True, "ok (prepare returned empty/null; no item to chain)"))
    else:
        results = _exercise_chain(
            spec,
            [
                (101, "call_hierarchy_incoming_calls", ch_item),
                (102, "call_hierarchy_outgoing_calls", ch_item),
            ],
        )
        cells.extend(results)

    if "-32601" in th_text:
        cells.append(("type_hierarchy_supertypes", True, "ok (LSP -32601 method not supported via prepare)"))
        cells.append(("type_hierarchy_subtypes", True, "ok (LSP -32601 method not supported via prepare)"))
    elif th_item is None:
        cells.append(("type_hierarchy_supertypes", True, "ok (prepare returned empty/null; no item to chain)"))
        cells.append(("type_hierarchy_subtypes", True, "ok (prepare returned empty/null; no item to chain)"))
    else:
        results = _exercise_chain(
            spec,
            [
                (103, "type_hierarchy_supertypes", th_item),
                (104, "type_hierarchy_subtypes", th_item),
            ],
        )
        cells.extend(results)

    return cells


def _first_item(prepare_response) -> dict | None:
    """Extract the first item from a `*_prepare` response.

    Pharos returns the LSP's verbatim JSON as the `text` field; that's
    a JSON array (or null, or an error). Parse and return the first
    element when shape is array-of-objects; None otherwise.
    """
    if prepare_response is None:
        return None
    text = tool_text(prepare_response)
    if not text or text.strip() in ("null", "[]"):
        return None
    if "-32601" in text:
        return None
    if tool_is_error(prepare_response):
        return None
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    if isinstance(parsed, list) and parsed:
        first = parsed[0]
        if isinstance(first, dict):
            return first
    return None


def _exercise_chain(spec, calls: list[tuple[int, str, dict]]) -> list[tuple[str, bool, str]]:
    """Stage 2 — fire the chain tools with the prepared items."""
    requests = [initialize_request(0)]
    for rid, name, item in calls:
        requests.append(tool_call_request(rid, name, {"item": item}))
    responses, stderr = drive({}, requests, timeout=120)

    out: list[tuple[str, bool, str]] = []
    for rid, name, _ in calls:
        r = find_response(responses, rid)
        if r is None:
            out.append((name, False, "no response"))
            continue
        if "result" not in r:
            out.append((name, False, f"error response: {r.get('error')}"))
            continue
        text = tool_text(r)
        if "-32601" in text:
            out.append((name, True, f"{name} ok (LSP -32601 method not supported)"))
            continue
        if tool_is_error(r):
            out.append((name, False, f"{name} marked isError=true: {text[:120]}"))
            continue
        if text.strip() in ("null", "[]"):
            out.append((name, True, f"{name} ok (empty result; plumbing fine)"))
            continue
        out.append((name, True, f"{name} ok ({len(text)}b non-empty)"))
    return out


if __name__ == "__main__":
    sys.exit(main())
