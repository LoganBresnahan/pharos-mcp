# M13 test plan — every tool × every language × stdio + http

Owner-approved scope: pharos cannot tag a release until every MCP tool
surface is exercised by an automated harness, against every supported
language, on both stdio and HTTP transports.

This doc captures the matrix, the acceptance criteria, the
implementation phases, and the deliverables. Treat it as the
release-prep checklist for M13.

## Tool inventory

37 distinct MCP tools shipped today. 22 are per-language (LSP-bound),
15 are language-agnostic (debug + echo). Subgroup breakdown:

### Per-language LSP-bound (22 tools × 22 langs = 484 cells per transport)

**Read (17):**
- hover
- goto_definition, goto_type_definition, goto_implementation
- find_references
- document_symbols, workspace_symbols
- signature_help
- get_diagnostics
- inlay_hints, semantic_tokens
- call_hierarchy_prepare, call_hierarchy_incoming_calls, call_hierarchy_outgoing_calls
- type_hierarchy_prepare, type_hierarchy_supertypes, type_hierarchy_subtypes

**Write (4):**
- rename_preview (no file mutation, dry-run)
- format_document
- code_actions
- apply_workspace_edit (round-trip: mutate → verify → revert)

**Raw (1):**
- lsp_request_raw

### Language-agnostic (15 tools × 1 boot = 15 cells per transport)

- echo
- runtime_processes, runtime_pid_info, runtime_supervision_tree
- runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util
- runtime_log_tail, runtime_log_clear, runtime_log_level
- runtime_trace_lsp, runtime_kill_lsp, runtime_trace_calls
- runtime_language_config

## Cell count

| Layer | Stdio | HTTP | Total |
|---|---|---|---|
| Per-lang × per-tool (22 × 22) | 484 | 484 | 968 |
| Lang-agnostic (15) | 15 | 15 | 30 |
| Both-transport edges | n/a | n/a | ~5 |
| **Total** | **499** | **499** | **~1003** |

Plus 5 plumbing tests already shipped (BinaryNotFound, language
override, sub-server override, init_options_json,
workspace_configuration_json). Those stay; not in this matrix.

## Acceptance criteria per cell

PASS = response is a valid JSON-RPC `result` (not error response) AND
EITHER:
- a tool-specific landmark substring appears in the rendered text, OR
- a documented "method not supported" / "cold-start tolerance" /
  "empty result" condition fires (tracked via existing test-suite
  tolerance helpers).

The harness must NEVER FAIL on a known-tolerable LSP behavior:
- `-32601` method not supported (HTML/CSS/JSON/YAML LSPs lack
  workspace/symbol; HLS pre-index for hover/documentSymbol)
- `-32603` timeout (next-ls/jdtls/ruby-lsp cold start)
- `-32098` position-outside (terraform-ls, when cursor lands on
  whitespace/punctuation)
- `null` / `[]` / `{"contents":[]}` (empty result at cursor
  position; valid LSP response)
- "no diagnostics observed yet" (cold get_diagnostics push timing)
- "tsserver still initializing" / "metals BSP bootstrap"

Each tolerance must be DOCUMENTED inline in the harness with a
comment naming which LSP behavior triggers it.

## Phase plan

Five new harnesses + one harness improvement, then HTTP mirror, then
final binary dogfood. Each phase commits and is independently
verifiable.

### Phase 1 — `bin/test-debug.py` (language-agnostic)

15 cells, single pharos boot, no LSP needed. Each runtime_* tool gets
a request, harness asserts response shape:

- `runtime_processes` → list contains `pharos_lsp_dyn_sup` registered
  name
- `runtime_pid_info` against the dyn_sup pid → returns
  `registered_name`, `current_function`, etc.
- `runtime_supervision_tree` → renders a tree with the root
  supervisor name
- `runtime_ets_tables` → `pharos_lsp_proc_subjects`,
  `pharos_diagnostics_cache`, `pharos_lsp_registry` etc. all present
- `runtime_memory` → returns `total`, `processes`, `atom`, `binary`,
  `ets` keys
- `runtime_applications` → contains pharos, kernel, stdlib
- `runtime_scheduler_util` → returns per-scheduler busy ratios
- `runtime_log_tail` → returns recent log entries
- `runtime_log_clear` → returns OK; subsequent log_tail shows fewer entries
- `runtime_log_level` → returns OK; subsequent emits at the level appear
- `runtime_trace_lsp` → returns OK with empty captures (no LSP active)
- `runtime_kill_lsp` → returns NotFound (no LSP cached at fixture time)
- `runtime_trace_calls` → gated; returns "disabled" or runs briefly
- `runtime_language_config` → returns the bundled rust config (paste-ready TOML)
- `echo` → text round-trips

Cost: ~1h. Confirms 15 tools that have NEVER been auto-tested.

### Phase 2 — `bin/test-raw.py` (lsp_request_raw)

Single language (rust), single tool. Send raw `textDocument/hover`
via `lsp_request_raw`, assert response shape mirrors the wrapped
`hover` tool.

Cost: ~30 min.

### Phase 3 — `bin/test-suite-tier1.py` (17 read tools × 22 langs)

Replaces the current `test-suite.py`'s 4-tool smoke. 374 cells.

Each LangSpec gains:
- A position for hover/goto/refs (already have via point_decl_line)
- An EXPECTED-SYMBOL position (cursor on a constructor call site, for
  goto_definition to land somewhere useful)
- Per-tool expected substring (already have for the 4 covered)

Tools that depend on prior state (call_hierarchy_incoming/outgoing
need an item from prepare; type_hierarchy_supertypes/subtypes need
the prepare result) get sequenced: harness fires `_prepare`, parses
the response, threads its `item` arg into the follow-up call.

Tolerances reuse existing tolerance helpers; new ones added as
real LSP behavior surfaces.

Cost: ~half-day to wire all 17. Cell count is the long pole — running
this once across 22 langs is ~30-min wall-clock.

### Phase 4 — `bin/test-suite-write.py` (4 write tools × 22 langs)

88 cells. Three flavors:

- `rename_preview` — dry-run; assert returned `WorkspaceEdit` mentions
  the target symbol's old + new name. No file mutation.
- `format_document` — assert non-error response. Some servers
  (pyright, html, css) return `-32601`; tolerate per existing rule.
- `code_actions` — assert ≥ 0 actions OR empty list (server-dependent).
- `apply_workspace_edit` — round-trip:
  1. Snapshot file content.
  2. Apply a known WorkspaceEdit (insert a comment line).
  3. Verify file content changed.
  4. Revert (re-apply with the inverse edit OR write the snapshot).
  5. Verify final content matches snapshot.

Cost: ~half-day. apply_workspace_edit is the long pole.

### Phase 5 — `bin/test-edges.py`

Edge-case harness. NOT per-language; uses a stub LSP for
determinism.

- Cold-start race: spawn fresh, fire concurrent requests, verify
  retry-on-content-modified absorbs the race.
- Mid-call cancel: spawn LSP, fire long-running request, send
  `notifications/cancelled`, verify worker terminates and inflight
  table is cleaned.
- Transport-error retry: kill LSP mid-request, verify pool re-spawns
  and tool returns success.
- Post-didOpen drain race: simulate concurrent first-touches, verify
  only one drain fires (post_didopen_drained `try_claim` path).

Stub LSP: a small Python script that speaks LSP framing and emits
deterministic responses with controllable delays. Lives at
`bin/_stub_lsp.py`.

Cost: full day.

### Phase 6 — HTTP transport (`bin/_pharos_drive_http.py` + 4 HTTP twins)

Mirror every stdio harness over HTTP.

`_pharos_drive_http.py`:
- Boots pharos with `PHAROS_TRANSPORT=http PHAROS_HTTP_PORT=0
  PHAROS_HTTP_PORT_FILE=/tmp/pharos.port`
- Polls /tmp/pharos.port for the bound port
- Drives requests via curl/requests against `http://127.0.0.1:<port>/mcp`
- Captures `Mcp-Session-Id` from `initialize` response, includes on
  subsequent calls
- Same response-streaming shape as stdio drive

HTTP twins:
- `bin/test-suite-tier1-http.py`
- `bin/test-suite-write-http.py`
- `bin/test-debug-http.py`
- `bin/test-raw-http.py`

Most LSP behavior is identical between transports — the LSP doesn't
know what's behind pharos. The harness re-runs the same SPECS.

Cost: full day. Most of it is the drive-http helper; twins are
mechanical.

### Phase 7 — `bin/test-both-transports.py`

`PHAROS_TRANSPORT=both`. Drive stdio AND HTTP simultaneously with
overlapping tool calls. Verify:
- Each transport sees only its own responses.
- In-flight cancel from one transport doesn't disturb the other
  (M9 ADR-016 keys per-session).
- Session-id routing works (HTTP server-initiated requests reach
  the originating client).

Cost: half-day.

### Phase 8 — Final binary dogfood

After every harness phase passes against `bin/pharos-dev`, run the
ENTIRE matrix against the burrito-built binary:

```sh
rm -rf ~/.local/share/.burrito/pharos_erts-*
mix release --overwrite
node /home/oof/pharos/npm/scripts/postinstall.js
# update ~/.claude.json to point at burrito_out/pharos_linux_x64
# /mcp reconnect pharos in Claude Code
# OR: drive every harness against burrito directly via MCP_SPAWN env
```

Same harness scripts, different binary. The full release-stdio bug
class (commit e857dce — `:user` group leader buffering, `prim_tty`
fd-0 claim, `-noinput` requirement) only surfaces under burrito's
release runtime, NOT under pharos-dev. This phase is the gate that
catches stdio-class bugs before tag.

Cost: ~1h running, ~undetermined fixing whatever surfaces.

## Acceptance criterion for v0.0.2-m12 → v0.1.0

`python3 bin/test-suite-tier1.py && python3 bin/test-suite-write.py
&& python3 bin/test-raw.py && python3 bin/test-debug.py &&
python3 bin/test-edges.py && (HTTP twins) &&
python3 bin/test-both-transports.py` returns 0 across all 22 working
languages, against BOTH `bin/pharos-dev` AND the burrito-built binary.

Scala and gleam stay marked as known-flaky/upstream-broken in the
SPECS; harness skips them in the default invocation but each has a
single-tool dogfood path documented.

## Out of scope for M13 testing

- Cross-version LSP regressions (we test against ONE version of each
  LSP, whatever's installed at harness-time). Future CI may matrix
  LSP versions.
- Performance benchmarks. The harness validates correctness, not
  latency. Pharos's existing trace_lsp + log_tail surface gives
  enough observability without dedicated perf tests yet.
- Crash-recovery beyond what `test-edges.py` covers (e.g. BEAM-level
  hot-restart of pharos itself). Out of release-blocker scope.
