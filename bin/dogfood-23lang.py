#!/usr/bin/env python3
"""Dogfood pass: 23 languages × 39 tools against real-world fixtures.

Drives pharos through stdio + NDJSON, exercises every advertised MCP
tool against `tmp/fixtures/<lang>/` repos cloned by
`bin/dogfood-fixtures.sh`. Records each tool's outcome into a markdown
report (default `doc/dogfood-23lang.md`).

Per-language exercises **22 LSP-bound tools** at a curated symbol
position; 16 runtime tools + `echo` + `lsp_request_raw` run once
globally. Total cells per pass = 23 × 22 + 17 = **523**.

Many tools return `-32601 Method not supported` for languages whose
LSP doesn't implement them. Those are recorded as `PASS (-32601)` —
plumbing works, server-side gap. Real failures are `FAIL: <reason>`.

Usage:

    python3 bin/dogfood-23lang.py                  # all langs
    python3 bin/dogfood-23lang.py rust go gleam    # specific langs
    PHAROS_TEST_BIN=burrito_out/pharos_linux_x64 python3 bin/dogfood-23lang.py
    python3 bin/dogfood-23lang.py --label "binary, post-rebuild"

Pass label appears in the report header so multiple runs can be
diff-walked. Default label = `pharos-dev`.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES_ROOT = os.path.join(PROJECT_ROOT, "tmp", "fixtures")
DEFAULT_REPORT = os.path.join(PROJECT_ROOT, "doc", "dogfood-23lang.md")


@dataclass
class Target:
    """Curated dogfood target for one language fixture.

    `file_rel` is relative to `tmp/fixtures/<id>/`. `line`/`character`
    point at a non-trivial declared symbol — `hover` and friends fire
    at this position. `query` is fed to `workspace_symbols`.
    `ws_sym_lang_override` only matters when the fixture's primary
    file extension routes to a different language id than the fixture
    itself (none currently).
    """
    id: str
    file_rel: str
    line: int            # 0-based (LSP convention)
    character: int       # 0-based UTF-16 code-unit offset
    query: str
    rename_to: str = "Renamed"  # for rename_preview
    ws_sym_lang_override: str | None = None

    @property
    def workspace(self) -> str:
        return os.path.join(FIXTURES_ROOT, self.id)

    @property
    def file_uri(self) -> str:
        return "file://" + os.path.join(self.workspace, self.file_rel)


# Curated targets per fixture. Symbol positions chosen by inspecting
# the file at clone time — see `bin/dogfood-fixtures.sh` for the
# pinned SHAs that lock these line numbers in place.
TARGETS = [
    Target("rust",       "src/cargo/lib.rs",                                       163,  7,  "exit_with_error"),
    Target("go",         "cmd/prometheus/main.go",                                 148,  5,  "init"),
    Target("typescript", "src/index.js",                                            42,  9,  "withPlugins"),
    Target("elixir",     "lib/phoenix.ex",                                           0, 11,  "Phoenix"),
    Target("ruby",       "lib/sinatra/base.rb",                                   2152, 11,  "Base"),
    Target("zig",        "src/main.zig",                                             3,  6,  "std"),
    Target("cpp",        "src/google/protobuf/message.h",                          132,  6,  "Message"),
    Target("scala",      "library/src/scala/Tuple.scala",                          113,  7,  "Tuple"),
    Target("clojure",    "src/clj/clojure/core.clj",                                12,  5,  "unquote"),
    Target("haskell",    "Cabal/src/Distribution/Simple.hs",                       143,  0,  "defaultMain"),
    Target("perl",       "lib/Mojolicious.pm",                                     151,  4,  "new"),
    Target("html",       "scripts/filecheck/fixtures/html/index.html",               0,  0,  "html"),
    Target("css",        "dist/css/bootstrap.css",                                   6,  0,  "root"),
    Target("json",       "package.json",                                             0,  0,  "name"),
    Target("yaml",       "changelogs/config.yaml",                                   0,  0,  "title"),
    Target("markdown",   "README.md",                                                0,  0,  "MDN"),
    Target("terraform",  "main.tf",                                                  0,  0,  "vpc"),
    Target("erlang",     "apps/rebar/src/rebar3.erl",                               58,  0,  "main"),
    Target("java",       "clients/src/main/java/org/apache/kafka/clients/KafkaClient.java",
                                                                                    28, 17,  "KafkaClient"),
    Target("gleam",      "src/gleam/list.gleam",                                    52,  7,  "length"),
    Target("lua",        "kong/init.lua",                                          635, 13,  "init"),
    Target("bash",       "oh-my-zsh.sh",                                             0,  0,  "main"),
    Target("python",     "src/flask/app.py",                                        72,  4,  "_make_timedelta"),
]

# Per-language tools — fire each at the target position, record the
# result. Order is chronological for the LSP cache: lighter probes
# first (hover + doc_symbols warm the document), heavier later.
PER_LANG_TOOLS = [
    "hover",
    "document_symbols",
    "workspace_symbols",
    "get_diagnostics",
    "goto_definition",
    "goto_type_definition",
    "goto_implementation",
    "find_references",
    "signature_help",
    "format_document",
    "code_actions",
    "rename_preview",
    "inlay_hints",
    "semantic_tokens",
    "call_hierarchy_prepare",
    "call_hierarchy_incoming_calls",
    "call_hierarchy_outgoing_calls",
    "type_hierarchy_prepare",
    "type_hierarchy_supertypes",
    "type_hierarchy_subtypes",
    "lsp_request_raw",
    "apply_workspace_edit",
]

GLOBAL_TOOLS = [
    "echo",
    "runtime_processes",
    "runtime_supervision_tree",
    "runtime_ets_tables",
    "runtime_memory",
    "runtime_applications",
    "runtime_scheduler_util",
    "runtime_log_tail",
    "runtime_log_level",
    "runtime_log_clear",
    "runtime_trace_lsp",
    "runtime_kill_lsp",
    "runtime_trace_calls",
    "runtime_language_config",
    "runtime_set_tool_timeout",
    "runtime_effective_tool_config",
    "runtime_pid_info",
]


PER_LANG_TIMEOUT_MS = 25_000  # 25s ceiling per LSP-bound call


def build_args(tool: str, t: Target | None, prepared_item=None) -> dict:
    """Compose the `arguments` body for one tool call.

    `t` is None for global tools. `prepared_item` carries the call/type
    hierarchy item from a prior `*_prepare` call when the tool is one
    of the chained `*_incoming_calls` / `*_outgoing_calls` /
    `*_supertypes` / `*_subtypes`.

    Every per-lang LSP-bound tool gets a `timeout_ms` arg capped at
    `PER_LANG_TIMEOUT_MS` so pharos's wait does not extend past the
    harness's outer deadline (we want pharos to fail fast and let us
    record the timeout, then continue to the next tool — slow LSPs
    like PLS / metals can otherwise hold one tool open for 3+ minutes
    on cold start).
    """
    if tool == "echo":
        return {"message": "dogfood-23lang"}
    if tool == "runtime_pid_info":
        return {"pid": "<0.0.0>"}  # always-present init pid
    if tool == "runtime_log_level":
        return {"target": "pharos", "level": "info"}
    if tool == "runtime_kill_lsp":
        # Skip — it would tear down the LSP we just spent cold-start
        # warming. Smoke-test plumbing by passing a non-matching
        # workspace; tool returns ok=false but does not error.
        return {"language": "rust", "workspace": "/nonexistent"}
    if tool == "runtime_trace_lsp":
        return {"window_ms": 200}
    if tool == "runtime_trace_calls":
        return {"mfa": "lists:reverse/1", "window_ms": 200, "max_events": 5}
    if tool == "runtime_set_tool_timeout":
        return {"tool": "hover", "language": "rust", "timeout_ms": 30000}
    if tool == "runtime_effective_tool_config":
        return {"tool": "hover", "language": "rust"}
    if tool == "runtime_language_config":
        return {"language": "rust"}
    if tool.startswith("runtime_log_"):
        return {} if tool == "runtime_log_clear" else {"lines": 10}
    if tool.startswith("runtime_"):
        return {}

    assert t is not None, f"per-lang tool {tool} requires a Target"

    pos = {"line": t.line, "character": t.character}
    uri_pos = {"uri": t.file_uri, **pos}
    tmo = {"timeout_ms": PER_LANG_TIMEOUT_MS}

    if tool == "hover":
        return {**uri_pos, **tmo}
    if tool == "document_symbols":
        return {"uri": t.file_uri, **tmo}
    if tool == "workspace_symbols":
        return {
            "query": t.query,
            "workspace_uri_hint": t.file_uri,
            "language": t.ws_sym_lang_override or t.id,
            **tmo,
        }
    if tool == "get_diagnostics":
        return {"uri": t.file_uri, **tmo}
    if tool == "goto_definition":
        return {**uri_pos, **tmo}
    if tool == "goto_type_definition":
        return {**uri_pos, **tmo}
    if tool == "goto_implementation":
        return {**uri_pos, **tmo}
    if tool == "find_references":
        return {**uri_pos, "include_declaration": True, **tmo}
    if tool == "signature_help":
        return {**uri_pos, **tmo}
    if tool == "format_document":
        return {"uri": t.file_uri, **tmo}
    if tool == "code_actions":
        return {
            "uri": t.file_uri,
            "start_line": t.line,
            "start_character": t.character,
            "end_line": t.line,
            "end_character": t.character + 5,
            **tmo,
        }
    if tool == "rename_preview":
        return {**uri_pos, "new_name": t.rename_to, **tmo}
    if tool == "inlay_hints":
        return {
            "uri": t.file_uri,
            "start_line": 0,
            "start_character": 0,
            "end_line": t.line + 20,
            "end_character": 0,
            **tmo,
        }
    if tool == "semantic_tokens":
        return {"uri": t.file_uri, **tmo}
    if tool == "call_hierarchy_prepare":
        return {**uri_pos, **tmo}
    if tool == "call_hierarchy_incoming_calls":
        return {"item": prepared_item, **tmo} if prepared_item else None
    if tool == "call_hierarchy_outgoing_calls":
        return {"item": prepared_item, **tmo} if prepared_item else None
    if tool == "type_hierarchy_prepare":
        return {**uri_pos, **tmo}
    if tool == "type_hierarchy_supertypes":
        return {"item": prepared_item, **tmo} if prepared_item else None
    if tool == "type_hierarchy_subtypes":
        return {"item": prepared_item, **tmo} if prepared_item else None
    if tool == "lsp_request_raw":
        return {
            "uri": t.file_uri,
            "method": "textDocument/hover",
            "params": {
                "textDocument": {"uri": t.file_uri},
                "position": pos,
            },
            **tmo,
        }
    if tool == "apply_workspace_edit":
        scratch = "/tmp/awe-dogfood-scratch.txt"
        with open(scratch, "w") as f:
            f.write("hello world\n")
        return {
            "edit": {
                "changes": {
                    "file://" + scratch: [
                        {
                            "range": {
                                "start": {"line": 0, "character": 6},
                                "end": {"line": 0, "character": 11},
                            },
                            "newText": "WORLD",
                        }
                    ]
                }
            },
            "dry_run": True,
        }
    raise AssertionError(f"unknown tool {tool}")


def request(rid: int, tool: str, args) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "method": "tools/call",
        "params": {"name": tool, "arguments": args},
    }


def call_one(proc, rid: int, tool: str, args, timeout_s: float) -> tuple[bool, str, dict | None]:
    """Send one tools/call, drain stdout until matching response or
    timeout. Returns (pass, summary, raw_result_dict).

    PASS criteria, in priority order:
      1. response with `"result"` and `isError=false` (or absent) — pass.
      2. response with `"result"` and `isError=true` whose body mentions
         `-32601`/`Method not found`/`unsupported file type` — pass with
         that note (server-side gap, not pharos plumbing).
      3. response with `"error"` field — fail with the error message.
      4. no response within timeout — fail "no response".
    """
    proc.stdin.write(json.dumps(request(rid, tool, args)) + "\n")
    proc.stdin.flush()

    deadline = time.monotonic() + timeout_s
    buf = ""
    while time.monotonic() < deadline:
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            return False, "stdout EOF (proc died)", None
        try:
            buf += chunk.decode("utf-8", errors="replace")
        except Exception:
            return False, "decode error on stdout", None
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") != rid:
                continue
            return classify(tool, obj)
    return False, f"no response within {timeout_s:.0f}s", None


def classify(tool: str, obj: dict) -> tuple[bool, str, dict | None]:
    if "error" in obj:
        e = obj["error"]
        return False, f"protocol error {e.get('code')}: {e.get('message','')[:120]}", None
    result = obj.get("result")
    if result is None:
        return False, "result missing", None
    is_err = bool(result.get("isError"))
    text = ""
    for c in result.get("content", []):
        if c.get("type") == "text":
            text += c.get("text", "")
    if is_err:
        low = text.lower()
        if "-32601" in low or "method not found" in low or "unsupported file type" in low:
            return True, f"server gap (-32601 / unsupported)", result
        return False, f"isError=true: {text[:160]}", None
    n = len(text)
    summary = f"ok ({n}b)"
    return True, summary, result


def initialize(proc) -> bool:
    proc.stdin.write(json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "dogfood-23lang", "version": "1"},
        },
    }) + "\n")
    proc.stdin.write(json.dumps({
        "jsonrpc": "2.0", "method": "notifications/initialized", "params": {},
    }) + "\n")
    proc.stdin.flush()

    deadline = time.monotonic() + 30
    buf = ""
    while time.monotonic() < deadline:
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            return False
        buf += chunk.decode("utf-8", errors="replace")
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == 1 and "result" in obj:
                return True
    return False


def run_pass(filter_langs: list[str] | None, skip: set[str] = frozenset()) -> list[tuple[str, str, bool, str]]:
    """Returns [(lang, tool, pass, summary), ...]."""
    bin_path = os.environ.get(
        "PHAROS_TEST_BIN", os.path.join(PROJECT_ROOT, "bin", "pharos-dev")
    )
    if not os.path.exists(bin_path):
        sys.exit(f"FATAL: pharos binary not found at {bin_path}")

    env = os.environ.copy()
    proc = subprocess.Popen(
        [bin_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        cwd=PROJECT_ROOT,
        text=True,
    )

    if not initialize(proc):
        proc.kill()
        sys.exit("FATAL: initialize handshake failed")

    rows: list[tuple[str, str, bool, str]] = []
    rid = 100

    targets = TARGETS
    if filter_langs:
        targets = [t for t in TARGETS if t.id in filter_langs]
        if not targets:
            sys.exit(f"no fixture matches: {filter_langs}")

    for t in targets:
        if t.id in skip:
            print(f"  SKIP {t.id}: opted out via --skip", flush=True)
            for tool in PER_LANG_TOOLS:
                rows.append((t.id, tool, False, "skipped (--skip)"))
            continue
        if not os.path.exists(t.workspace):
            print(f"  SKIP {t.id}: fixture not cloned ({t.workspace})", flush=True)
            for tool in PER_LANG_TOOLS:
                rows.append((t.id, tool, False, "fixture not cloned"))
            continue

        target_path = os.path.join(t.workspace, t.file_rel)
        if not os.path.exists(target_path):
            print(f"  SKIP {t.id}: target file missing ({target_path})", flush=True)
            for tool in PER_LANG_TOOLS:
                rows.append((t.id, tool, False, "target file missing"))
            continue

        print(f"\n=== {t.id} ({t.file_rel}) ===", flush=True)
        prepared_call_item = None
        prepared_type_item = None

        for tool in PER_LANG_TOOLS:
            rid += 1
            if tool in ("call_hierarchy_incoming_calls", "call_hierarchy_outgoing_calls"):
                args = build_args(tool, t, prepared_call_item)
                if args is None:
                    rows.append((t.id, tool, False, "prepare returned no item"))
                    print(f"  SKIP {tool}: no prepared call item", flush=True)
                    continue
            elif tool in ("type_hierarchy_supertypes", "type_hierarchy_subtypes"):
                args = build_args(tool, t, prepared_type_item)
                if args is None:
                    rows.append((t.id, tool, False, "prepare returned no item"))
                    print(f"  SKIP {tool}: no prepared type item", flush=True)
                    continue
            else:
                args = build_args(tool, t)

            ok, summary, result = call_one(proc, rid, tool, args, timeout_s=60)
            rows.append((t.id, tool, ok, summary))
            print(f"  {'PASS' if ok else 'FAIL'} {tool}: {summary}", flush=True)

            # Capture prepare items for chained follow-ups.
            if tool == "call_hierarchy_prepare" and ok and result:
                prepared_call_item = first_item_from(result)
            elif tool == "type_hierarchy_prepare" and ok and result:
                prepared_type_item = first_item_from(result)

    print(f"\n=== global tools ===", flush=True)
    for tool in GLOBAL_TOOLS:
        rid += 1
        args = build_args(tool, None)
        ok, summary, _ = call_one(proc, rid, tool, args, timeout_s=30)
        rows.append(("(global)", tool, ok, summary))
        print(f"  {'PASS' if ok else 'FAIL'} {tool}: {summary}", flush=True)

    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()

    return rows


def first_item_from(result: dict):
    """Pull the first JSON object out of a tool result's text payload.

    `*_prepare` tools return the LSP item array as JSON inside the text
    content block. We thread one of those items back into the chained
    `*_incoming_calls` / `*_outgoing_calls` tools.
    """
    for c in result.get("content", []):
        if c.get("type") != "text":
            continue
        try:
            payload = json.loads(c.get("text", ""))
        except json.JSONDecodeError:
            continue
        if isinstance(payload, list) and payload:
            return payload[0]
        if isinstance(payload, dict) and "items" in payload and payload["items"]:
            return payload["items"][0]
    return None


def write_report(rows, out_path: str, label: str):
    by_lang: dict[str, list] = {}
    for lang, tool, ok, summary in rows:
        by_lang.setdefault(lang, []).append((tool, ok, summary))

    pharos_bin = os.environ.get("PHAROS_TEST_BIN", "bin/pharos-dev")
    total = len(rows)
    passed = sum(1 for _, _, ok, _ in rows if ok)

    lines = [
        f"# Dogfood pass — 23 languages × 39 tools",
        "",
        f"**Label:** {label}",
        f"**Binary:** `{pharos_bin}`",
        f"**Result:** **{passed}/{total} cells PASS** ({100 * passed // max(total,1)}%)",
        "",
        "Per-language LSP-bound tools (22): hover, document_symbols, workspace_symbols, "
        "get_diagnostics, goto_definition, goto_type_definition, goto_implementation, "
        "find_references, signature_help, format_document, code_actions, rename_preview, "
        "inlay_hints, semantic_tokens, call_hierarchy_prepare, call_hierarchy_incoming_calls, "
        "call_hierarchy_outgoing_calls, type_hierarchy_prepare, type_hierarchy_supertypes, "
        "type_hierarchy_subtypes, lsp_request_raw, apply_workspace_edit.",
        "",
        "Global one-shot tools (17): echo, runtime_processes, runtime_supervision_tree, "
        "runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util, "
        "runtime_log_tail, runtime_log_level, runtime_log_clear, runtime_trace_lsp, "
        "runtime_kill_lsp, runtime_trace_calls, runtime_language_config, "
        "runtime_set_tool_timeout, runtime_effective_tool_config, runtime_pid_info.",
        "",
        "Result keys: `OK` = response without isError. "
        "`server gap` = isError carrying -32601 / Method not found / unsupported file type — "
        "plumbing fine, LSP doesn't implement it. `FAIL` = anything else.",
        "",
    ]

    for lang in sorted(by_lang.keys()):
        entries = by_lang[lang]
        lpass = sum(1 for _, ok, _ in entries if ok)
        lines.append(f"## {lang} ({lpass}/{len(entries)})")
        lines.append("")
        lines.append("| Tool | Result | Note |")
        lines.append("|------|--------|------|")
        for tool, ok, summary in entries:
            mark = "OK" if ok else "FAIL"
            if "server gap" in summary:
                mark = "GAP"
            lines.append(f"| `{tool}` | {mark} | {summary} |")
        lines.append("")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("languages", nargs="*", help="filter to listed langs (default: all)")
    ap.add_argument("--skip", default="",
                    help="comma-separated langs to skip. Useful for slow LSPs "
                         "(e.g. `--skip perl,ruby`). Recorded as 'skipped' in report.")
    ap.add_argument("--label", default="pharos-dev",
                    help="pass label written into the report header")
    ap.add_argument("--out", default=DEFAULT_REPORT,
                    help=f"output markdown path (default: {DEFAULT_REPORT})")
    args = ap.parse_args()

    skip = set(s.strip() for s in args.skip.split(",") if s.strip())
    rows = run_pass(args.languages or None, skip)
    write_report(rows, args.out, args.label)

    total = len(rows)
    passed = sum(1 for _, _, ok, _ in rows if ok)
    print(f"\n=== {passed}/{total} cells PASS ===")
    print(f"report: {args.out}")
    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
