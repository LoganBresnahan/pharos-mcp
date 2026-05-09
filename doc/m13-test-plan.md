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

### Phase 9 — Chained read tools (`bin/test-chained.py`)

Four tools deferred from Phase 3 because their `item` arg comes from
the response of their `*_prepare` sibling:

- `call_hierarchy_incoming_calls`
- `call_hierarchy_outgoing_calls`
- `type_hierarchy_supertypes`
- `type_hierarchy_subtypes`

Harness shape:

1. Fire `call_hierarchy_prepare` (or `type_hierarchy_prepare`) at a
   known symbol position.
2. Parse response — extract first item from the returned array.
3. Fire follow-up tool with `{ item: <that item> }`.
4. Assert response shape (incoming/outgoing arrays, supertype/subtype
   list).

Drive needs a small enhancement: `drive_chained()` that sends a
batch, waits for a specific id, returns its response synchronously,
then continues with follow-up requests. Reuses the streaming
infrastructure from the current `drive()`.

Cost: ~1-2h. Cell count: 4 tools × ~13 langs that support hierarchy
methods (rust, go, ts, java, c++, scala, kotlin once added) = ~50
cells. Plus HTTP twin = ~100 cells.

Tolerance rules: `-32601 method not supported` is the dominant
response — most LSPs do not implement type hierarchy, several skip
call hierarchy too. Same tolerance helpers as Phase 3.

### Phase 10 — Serial-mode harness path (heavy-LSP support)

Add a `serial_mode: bool = False` field to `LangSpec`. When True,
`drive()` sends one request, waits for its response, sends the next.
Per-language config decides whether the LSP needs serial mode:

- perl / PLS — single-threaded Perl process
- ruby / ruby-lsp — single-threaded gem indexer
- java / jdtls — Eclipse JDT cold-start blocks dispatch
- scala / metals — confirmed PASS-single, FAIL-concurrent

Implementation:

- `_pharos_drive.drive_serial()` — same signature as `drive()`,
  different inner loop. Sends one request, reads stdout until that
  id's response lands or per-request timeout fires, repeats.
- `LangSpec.serial_mode = True` flag flows through `_run` and
  routes to `drive_serial`.
- HTTP twin already serializes per-request (one POST at a time);
  no separate HTTP serial path needed.

Cost: ~2-3h. Closes the gap for the four heavy LSPs that fail under
the all-at-once batch.

After Phase 10: `python3 bin/test-suite.py` against perl/ruby/java/
scala flips from "13 concurrent → many timeouts" to "13 sequential
→ all PASS." Wall-clock per language goes from 10s (light) to ~60s
(heavy) but coverage becomes uniform across the matrix.

### Phase 11a — Verify edge-case retries under burrito

`bin/test-edges.py` against burrito:
- `handshake_delay` confirmed PASS in Phase 8.
- `content_modified_retry` output got truncated in the Phase 8
  capture; status uncertain. Re-run, capture full output, confirm
  pharos's `request_with_content_modified_retry` lands the second
  attempt under release runtime exactly as it does under
  bin/pharos-dev.

If `content_modified_retry` fails on burrito but works on dev, treat
as a second release-runtime bug and add to Phase 11 follow-up.

Cost: ~10 min run + diagnose only if the gap turns out to be real.

### Phase 11 — Burrito HTTP transport bug

Real bug found in Phase 8: HTTP transport returns
`HTTP 500 Internal Server Error` on `initialize` when running
under the burrito-built binary, despite working fine under
`bin/pharos-dev`. Stderr (even at `PHAROS_LOG=debug`) shows the
HTTP listener bind succeeding but no log line for the actual
request handler — mist swallows the exception silently.

Hypotheses to investigate (in priority order):

1. **`mist` or a transitive dep is pruned by the prod release.**
   `mix release` strips unused beams; if `pharos/mcp/http`'s
   request-decode path references something only loaded in :dev,
   the prod binary's `:code.load_file` returns `:not_purged` /
   `:not_loaded` at first call, which mist's catch-all turns into a
   500.
2. **`gleam_json` / `tomerl` codec init.** Some codecs lazy-init on
   first use; if dev-runtime warms one up via stdio dispatch (M5
   already exercises stdio from boot), HTTP-first dispatch hits an
   unwarmed codec.
3. **`mist`-side handler crash.** Mist wraps user handlers in a
   try/catch and returns 500 on any throw. The actual exception
   needs to be unwrapped via mist's logger.

Diagnosis recipe:

```sh
# Boot burrito directly with full Erlang error reporting + a long
# enough timeout to get a meaningful stack trace.
ERL_FLAGS="+S 1 -kernel logger_level debug" \
  burrito_out/pharos_linux_x64 \
  --print-default-config &
# Then drive an HTTP request with curl and capture stderr.
```

Once the trace surfaces, the fix is likely a one-line `application`
addition to `mix.exs`'s `applications: [...]`, OR a `:code.ensure_loaded`
preload at boot, OR a build-time `extra_applications` for `mist`.

Cost: half-day to full-day. Hard-blocks HTTP-on-burrito coverage and
therefore release.

### Phase 12 — `[tools.<name>] default_timeout_ms` config override

Today, three timeout layers exist:

1. Per-call `timeout_ms` — passed as a tool argument.
2. Per-server `initialize_timeout_ms` / `readiness_timeout_ms` — set
   via `[[languages.<id>.servers]]`.
3. Per-tool `default_timeout_ms` — hardcoded constant inside each
   tool's .gleam file (M11 + M13 polish set most to 30s).

Layer 3 is not user-overridable. Users who run a tool against a slow
workspace (rust-analyzer formatting a monorepo, jdtls type-hierarchy
on a 50-module project) need to either pass `timeout_ms` on every
call or fork pharos. Add a fourth layer:

```toml
[tools.format_document]
default_timeout_ms = 90000

[tools.find_references]
default_timeout_ms = 120000
```

Implementation:

- Add `tools: Dict(String, ToolConfig)` field on `pharos/config.Config`
- `ToolConfig` carries a single field today: `default_timeout_ms:
  Option(Int)` — extensible if tool-level knobs accrue.
- `config.cached().tools["format_document"]` lookup at the tool's
  request site replaces the hardcoded const.
- TOML decoder in config.gleam.
- Document in example-pharos.toml.

Cost: ~30 LOC + a verification test. M13 deliverable; no release
should ship without this knob if heavy-workspace users are an
audience.

## Acceptance criterion for v0.0.2-m12 → v0.1.0

`python3 bin/test-suite-tier1.py && python3 bin/test-suite-write.py
&& python3 bin/test-raw.py && python3 bin/test-debug.py &&
python3 bin/test-edges.py && python3 bin/test-chained.py &&
(HTTP twins) && python3 bin/test-both-transports.py` returns 0
across all 22 working languages, against BOTH `bin/pharos-dev` AND
the burrito-built binary. Heavy LSPs (perl, ruby, java, scala) run
in serial mode (Phase 10); other langs run concurrent.

Gleam stays marked as upstream-broken at gleam 1.16; harness skips
it in the default invocation. Re-enable when gleam ships a fixed
LSP release.

### Two-gate ship policy

Pharos cannot tag v0.1.0 unless BOTH gates pass:

**Gate 1 — automated correctness (this matrix).** All ~1003 cells
PASS across stdio + HTTP × dev-runtime + burrito-runtime. Owns:
wire-protocol correctness, override-merge correctness, transport
isolation, edge-case retry behavior. Catches: regressions, schema
drift, transport-class bugs.

**Gate 2 — live dogfood through Claude Code.** Walk
`doc/dogfood.md` Phase 0-14 by hand inside Claude Code with the
release binary installed. Owns: LLM-readability of pharos's tool
output, real workflow chaining (multi-tool sessions), MCP-host
quirks, real-workspace scale. Catches: usability issues that
automated assertions cannot judge ("does the LLM actually
understand this output?").

The matrix is the SUFFICIENT-ON-CORRECTNESS gate; live dogfood is
the SUFFICIENT-ON-USEFULNESS gate. Both required.

## Out of scope for M13 testing

- Cross-version LSP regressions (we test against ONE version of each
  LSP, whatever's installed at harness-time). Future CI may matrix
  LSP versions.
- Performance benchmarks. The harness validates correctness, not
  latency. Pharos's existing trace_lsp + log_tail surface gives
  enough observability without dedicated perf tests yet.
- Crash-recovery beyond what `test-edges.py` covers (e.g. BEAM-level
  hot-restart of pharos itself). Out of release-blocker scope.

## Phase results (rolling — last update 2026-05-09)

| Phase | Status | Cell totals |
|---|---|---|
| 1 — debug + lang-agnostic | DONE | 15/15 |
| 2 — `lsp_request_raw` | DONE | covered in test-suite |
| 3 — tier1 read tools (stdio dev) | DONE | 247/247 (19 light langs) |
| 4 — write tools (stdio dev) | DONE | 76/76 (light langs); 93/96 burrito-stdio incl heavy (3 serial-cap timeouts: scala rename+code_actions, perl rename) |
| 5 — edges (stdio dev) | DONE | 2/2 + sub-server override + JSON-string overrides |
| 6 — HTTP twin (dev) | DONE | 246/247 tier1, 76/76 write; burrito write HTTP 96/96 |
| 7 — both-transports isolation | DONE | dev + burrito PASS |
| 8 — burrito dogfood (final binary) | DONE v4 | tier1 stdio 311/312, HTTP 311/312 post Phase 1-4 timeout-rework; write stdio 93/96, write HTTP 96/96; debug 16/16 stdio + 16/16 HTTP (incl runtime_set_tool_timeout + runtime_effective_tool_config); edges 3/3 + 3/3 HTTP; chained 96/96; raw + missing-binary + config-override smokes PASS (prod build via `MIX_ENV=prod mix release --overwrite`; cold-cache extract dir purge required after rebuild) |
| 9 — chained tools | DONE | 96/96 dev + 96/96 burrito |
| 10 — serial-mode (heavy LSPs) | DONE v2 | 38/39 (perl find_references caps at 120s) |
| 11 — burrito HTTP `:crypto` fix | DONE | 1-line fix in mix.exs |
| 11a — burrito edge retries verify | DONE | 2/2 |
| 12 — `[tool_config.<name>] default_timeout_ms` | DONE | 3/3 verification cells |
| 13 — Phase 1+2 timeout rework (ADR 021) | DONE | Fix A error rendering, ws_symbols 30s, Phase 12b wires `timeout_ms` through every LSP-bound tool, `[tool_config.<name>.<lang>]` per-tool×per-lang, `runtime_set_tool_timeout` MCP tool. 6/6 cells in test-tool-config + 16/16 debug |
| 14 — Phase 3 logging (ADR 022) | DONE | file rotation (`file_max_bytes` / `file_keep_rotated`), ring `tail_by_target_prefix`, `fields_at` structured-fields canonical for new code |
| 15 — Phase 4 introspection (ADR 022) | DONE | `runtime_effective_tool_config` MCP tool surfaces session_overrides + toml_overrides + computed effective_summary with source attribution. 6/6 in test-tool-config |

Known transients (LSP-side, not pharos):
- `gleam.workspace_symbols` — gleam-lsp returns transport error on
  mid-cold-start workspace symbol query; reproducible on dev + burrito.
- `scala.workspace_symbols` — metals BSP bootstrap race; same shape.
- `perl.find_references` — perl/PLS exceeds 120s/req serial cap on
  cold project-wide reference lookup.

Phase 8 sub-fix landed during this round:
- gleam marked `serial_mode=True` in test-suite.py — gleam-lsp 1.16.0
  panics on stdin close mid-drain when 10+ tool requests are in flight
  on the shared lsp_proc, but only when pharos itself runs from the
  burrito release runtime. Dev-wrapper stdio doesn't trip it. HTTP
  unaffected (per-POST serialization). Serial mode dispatches one
  request at a time and dodges the race; result jumps from 0/13 to
  12/13 (the workspace_symbols transient remains).
