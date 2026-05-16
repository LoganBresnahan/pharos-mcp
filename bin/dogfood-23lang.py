#!/usr/bin/env python3
"""Dogfood pass: 23 languages × 39 tools against real-world fixtures.

Drives pharos through stdio NDJSON or HTTP POST (`--transport http`),
exercises every advertised MCP tool against `tmp/fixtures/<lang>/`
repos cloned by `bin/dogfood-fixtures.sh`. Records each tool's
outcome into a markdown report (default `doc/dogfood-23lang.md`).

Per-language exercises **22 LSP-bound tools** at a curated symbol
position; 16 runtime tools + `echo` + `lsp_request_raw` run once
globally. Total cells per pass = 23 × 22 + 17 = **523**.

Many tools return `-32601 Method not supported` for languages whose
LSP doesn't implement them. Those are recorded as `PASS (-32601)` —
plumbing works, server-side gap. Real failures are `FAIL: <reason>`.

When a per-call timeout fires (pharos returns
`tool timeout: LSP did not respond in <N>ms`), the harness fires
`runtime_set_tool_timeout` to bump the budget for that
(tool, language) pair and retries the original call once. This
mirrors the LLM-realistic recovery path documented in ADR-021.

Usage:

    python3 bin/dogfood-23lang.py                       # dev/stdio/all
    python3 bin/dogfood-23lang.py --transport http      # dev/http/all
    python3 bin/dogfood-23lang.py --profile default     # default surface
    PHAROS_TEST_BIN=burrito_out/pharos_linux_x64 \\
      python3 bin/dogfood-23lang.py --label "binary, post-rebuild"

Pass label appears in the report header so multiple runs can be
diff-walked. Default label = `pharos-dev`.
"""

import argparse
import json
import os
import select
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
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

    `timeout_override_ms` raises the per-call `timeout_ms` for known
    slow LSPs (PLS / metals / jdtls / HLS) above the harness default.
    Cold-index walks on real-world repos can run multi-minutes;
    raising the budget per-language matches what an LLM client would
    do via `runtime_set_tool_timeout` in practice.
    """
    id: str
    file_rel: str
    line: int            # 0-based (LSP convention)
    character: int       # 0-based UTF-16 code-unit offset
    query: str
    # Default lowercase identifier — universally valid for most
    # languages. Per-language overrides set below where the LSP's
    # identifier validator rejects this (scala metals = strict
    # case rules, go = exported-uppercase convention).
    rename_to: str = "renamed"  # for rename_preview
    ws_sym_lang_override: str | None = None
    timeout_override_ms: int | None = None
    # ADR-026 symbol-layer probes. Set to enable find_symbol /
    # get_symbols_overview / find_referencing_symbols / edit_at_symbol
    # cells. When None, those cells are recorded as
    # "no symbol fixture configured" without firing — lets the layer
    # roll out staged (4 reference langs first, expand to 23 once
    # green). `symbol_name_path` resolves to a unique top-level
    # symbol in `file_rel` (single-segment paths today). The edit
    # body is appended after the symbol body in `insert_after` mode;
    # comment-prefix must be valid in the target language so the
    # rendered diff doesn't read as syntactically broken.
    symbol_name_path: str | None = None
    symbol_edit_body: str | None = None

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
    Target("rust",       "src/cargo/lib.rs",                                       163,  7,  "exit_with_error",
                                                                                    symbol_name_path="exit_with_error",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    # `func init()` (line 149 1-based) was the previous target — it's
    # the Go builtin lifecycle hook, has no type / impl / hierarchy,
    # so gopls correctly errored on goto_type/goto_impl/type_hierarchy.
    # Switched to `flagConfig` struct (line 184 1-based) which has
    # both methods and field types — exercises the position-bound
    # tools meaningfully.
    Target("go",         "cmd/prometheus/main.go",                                 182,  5,  "flagConfig",
                                                                                    symbol_name_path="flagConfig",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("typescript", "src/index.js",                                            42,  9,  "withPlugins",
                                                                                    symbol_name_path="withPlugins",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("elixir",     "lib/phoenix.ex",                                           0, 11,  "Phoenix",
                                                                                    timeout_override_ms=60_000,
                                                                                    symbol_name_path="Phoenix",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
    Target("ruby",       "lib/sinatra/base.rb",                                   2152, 11,  "Base",
                                                                                    symbol_name_path="Base",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
    Target("zig",        "src/main.zig",                                             3,  6,  "std",
                                                                                    symbol_name_path="std",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("cpp",        "src/google/protobuf/message.h",                          132,  6,  "Message",
                                                                                    symbol_name_path="Message",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("scala",      "library/src/scala/Tuple.scala",                          113,  7,  "Tuple",
                                                                                    timeout_override_ms=300_000,
                                                                                    symbol_name_path="Tuple",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("clojure",    "src/clj/clojure/core.clj",                                12,  5,  "unquote",
                                                                                    symbol_name_path="unquote",
                                                                                    symbol_edit_body=";; pharos dogfood probe\n"),
    Target("haskell",    "Cabal/src/Distribution/Simple.hs",                       143,  0,  "defaultMain",
                                                                                    timeout_override_ms=180_000,
                                                                                    symbol_name_path="defaultMain",
                                                                                    symbol_edit_body="-- pharos dogfood probe\n"),
    # PLS single-threads workspace indexing on first cross-file query;
    # 240s matches `bin/test-suite.py`'s `serial_per_request_timeout`
    # for perl. Without this, every position-bound tool times out.
    Target("perl",       "lib/Mojolicious.pm",                                     151,  4,  "new",
                                                                                    timeout_override_ms=240_000,
                                                                                    symbol_name_path="new",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
    Target("html",       "scripts/filecheck/fixtures/html/index.html",               0,  0,  "html",
                                                                                    symbol_name_path="h1",
                                                                                    symbol_edit_body="<!-- pharos dogfood probe -->\n"),
    Target("css",        "dist/css/bootstrap.css",                                   6,  0,  "root",
                                                                                    symbol_name_path="root",
                                                                                    symbol_edit_body="/* pharos dogfood probe */\n"),
    Target("json",       "package.json",                                             0,  0,  "name",
                                                                                    symbol_name_path="name",
                                                                                    symbol_edit_body="\n"),
    Target("yaml",       "changelogs/config.yaml",                                   0,  0,  "title",
                                                                                    symbol_name_path="title",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
    Target("markdown",   "README.md",                                                0,  0,  "MDN",
                                                                                    symbol_name_path="GitHub Docs",
                                                                                    symbol_edit_body="<!-- pharos dogfood probe -->\n"),
    Target("terraform",  "main.tf",                                                  0,  0,  "vpc",
                                                                                    symbol_name_path="vpc",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
    Target("erlang",     "apps/rebar/src/rebar3.erl",                               58,  0,  "main",
                                                                                    timeout_override_ms=240_000,
                                                                                    symbol_name_path="main",
                                                                                    symbol_edit_body="%% pharos dogfood probe\n"),
    # jdtls + Gradle cold-build of kafka takes minutes per call;
    # bump generously. Smaller java fixtures are an option too but
    # kafka exercises a real polyglot codebase well.
    Target("java",       "clients/src/main/java/org/apache/kafka/clients/KafkaClient.java",
                                                                                    28, 17,  "KafkaClient",
                                                                                    timeout_override_ms=600_000,
                                                                                    symbol_name_path="KafkaClient",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("gleam",      "src/gleam/list.gleam",                                    52,  7,  "length",
                                                                                    timeout_override_ms=600_000,
                                                                                    symbol_name_path="length",
                                                                                    symbol_edit_body="// pharos dogfood probe\n"),
    Target("lua",        "kong/init.lua",                                          635, 13,  "init",
                                                                                    symbol_name_path="init",
                                                                                    symbol_edit_body="-- pharos dogfood probe\n"),
    Target("bash",       "oh-my-zsh.sh",                                             0,  0,  "main",
                                                                                    symbol_name_path="main",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
    Target("python",     "src/flask/app.py",                                        72,  4,  "_make_timedelta",
                                                                                    symbol_name_path="_make_timedelta",
                                                                                    symbol_edit_body="# pharos dogfood probe\n"),
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
    # ADR-026 symbol layer. find_symbol fires first so its handle
    # threads into find_referencing_symbols + edit_at_symbol (same
    # chaining pattern as *_prepare → *_calls / *_types).
    "find_symbol",
    "get_symbols_overview",
    "find_referencing_symbols",
    "edit_at_symbol",
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
    "runtime_lsp_state",
]

# Tools filtered out under `--profile default` (debug + raw categories).
# `default` profile = read + write + CatDefault essentials. The harness
# uses this list to (a) skip live calls that would error with
# "Tool not enabled" and (b) emit synthetic `PASS (filter rejected)`
# rows so the cell count and the verifier match between profiles.
DEFAULT_FILTERED_TOOLS = [
    "lsp_request_raw",
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
    "runtime_pid_info",
    "runtime_lsp_state",
]


PER_LANG_TIMEOUT_MS = 25_000  # 25s ceiling per LSP-bound call


def build_args(tool: str, t: Target | None, prepared_item=None,
               timeout_ms: int | None = None) -> dict:
    """Compose the `arguments` body for one tool call.

    `t` is None for global tools. `prepared_item` carries the call/type
    hierarchy item from a prior `*_prepare` call when the tool is one
    of the chained `*_incoming_calls` / `*_outgoing_calls` /
    `*_supertypes` / `*_subtypes`.

    Every per-lang LSP-bound tool gets a `timeout_ms` arg so pharos's
    wait does not extend past the harness's outer deadline. Caller
    can pass an override via `timeout_ms` (used by retry-on-timeout).
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
    effective = timeout_ms or t.timeout_override_ms or PER_LANG_TIMEOUT_MS
    tmo = {"timeout_ms": effective}

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
    if tool == "find_symbol":
        if t.symbol_name_path is None:
            return None
        return {
            "name_path": t.symbol_name_path,
            "scope_uri": t.file_uri,
            "policy": "all_matches",
        }
    if tool == "get_symbols_overview":
        if t.symbol_name_path is None:
            return None
        return {"uri": t.file_uri}
    if tool == "find_referencing_symbols":
        # Chained: needs the SymbolHandle returned by find_symbol.
        # `prepared_item` is the handle object extracted from the
        # find_symbol result by `handle_from_find_symbol_result`.
        return {"symbol_handle": prepared_item} if prepared_item else None
    if tool == "edit_at_symbol":
        if not prepared_item or t.symbol_edit_body is None:
            return None
        return {
            "symbol_handle": prepared_item,
            "mode": "insert_after",
            "content": t.symbol_edit_body,
        }
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


def classify(tool: str, obj: dict, expect_filter_reject: bool = False
             ) -> tuple[bool, str, dict | None]:
    if "error" in obj:
        e = obj["error"]
        msg = e.get("message", "")
        # JSON-RPC -32601 (Method not found) is also how pharos's MCP
        # router reports filtered tools at the protocol level — when
        # `default` profile hides a tool, the tools/call dispatch
        # responds with `error.code = -32601`. Treat as a graceful
        # filter rejection when the harness expected it.
        if expect_filter_reject and (e.get("code") == -32601
                                     or "method not found" in msg.lower()):
            return True, "filter rejected (-32601)", None
        return False, f"protocol error {e.get('code')}: {msg[:120]}", None
    result = obj.get("result")
    if result is None:
        return False, "result missing", None
    is_err = bool(result.get("isError"))
    text = ""
    for c in result.get("content", []):
        if c.get("type") == "text":
            text += c.get("text", "")
    low = text.lower()
    if is_err:
        # Pharos returns isError=true with "Tool not enabled" when a
        # caller hits a tool that isn't exposed under the active
        # profile filter. That's the graceful path the M14 plan
        # asserts on under `--profile default`.
        if expect_filter_reject and ("tool not enabled" in low
                                     or "not enabled" in low):
            return True, "filter rejected (Tool not enabled)", result
        if "-32601" in low or "method not found" in low or "unsupported file type" in low:
            return True, "server gap (-32601 / unsupported)", result
        return False, f"isError=true: {text[:160]}", None
    if expect_filter_reject:
        # Tool was supposed to be filtered out under default profile
        # but pharos answered it normally. That's a defect — the
        # filter is leaking. Fail loudly.
        return False, f"expected filter rejection but got OK: {text[:120]}", None
    n = len(text)
    summary = f"ok ({n}b)"
    return True, summary, result


# ---------------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------------


class Transport:
    """Send/receive JSON-RPC against a running pharos process.

    `send(req, timeout_s)` returns the response object whose `id`
    matches `req['id']`, or None on timeout / transport error.
    """

    def initialize(self) -> bool:
        raise NotImplementedError

    def send(self, req: dict, timeout_s: float) -> dict | None:
        raise NotImplementedError

    def cancel(self, rid: int) -> None:
        """Tell pharos to abandon an in-flight request — fire-and-forget
        `notifications/cancelled`. Critical under long runs: without
        cancel, every wall-clock timeout leaves a dispatcher worker
        wedged in pharos waiting on its LSP, which queues subsequent
        requests behind it and ultimately starves the pool. See M14
        pass-1 finding (316 in-flight workers at shutdown)."""
        raise NotImplementedError

    def close(self) -> None:
        raise NotImplementedError


def cancelled_notification(rid: int) -> dict:
    return {
        "jsonrpc": "2.0",
        "method": "notifications/cancelled",
        "params": {"requestId": rid},
    }


class StdioTransport(Transport):
    """Streaming NDJSON over child stdin/stdout. Mirrors the M13 path.

    Pharos's stderr is redirected to a tempfile, not a PIPE. Under
    long runs against real fixtures, pharos can produce >64KB of
    stderr (info/debug log lines), and a PIPE-buffered stderr with
    no concurrent drainer will fill the kernel buffer and deadlock
    pharos. Tempfile lets pharos write freely and post-mortem reads
    work via `transport.stderr_path`.
    """

    def __init__(self, env: dict[str, str]):
        bin_path = env.get(
            "PHAROS_TEST_BIN",
            os.path.join(PROJECT_ROOT, "bin", "pharos-dev"),
        )
        if not os.path.exists(bin_path):
            sys.exit(f"FATAL: pharos binary not found at {bin_path}")
        self.bin_path = bin_path
        self.stderr_path = tempfile.mktemp(prefix="pharos-stdio-stderr-", suffix=".log")
        self._stderr_file = open(self.stderr_path, "w")
        self.proc = subprocess.Popen(
            [bin_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr_file,
            env=env,
            cwd=PROJECT_ROOT,
            text=True,
        )
        self._buf = ""

    def initialize(self) -> bool:
        self.proc.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "dogfood-23lang", "version": "1"},
            },
        }) + "\n")
        self.proc.stdin.write(json.dumps({
            "jsonrpc": "2.0", "method": "notifications/initialized", "params": {},
        }) + "\n")
        self.proc.stdin.flush()

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            obj = self._next_message(deadline)
            if obj is None:
                return False
            if obj.get("id") == 1 and "result" in obj:
                return True
        return False

    def send(self, req: dict, timeout_s: float) -> dict | None:
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        rid = req.get("id")
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            obj = self._next_message(deadline)
            if obj is None:
                return None
            if obj.get("id") == rid:
                return obj
        return None

    def _next_message(self, deadline: float) -> dict | None:
        """Drain one JSON line from stdout, honoring the absolute
        deadline. Returns None on EOF or deadline expiry (callers
        treat both as a failed read)."""
        while True:
            if "\n" in self._buf:
                line, self._buf = self._buf.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                return None
            try:
                chunk = os.read(self.proc.stdout.fileno(), 65536)
            except Exception:
                return None
            if not chunk:
                return None
            self._buf += chunk.decode("utf-8", errors="replace")

    def cancel(self, rid: int) -> None:
        try:
            self.proc.stdin.write(json.dumps(cancelled_notification(rid)) + "\n")
            self.proc.stdin.flush()
        except Exception:
            pass

    def close(self) -> None:
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        try:
            self._stderr_file.close()
        except Exception:
            pass


class HttpTransport(Transport):
    """One-shot POSTs against pharos's HTTP MCP endpoint.

    Spawns pharos with `PHAROS_TRANSPORT=http PHAROS_HTTP_PORT=0
    PHAROS_HTTP_PORT_FILE=...`. Polls the port file for the bound
    port, then POSTs to `http://127.0.0.1:<port>/mcp`. Captures
    `Mcp-Session-Id` from the initialize response and includes it on
    every subsequent request.
    """

    def __init__(self, env: dict[str, str]):
        bin_path = env.get(
            "PHAROS_TEST_BIN",
            os.path.join(PROJECT_ROOT, "bin", "pharos-dev"),
        )
        if not os.path.exists(bin_path):
            sys.exit(f"FATAL: pharos binary not found at {bin_path}")
        self.bin_path = bin_path
        self.port_file = tempfile.mktemp(prefix="pharos-http-port-", suffix=".txt")
        self.stderr_path = tempfile.mktemp(prefix="pharos-http-stderr-", suffix=".log")
        self._stderr_file = open(self.stderr_path, "w")
        env = {
            **env,
            "PHAROS_TRANSPORT": "http",
            "PHAROS_HTTP_PORT": "0",
            "PHAROS_HTTP_BIND": "127.0.0.1",
            "PHAROS_HTTP_PORT_FILE": self.port_file,
        }
        self.proc = subprocess.Popen(
            [bin_path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=self._stderr_file,
            env=env,
            cwd=PROJECT_ROOT,
        )
        self.port = self._wait_for_port_file(timeout_s=60)
        if self.port is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
            sys.exit(f"FATAL: HTTP port file did not appear at {self.port_file}")
        self.base_url = f"http://127.0.0.1:{self.port}/mcp"
        self.session_id: str | None = None

    def _wait_for_port_file(self, timeout_s: float) -> int | None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if os.path.exists(self.port_file):
                try:
                    with open(self.port_file) as f:
                        text = f.read().strip()
                        if text:
                            return int(text)
                except (OSError, ValueError):
                    pass
            time.sleep(0.1)
        return None

    def initialize(self) -> bool:
        init_req = {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "dogfood-23lang", "version": "1"},
            },
        }
        resp = self._post(init_req, timeout_s=30)
        if resp is None:
            return False
        return "result" in resp

    def send(self, req: dict, timeout_s: float) -> dict | None:
        return self._post(req, timeout_s)

    def cancel(self, rid: int) -> None:
        # HTTP transport: each request runs on its mist connection
        # process. Pharos's cancel handler short-circuits on lookup
        # miss (see request_workers.gleam — HTTP doesn't populate
        # the worker table). But emit the notification anyway so the
        # LSP-side `$/cancelRequest` path still fires.
        try:
            self._post(cancelled_notification(rid), timeout_s=5)
        except Exception:
            pass

    def _post(self, body: dict, timeout_s: float) -> dict | None:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if self.session_id is not None:
            headers["Mcp-Session-Id"] = self.session_id
        data = json.dumps(body).encode("utf-8")
        http_req = urllib.request.Request(
            self.base_url, data=data, headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(http_req, timeout=timeout_s) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                if self.session_id is None:
                    sid = resp.headers.get("Mcp-Session-Id")
                    if sid:
                        self.session_id = sid
                if not raw.strip():
                    return None
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    return None
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace") if e.fp else ""
            return {
                "jsonrpc": "2.0",
                "id": body.get("id"),
                "error": {
                    "code": -32000,
                    "message": f"HTTP {e.code}: {body_text[:300]}",
                },
            }
        except Exception as e:  # noqa: BLE001
            return {
                "jsonrpc": "2.0",
                "id": body.get("id"),
                "error": {
                    "code": -32001,
                    "message": f"transport: {type(e).__name__}: {e}",
                },
            }

    def close(self) -> None:
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        try:
            self._stderr_file.close()
        except Exception:
            pass
        try:
            os.unlink(self.port_file)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Call orchestration (timeout retry, chained items)
# ---------------------------------------------------------------------------


def call_one(transport: Transport, rid: int, tool: str, args,
             timeout_s: float, expect_filter_reject: bool = False
             ) -> tuple[bool, str, dict | None]:
    """Send one tools/call, classify the response.

    PASS criteria, in priority order:
      1. response with `"result"` and `isError=false` (or absent) — pass.
      2. response with `"result"` and `isError=true` whose body mentions
         `-32601`/`Method not found`/`unsupported file type` — pass with
         that note (server-side gap, not pharos plumbing).
      3. response with `"error"` field — fail with the error message.
      4. no response within timeout — fail "no response".

    When `expect_filter_reject` is True (caller is firing a tool the
    active profile is supposed to deny), a `Tool not enabled` /
    `-32601` rejection counts as PASS instead of FAIL.
    """
    resp = transport.send(request(rid, tool, args), timeout_s=timeout_s)
    if resp is None:
        return False, f"no response within {timeout_s:.0f}s", None
    return classify(tool, resp, expect_filter_reject=expect_filter_reject)


def is_timeout_summary(summary: str) -> bool:
    """Recognize a timeout — either pharos's typed response (ADR-021)
    OR the harness's own wall-clock deadline firing because pharos's
    typed response never arrived in time.

    Wall-clock fires when total cold-start cost (workspace discovery
    + LSP spawn + initialize + readiness drain + per-call) exceeds
    the harness's outer deadline. The retry path bumps the per-call
    timeout via `runtime_set_tool_timeout` and retries — by the
    retry the LSP is warm, so cold-start is no longer in the budget.
    """
    s = summary.lower()
    if "tool timeout" in s and "lsp did not respond" in s:
        return True
    if s.startswith("no response within"):
        return True
    return False


def runtime_set_tool_timeout_request(rid: int, tool: str, language: str,
                                     timeout_ms: int) -> dict:
    return request(rid, "runtime_set_tool_timeout", {
        "tool": tool, "language": language, "timeout_ms": timeout_ms,
    })


# ---------------------------------------------------------------------------
# Pass driver
# ---------------------------------------------------------------------------


class PoolTracePoller:
    """Periodic snapshot of pool state via runtime_lsp_state +
    runtime_pool_recon. Appends a JSONL record to `path` whenever
    `tick(label)` is invoked and at least `every_s` seconds have
    elapsed since the last successful poll. Reuses the harness's
    own transport (no parallel transport, no thread-safety on
    JSON-RPC ids — caller controls ordering).

    Records have shape:
      {"ts": <unix_ms>, "label": "<phase tag>",
       "lsp_state": <runtime_lsp_state json>,
       "pool_recon": <runtime_pool_recon json>}

    Skips silently if the tool is filtered (default profile) or
    pharos returned an error — diagnostics must never fail the
    pass."""

    def __init__(self, transport: "Transport", path: str | None, every_s: float,
                 rid_start: int):
        self.transport = transport
        self.path = path
        self.every_s = every_s
        self._next_rid = rid_start
        self._last_at = 0.0
        self._fh = open(path, "a") if path else None

    def _alloc_rid(self) -> int:
        self._next_rid += 1
        return self._next_rid

    def tick(self, label: str, force: bool = False) -> None:
        if self._fh is None:
            return
        now = time.monotonic()
        if not force and (now - self._last_at) < self.every_s:
            return
        ts_ms = int(time.time() * 1000)

        def _call(name: str, args: dict, timeout_s: float = 15) -> dict | None:
            rid = self._alloc_rid()
            try:
                resp = self.transport.send(
                    {"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                     "params": {"name": name, "arguments": args}},
                    timeout_s=timeout_s,
                )
            except Exception:  # noqa: BLE001
                return None
            if resp is None or "result" not in resp:
                return None
            content = resp["result"].get("content") or []
            for c in content:
                if c.get("type") == "text":
                    try:
                        return json.loads(c.get("text", ""))
                    except json.JSONDecodeError:
                        return None
            return None

        lsp_state = _call("runtime_lsp_state", {})
        pool_recon = _call("runtime_pool_recon", {"top_n": 15})
        if lsp_state is None and pool_recon is None:
            return  # filtered or pharos refused; skip silently
        rec = {
            "ts": ts_ms,
            "label": label,
            "lsp_state": lsp_state,
            "pool_recon": pool_recon,
        }
        self._fh.write(json.dumps(rec) + "\n")
        self._fh.flush()
        self._last_at = now

    def close(self) -> None:
        if self._fh is not None:
            try:
                self._fh.close()
            except Exception:  # noqa: BLE001
                pass
            self._fh = None


# Module-level handle so run_pass + per-language loop can reach the poller
# without rethreading it through every function signature.
_POOL_POLLER: PoolTracePoller | None = None


def run_pass(transport: Transport, filter_langs: list[str] | None,
             skip: set[str], profile: str
             ) -> list[tuple[str, str, bool, str]]:
    """Returns [(lang, tool, pass, summary), ...]."""
    if not transport.initialize():
        transport.close()
        sys.exit("FATAL: initialize handshake failed")

    rows: list[tuple[str, str, bool, str]] = []
    rid = 100

    targets = TARGETS
    if filter_langs:
        targets = [t for t in TARGETS if t.id in filter_langs]
        if not targets:
            transport.close()
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
        if _POOL_POLLER is not None:
            _POOL_POLLER.tick(f"lang_start:{t.id}", force=True)
        prepared_call_item = None
        prepared_type_item = None
        prepared_symbol_handle = None
        # Broken-LSP fast-path: if a lang's first N tools all
        # retry-exhaust, the LSP itself isn't responding. No point
        # firing the rest — record them as `lsp unresponsive` and
        # move on. Without this, a fully-broken LSP burns ~22 × 170s
        # = ~60 min per pass per pass for nothing.
        consecutive_timeouts = 0
        lsp_broken = False
        BROKEN_LSP_THRESHOLD = 3

        for tool in PER_LANG_TOOLS:
            rid += 1

            if lsp_broken:
                rows.append((t.id, tool, False, "lsp unresponsive (short-circuited)"))
                print(f"  SKIP {tool}: lsp unresponsive (short-circuited)", flush=True)
                continue

            # `default` profile filter: fire the call but expect
            # pharos to reject it with `Tool not enabled` (or
            # `-32601`). Live confirmation is the M14 acceptance
            # criterion: filter rejection is graceful, not a crash.
            expect_reject = profile == "default" and tool in DEFAULT_FILTERED_TOOLS
            if expect_reject:
                args = build_args(tool, t)
                rid_local = rid
                ok, summary, _ = call_one(
                    transport, rid_local, tool, args,
                    timeout_s=10, expect_filter_reject=True,
                )
                rows.append((t.id, tool, ok, summary))
                print(f"  {'PASS' if ok else 'FAIL'} {tool}: {summary}", flush=True)
                continue

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
            elif tool in ("find_referencing_symbols", "edit_at_symbol"):
                args = build_args(tool, t, prepared_symbol_handle)
                if args is None:
                    note = (
                        "no symbol fixture configured"
                        if t.symbol_name_path is None
                        else "find_symbol returned no handle"
                    )
                    rows.append((t.id, tool, False, note))
                    print(f"  SKIP {tool}: {note}", flush=True)
                    continue
            elif tool in ("find_symbol", "get_symbols_overview"):
                args = build_args(tool, t)
                if args is None:
                    rows.append((t.id, tool, False, "no symbol fixture configured"))
                    print(f"  SKIP {tool}: no symbol fixture configured", flush=True)
                    continue
            else:
                args = build_args(tool, t)

            # Harness wall-clock cap = pharos's per-call cap + 45s
            # slack. The slack must cover pharos's cold-start cost
            # (workspace discovery + LSP spawn + initialize handshake
            # + readiness drain) on top of the per-call budget. 45s
            # comfortably covers gopls/rust-analyzer/pyright; slower
            # LSPs already carry explicit `timeout_override_ms`.
            current_tmo_ms = t.timeout_override_ms or PER_LANG_TIMEOUT_MS
            ok, summary, result = call_one(
                transport, rid, tool, args,
                timeout_s=(current_tmo_ms / 1000) + 45,
            )

            # Wall-clock timeout? Tell pharos to abandon the worker
            # so the LSP queue doesn't back up behind a zombie call.
            if not ok and is_timeout_summary(summary):
                transport.cancel(rid)

            # ADR-021 LLM-realistic recovery: bump timeout once via
            # runtime_set_tool_timeout, retry the original call. Only
            # for per-lang LSP-bound tools — global / runtime tools
            # don't honor a per-language timeout knob.
            #
            # Skip retry when the lang already carries a tuned
            # `timeout_override_ms`. Those overrides were chosen for
            # PLS / jdtls / metals / HLS specifically — when the
            # tuned value is itself exceeded, doubling it almost
            # never helps and burns retry-wait minutes per cell.
            # Record FAIL immediately so the report shows the real
            # ceiling instead of a slower retry-exhausted ceiling.
            retry_eligible = (
                not ok
                and is_timeout_summary(summary)
                and t.timeout_override_ms is None
            )
            if retry_eligible:
                bumped_ms = current_tmo_ms * 2
                rid += 1
                # Generous deadline (60s): pharos may still be
                # finishing the timed-out original call when this
                # runtime tool is queued behind it. send() will drop
                # any stale rids that arrive first; the deadline
                # needs to outlast pharos's in-flight work.
                rs_resp = transport.send(
                    runtime_set_tool_timeout_request(rid, tool, t.id, bumped_ms),
                    timeout_s=60,
                )
                rs_ok = rs_resp is not None and "result" in rs_resp
                print(
                    f"  RETRY {tool}: bumping timeout {current_tmo_ms}→{bumped_ms}ms "
                    f"(set_tool_timeout: {'ok' if rs_ok else 'failed'})",
                    flush=True,
                )
                if rs_ok:
                    rid += 1
                    retry_args = build_args(tool, t, prepared_call_item
                                            if tool.startswith("call_hierarchy_")
                                            else prepared_type_item
                                            if tool.startswith("type_hierarchy_")
                                            else prepared_symbol_handle
                                            if tool in ("find_referencing_symbols", "edit_at_symbol")
                                            else None,
                                            timeout_ms=bumped_ms)
                    if retry_args is not None:
                        retry_rid = rid
                        ok2, summary2, result2 = call_one(
                            transport, retry_rid, tool, retry_args,
                            timeout_s=(bumped_ms / 1000) + 45,
                        )
                        if not ok2 and is_timeout_summary(summary2):
                            transport.cancel(retry_rid)
                        if ok2:
                            rows.append((t.id, tool, True,
                                         f"OK (after retry @ {bumped_ms}ms)"))
                            print(
                                f"  PASS {tool}: OK after retry "
                                f"({summary2})",
                                flush=True,
                            )
                            if tool == "call_hierarchy_prepare" and result2:
                                prepared_call_item = first_item_from(result2)
                            elif tool == "type_hierarchy_prepare" and result2:
                                prepared_type_item = first_item_from(result2)
                            elif tool == "find_symbol" and result2:
                                prepared_symbol_handle = handle_from_find_symbol_result(result2)
                            continue
                        rows.append((t.id, tool, False,
                                     f"retry exhausted: {summary2}"))
                        print(
                            f"  FAIL {tool}: retry exhausted "
                            f"({summary2})",
                            flush=True,
                        )
                        consecutive_timeouts += 1
                        if consecutive_timeouts >= BROKEN_LSP_THRESHOLD:
                            lsp_broken = True
                            print(
                                f"  ! LSP for {t.id} marked unresponsive "
                                f"after {BROKEN_LSP_THRESHOLD} consecutive "
                                f"retry exhaustions; short-circuiting rest",
                                flush=True,
                            )
                        continue

            rows.append((t.id, tool, ok, summary))
            print(f"  {'PASS' if ok else 'FAIL'} {tool}: {summary}", flush=True)
            if _POOL_POLLER is not None:
                _POOL_POLLER.tick(f"after_tool:{t.id}:{tool}")
            if ok:
                consecutive_timeouts = 0
            elif is_timeout_summary(summary):
                consecutive_timeouts += 1
                if consecutive_timeouts >= BROKEN_LSP_THRESHOLD:
                    lsp_broken = True
                    print(
                        f"  ! LSP for {t.id} marked unresponsive after "
                        f"{BROKEN_LSP_THRESHOLD} consecutive timeouts; "
                        f"short-circuiting rest",
                        flush=True,
                    )

            if tool == "call_hierarchy_prepare" and ok and result:
                prepared_call_item = first_item_from(result)
            elif tool == "type_hierarchy_prepare" and ok and result:
                prepared_type_item = first_item_from(result)
            elif tool == "find_symbol" and ok and result:
                prepared_symbol_handle = handle_from_find_symbol_result(result)

    print("\n=== global tools ===", flush=True)
    if _POOL_POLLER is not None:
        _POOL_POLLER.tick("global_tools_start", force=True)
    for tool in GLOBAL_TOOLS:
        rid += 1

        expect_reject = profile == "default" and tool in DEFAULT_FILTERED_TOOLS
        args = build_args(tool, None)
        ok, summary, _ = call_one(
            transport, rid, tool, args,
            timeout_s=30, expect_filter_reject=expect_reject,
        )
        rows.append(("(global)", tool, ok, summary))
        print(f"  {'PASS' if ok else 'FAIL'} {tool}: {summary}", flush=True)

    if _POOL_POLLER is not None:
        _POOL_POLLER.tick("pass_complete", force=True)
        _POOL_POLLER.close()

    transport.close()
    return rows


def handle_from_find_symbol_result(result: dict):
    """Extract a SymbolHandle out of a find_symbol result.

    find_symbol returns a Resolution JSON (see
    `pharos/tools/symbols.resolution_to_json`):
      - status="single"   → {match: {handle: {...}, ...}}
      - status="multiple" → {matches: [{handle: {...}, ...}, ...]}
      - status="not_found"→ no handle
    Returns the first handle when available, else None.
    """
    for c in result.get("content", []):
        if c.get("type") != "text":
            continue
        try:
            payload = json.loads(c.get("text", ""))
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        status = payload.get("status")
        if status == "single":
            match = payload.get("match")
            if isinstance(match, dict):
                h = match.get("handle")
                if isinstance(h, dict):
                    return h
        elif status == "multiple":
            matches = payload.get("matches", [])
            if matches and isinstance(matches[0], dict):
                h = matches[0].get("handle")
                if isinstance(h, dict):
                    return h
    return None


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


def write_report(rows, out_path: str, label: str, transport_name: str,
                 profile: str):
    by_lang: dict[str, list] = {}
    for lang, tool, ok, summary in rows:
        by_lang.setdefault(lang, []).append((tool, ok, summary))

    pharos_bin = os.environ.get("PHAROS_TEST_BIN", "bin/pharos-dev")
    total = len(rows)
    passed = sum(1 for _, _, ok, _ in rows if ok)

    lines = [
        f"# Dogfood pass — 23 languages × 43 tools",
        "",
        f"**Label:** {label}",
        f"**Binary:** `{pharos_bin}`",
        f"**Transport:** `{transport_name}`",
        f"**Profile:** `{profile}`",
        f"**Result:** **{passed}/{total} cells PASS** ({100 * passed // max(total,1)}%)",
        "",
        "Per-language LSP-bound tools (26): hover, document_symbols, workspace_symbols, "
        "get_diagnostics, goto_definition, goto_type_definition, goto_implementation, "
        "find_references, signature_help, format_document, code_actions, rename_preview, "
        "inlay_hints, semantic_tokens, call_hierarchy_prepare, call_hierarchy_incoming_calls, "
        "call_hierarchy_outgoing_calls, type_hierarchy_prepare, type_hierarchy_supertypes, "
        "type_hierarchy_subtypes, find_symbol, get_symbols_overview, "
        "find_referencing_symbols, edit_at_symbol, lsp_request_raw, apply_workspace_edit.",
        "",
        "Global one-shot tools (17): echo, runtime_processes, runtime_supervision_tree, "
        "runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util, "
        "runtime_log_tail, runtime_log_level, runtime_log_clear, runtime_trace_lsp, "
        "runtime_kill_lsp, runtime_trace_calls, runtime_language_config, "
        "runtime_set_tool_timeout, runtime_effective_tool_config, runtime_pid_info.",
        "",
        "Result keys: `OK` = response without isError. "
        "`server gap` = isError carrying -32601 / Method not found / unsupported file type — "
        "plumbing fine, LSP doesn't implement it. `FAIL` = anything else. "
        "`OK (after retry …)` = first call timed out, harness fired "
        "`runtime_set_tool_timeout` to bump the budget, retry passed. "
        "`filter rejected (default profile)` rows mark tools the default "
        "profile is configured to deny — graceful filter, not a defect.",
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
            elif "filter rejected" in summary:
                mark = "FILT"
            elif "after retry" in summary:
                mark = "RETRY"
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
    ap.add_argument("--transport", choices=("stdio", "http"), default="stdio",
                    help="MCP transport (default: stdio)")
    ap.add_argument("--profile", choices=("all", "default"), default="all",
                    help="tool surface profile. `all` exposes every category; "
                         "`default` ships read+write+CatDefault and the harness "
                         "records 14 debug+raw tools as `filter rejected` "
                         "without firing them.")
    ap.add_argument("--pool-trace-path", default=None,
                    help="if set, harness writes a JSONL pool-state trace "
                         "(runtime_lsp_state + runtime_pool_recon snapshots) "
                         "to this path. Required for Option B regression "
                         "diagnostics. Forces --profile=all (debug tools).")
    ap.add_argument("--pool-trace-every", type=float, default=20.0,
                    help="poll interval in seconds for the pool-state trace "
                         "(default 20s). Lang-start and pass-end snapshots "
                         "fire regardless.")
    ap.add_argument("--pool-trace-pharos-log",
                    default="info,pharos/lsp/pool/trace=debug",
                    help="value to set as PHAROS_LOG when pool-trace is on. "
                         "Default routes pool-trace events to stderr.")
    args = ap.parse_args()

    skip = set(s.strip() for s in args.skip.split(",") if s.strip())

    env = os.environ.copy()
    env["PHAROS_TOOLS"] = args.profile  # `all` or `default`

    effective_profile = args.profile
    if args.pool_trace_path:
        # Pool-state tools live in `debug` category; default profile
        # filters them. Force `all` so the snapshots actually return
        # data instead of `Tool not enabled`.
        if args.profile != "all":
            print(f"  ! --pool-trace-path forces --profile=all "
                  f"(was {args.profile}); switching", flush=True)
        env["PHAROS_TOOLS"] = "all"
        env["PHAROS_LOG"] = args.pool_trace_pharos_log
        effective_profile = "all"

    if args.transport == "stdio":
        transport: Transport = StdioTransport(env)
    else:
        transport = HttpTransport(env)

    global _POOL_POLLER
    if args.pool_trace_path:
        # Use a high rid offset so poller-owned ids never collide with
        # the main pass's rid space (which starts at 100 and increments).
        _POOL_POLLER = PoolTracePoller(
            transport=transport,
            path=args.pool_trace_path,
            every_s=args.pool_trace_every,
            rid_start=900_000,
        )
        print(f"  pool-trace enabled: {args.pool_trace_path} "
              f"(every {args.pool_trace_every}s)", flush=True)

    try:
        rows = run_pass(transport, args.languages or None, skip, effective_profile)
    except SystemExit:
        raise
    except BaseException:
        try:
            transport.close()
        except Exception:  # noqa: BLE001
            pass
        raise

    write_report(rows, args.out, args.label, args.transport, effective_profile)

    total = len(rows)
    passed = sum(1 for _, _, ok, _ in rows if ok)
    print(f"\n=== {passed}/{total} cells PASS ===")
    print(f"report: {args.out}")
    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
