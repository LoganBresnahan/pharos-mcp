#!/usr/bin/env python3
"""HTTP twin of bin/test-debug.py — same 15 cells, HTTP transport.

Imports drive helpers from _pharos_drive_http instead of _pharos_drive.
Otherwise identical. Both pass = transport-parity for the debug
category.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pharos_drive_http import (  # noqa: E402
    drive,
    find_response,
    initialize_request,
    tool_call_request,
    tool_is_error,
    tool_text,
)

# Reuse the cell logic from the stdio harness — copy/paste rather
# than import because the file has a dash in its name and the cell
# bodies are short enough not to be worth importlib gymnastics.


def main() -> int:
    requests = [
        initialize_request(0),
        tool_call_request(1, "echo", {"message": "hello-from-test-debug-http"}),
        tool_call_request(2, "runtime_processes", {"limit": 30}),
        tool_call_request(3, "runtime_supervision_tree", {}),
        tool_call_request(4, "runtime_ets_tables", {}),
        tool_call_request(5, "runtime_memory", {}),
        tool_call_request(6, "runtime_applications", {}),
        tool_call_request(7, "runtime_scheduler_util", {}),
        tool_call_request(8, "runtime_log_tail", {"n": 50}),
        tool_call_request(9, "runtime_log_clear", {}),
        tool_call_request(
            10, "runtime_log_level", {"target": "pharos/mcp/server", "level": "debug"}
        ),
        tool_call_request(11, "runtime_trace_lsp", {"duration_ms": 500}),
        tool_call_request(
            12,
            "runtime_kill_lsp",
            {"language": "rust", "workspace": "/tmp/nonexistent-test-debug"},
        ),
        tool_call_request(
            13,
            "runtime_trace_calls",
            {"module": "lists", "function": "reverse", "duration_ms": 500, "max_events": 5},
        ),
        tool_call_request(14, "runtime_language_config", {"language": "rust"}),
        tool_call_request(15, "runtime_pid_info", {"pid": "<0.0.0>"}),
    ]

    responses, stderr = drive({}, requests, timeout=30)

    init = find_response(responses, 0)
    if not init or "result" not in init:
        print(f"FAIL: initialize did not return a result\n  {init}")
        return 1

    cells = []

    def check(name, rid, predicate, fail_msg):
        r = find_response(responses, rid)
        if r is None:
            cells.append((False, name, "no response"))
            return
        if "result" not in r:
            cells.append((False, name, f"error response: {r.get('error')}"))
            return
        try:
            ok = predicate(r)
        except Exception as e:  # noqa: BLE001
            cells.append((False, name, f"predicate raised {type(e).__name__}: {e}"))
            return
        if ok:
            cells.append((True, name, "ok"))
        else:
            text = tool_text(r)
            cells.append((False, name, f"{fail_msg} text: {text[:200]}"))

    check("echo", 1, lambda r: "hello-from-test-debug-http" in tool_text(r), "echo did not round-trip")
    check("runtime_processes", 2, lambda r: ("pharos_lsp_dyn_sup" in tool_text(r) or "registered_name" in tool_text(r)), "missing landmark")
    check("runtime_supervision_tree", 3, lambda r: ("pharos" in tool_text(r).lower() or "supervisor" in tool_text(r).lower()), "missing landmark")
    check("runtime_ets_tables", 4, lambda r: ("pharos_diagnostics_cache" in tool_text(r) and "pharos_lsp_proc_subjects" in tool_text(r)), "missing pharos tables")
    check("runtime_memory", 5, lambda r: ("total" in tool_text(r) and "processes" in tool_text(r)), "missing keys")
    check("runtime_applications", 6, lambda r: ("kernel" in tool_text(r) and "stdlib" in tool_text(r)), "missing kernel/stdlib")
    check("runtime_scheduler_util", 7, lambda r: any(k in tool_text(r).lower() for k in ("scheduler", "util", "weight")), "missing landmark")
    check("runtime_log_tail", 8, lambda r: ("pharos" in tool_text(r).lower() or tool_text(r).strip() in ("[]", "")), "missing landmark")
    check("runtime_log_clear", 9, lambda r: not tool_is_error(r), "marked isError=true")
    check("runtime_log_level", 10, lambda r: not tool_is_error(r), "marked isError=true")
    check("runtime_trace_lsp", 11, lambda r: ("captured" in tool_text(r) or "duration_ms" in tool_text(r) or tool_text(r).strip() == "[]"), "missing landmark")
    check("runtime_kill_lsp", 12, lambda r: any(s in tool_text(r).lower() for s in ("not found", "killed", "no cached")), "missing expected shape")
    check("runtime_trace_calls", 13, lambda r: any(s in tool_text(r).lower() for s in ("disabled", "trace_calls_enabled", "events")), "missing expected shape")
    check("runtime_language_config", 14, lambda r: "[languages.rust]" in tool_text(r) and "rust-analyzer" in tool_text(r), "missing rust block")
    check("runtime_pid_info", 15, lambda r: any(s in tool_text(r) for s in ("0.0.0", "registered_name", "current_function")) or "not found" in tool_text(r).lower() or "no such" in tool_text(r).lower(), "missing expected shape")

    passed = sum(1 for ok, *_ in cells if ok)
    total = len(cells)
    print(f"\n=== {passed}/{total} cells PASS (HTTP transport) ===")
    if passed == total:
        return 0
    print("\nFailures:")
    for ok, name, msg in cells:
        if not ok:
            print(f"  {name}: {msg}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
