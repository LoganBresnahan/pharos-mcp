#!/usr/bin/env python3
"""Parse a dogfood pass report (doc/dogfood-pass-NN.md) into the wide
per-tool matrix tables used in doc/lsp-capability-matrix.md.

Usage:
    bin/pass-to-matrix.py doc/dogfood-pass-27.md
"""

import re
import sys
from pathlib import Path

# Column order for the main per-tool table.
# Each entry is (column_header, list_of_underlying_tools).
# When multiple tools share a column (call-h, type-h), the column is
# OK only if every underlying tool is OK / GAP and the prepare succeeded;
# any FAIL collapses the column.
MAIN_COLS = [
    ("hov",        ["hover"]),
    ("doc-sym",    ["document_symbols"]),
    ("ws-sym",     ["workspace_symbols"]),
    ("refs",       ["find_references"]),
    ("diag",       ["get_diagnostics"]),
    ("def",        ["goto_definition"]),
    ("type-def",   ["goto_type_definition"]),
    ("impl",       ["goto_implementation"]),
    ("sig",        ["signature_help"]),
    ("fmt",        ["format_document"]),
    ("code-act",   ["code_actions"]),
    ("rename",     ["rename_preview"]),
    ("inlay",      ["inlay_hints"]),
    ("sem",        ["semantic_tokens"]),
    ("call-h",     ["call_hierarchy_prepare",
                    "call_hierarchy_incoming_calls",
                    "call_hierarchy_outgoing_calls"]),
    ("type-h",     ["type_hierarchy_prepare",
                    "type_hierarchy_supertypes",
                    "type_hierarchy_subtypes"]),
]

# Symbol-layer table (ADR-026).
SYMBOL_COLS = [
    ("find_sym",   ["find_symbol"]),
    ("overview",   ["get_symbols_overview"]),
    ("contain",    ["containing_symbol"]),
    ("refs-sym",   ["find_referencing_symbols"]),
    ("edit",       ["edit_at_symbol"]),
]

# Per-language section header pattern: `## bash (23/27)`
LANG_HEADER = re.compile(r"^## (\S+) \(\d+/\d+\)\s*$")
# Skip cross-cutting sections like `## (global)` and `## (memory)`.
SKIP_LANGS = {"(global)", "(memory)"}
# Row pattern: `| \`tool\` | OK | note |`
ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*(OK|GAP|FAIL|SKIP)\s*\|")


def parse(report_path: Path) -> dict:
    """Return {lang: {tool: result}} where result is OK / GAP / FAIL / SKIP."""
    data: dict[str, dict[str, str]] = {}
    cur_lang: str | None = None

    for raw in report_path.read_text().splitlines():
        m = LANG_HEADER.match(raw)
        if m:
            lang = m.group(1)
            if lang in SKIP_LANGS:
                cur_lang = None
            else:
                cur_lang = lang
                data[cur_lang] = {}
            continue

        if cur_lang is None:
            continue

        m = ROW.match(raw)
        if not m:
            continue

        tool, result = m.group(1), m.group(2)
        result = result.upper()
        # Handle `OK (after retry ...)` style by stripping after first word.
        data[cur_lang][tool] = result

    return data


def collapse(cell_results: list[str]) -> str:
    """Collapse multi-tool column results into one symbol.

    OK    iff every tool is OK
    G     iff every tool is OK or GAP, and at least one is GAP
    F     iff any tool is FAIL
    -     iff missing/SKIP
    """
    if not cell_results:
        return "—"
    if any(r == "FAIL" for r in cell_results):
        return "F"
    if any(r == "SKIP" for r in cell_results) and not all(r == "SKIP" for r in cell_results):
        return "F"  # partial skip = treat as failure for transparency
    if all(r == "SKIP" for r in cell_results):
        return "—"
    if any(r == "GAP" for r in cell_results):
        return "G"
    return "✓"


def render(data: dict, cols: list, title: str, lang_width: int = 12) -> str:
    """Render a markdown table with one column per `cols` entry."""
    headers = ["Lang"] + [c[0] for c in cols]
    sep_row = ["-" * len(h) for h in headers]

    lines = [
        f"## {title}",
        "",
        "| " + " | ".join(headers) + " |",
        "|" + "|".join(["-" * len(h) for h in headers]) + "|",
    ]

    for lang in sorted(data.keys()):
        row = [lang.ljust(lang_width)]
        for _, tool_list in cols:
            cell_results = [data[lang].get(t, "SKIP") for t in tool_list]
            row.append(collapse(cell_results))
        lines.append("| " + " | ".join(row) + " |")

    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <pass-report.md>", file=sys.stderr)
        sys.exit(2)

    report = Path(sys.argv[1])
    if not report.exists():
        print(f"error: report not found: {report}", file=sys.stderr)
        sys.exit(2)

    data = parse(report)
    if not data:
        print("error: no per-language sections found in report", file=sys.stderr)
        sys.exit(2)

    print(render(data, MAIN_COLS,
                 "Per-language LSP tool support"))
    print()
    print(render(data, SYMBOL_COLS,
                 "Symbol-layer support (ADR-026)"))


if __name__ == "__main__":
    main()
