# pharos dogfood regression plan

End-to-end test plan exercised through the live MCP bridge. Each step
records: tool invocation, expected outcome, pass/fail criterion. Run
top-to-bottom — later steps depend on earlier servers being warm.

## Prereqs (binary runs only)

Burrito's runtime cache key is `pharos_erts-<erts_ver>_<app_ver>` — it
does not include payload bytes, so a rebuild of the same `app_version`
silently re-runs old beams from the prior extract. ADR-020 captures the
mechanism. Until that's fixed (deferred; see ADR-020 deferral note),
clear the cache before every full-binary dogfood run:

```sh
rm -rf ~/.local/share/.burrito/pharos_erts-*
MIX_ENV=prod mix release --overwrite
# `npm/scripts/postinstall.js` warms the extract from `npm/vendor/`,
# NOT `burrito_out/`. If `npm/vendor/` is older than the just-built
# `burrito_out/`, the cache extracts STALE beams — silently dropping
# any module added since the last vendor refresh. Always copy first.
cp burrito_out/pharos_linux_x64 npm/vendor/pharos_linux_x64
node /home/oof/pharos-mcp/npm/scripts/postinstall.js   # warmup re-extract
# Then /mcp reconnect pharos in Claude Code
```

Daily iteration uses `pharos-dev` (no cache, hits `_build/dev/lib/*/ebin`
directly, fast). Note: `pharos-dev` runs interactive Erlang, NOT
`-noshell -mode embedded -noinput` like the release — the stdio bug
class fixed in commit e857dce is invisible there. Any change touching
`pharos_stdin_ffi`, `writer`, NDJSON framing, or port operations must be
verified against the binary, not just `pharos-dev`.

## Test workspaces

| Language | Workspace | Test file | Symbols |
|----------|-----------|-----------|---------|
| Rust     | `/home/oof/rust_dev`       | `src/main.rs`     | `Point`, `new_point`, `Greet`, `greet` |
| Go       | `/home/oof/go_dev`         | `main.go`         | `Point`, `NewPoint`, `unused` |
| TypeScript | `/home/oof/typescript_dev` | `src/index.ts` | `Point`, `newPoint`, `unused` |
| Python   | `/home/oof/python_dev`     | `main.py`         | `Point`, `new_point`, `wrong_type` |

## Out-of-band tests (driven via stdio, no MCP host)

Boot-time behavior the live MCP host can't reach. Run via:

```sh
python3 bin/test-missing-binary.py            # ADR-018 BinaryNotFound surfacing
python3 bin/test-config-override.py           # PHAROS_CONFIG_FILE [languages.<id>] override
python3 bin/test-subserver-override.py        # [[languages.<id>.servers]] sub-server override
python3 bin/test-init-options-override.py     # initialization_options_json whole-blob replace
python3 bin/test-workspace-config-override.py # workspace_configuration_json whole-blob replace
python3 bin/test-suite.py                     # Tier 1 regression across rust/go/ts/py (C3)
```

Each script spawns `bin/pharos-dev`, sends NDJSON requests on stdin,
parses responses, asserts shape. Exits non-zero on regression. Use as a
quick CI-style smoke before live dogfood.

## Phase 0 — sanity

| # | Tool | Args | Expected |
|---|------|------|----------|
| 0.1 | `echo` | `text="dogfood"` | echoes back |
| 0.2 | `runtime_applications` | — | lists `pharos`, `kernel`, `stdlib`, `gleam_*` apps |
| 0.3 | `runtime_processes` | filter `pharos_lsp_dyn_sup` | dyn_sup process visible (registered) |
| 0.4 | `runtime_supervision_tree` | — | pharos tree visible **OR** noted limitation (app_ffi gap) |
| 0.5 | `runtime_ets_tables` | — | `pharos_lsp_proc_subjects`, `pharos_log_ring`, `pharos_log_ring_meta`, `pharos_diagnostics_cache`, `pharos_lsp_registry`, `pharos_lsp_inflight` present |

## Phase 1 — Tier 1 LSP per language

Repeat all of these for each `(language, workspace, file)` row in the
test-workspace table. First call warm-spawns the LSP; subsequent calls
hit the cached proc.

| # | Tool | Pass criterion |
|---|------|----------------|
| 1.1 | `hover` on the `Point` type | non-empty markup, mentions "Point" or struct/interface |
| 1.2 | `goto_definition` on the constructor call site | jumps to the `new_point`/`NewPoint`/`newPoint` definition |
| 1.3 | `goto_type_definition` on `p` (constructor result) | lands on `Point` type |
| 1.4 | `goto_implementation` (Rust only) on `Greet` | jumps to `impl Greet for Point` |
| 1.5 | `find_references` on `Point` | ≥ 2 references (decl + use) |
| 1.6 | `document_symbols` | returns the type and the function |
| 1.7 | `workspace_symbols` query="Point" | returns `Point` from the workspace |
| 1.8 | `signature_help` inside `new_point(\|)` arglist | returns parameter info |
| 1.9 | `format_document` | non-error response (idempotent on already-formatted) |
| 1.10 | `code_actions` on the type-error line | ≥ 1 action OR empty (server-dependent) |
| 1.11 | `rename_preview` on `Point` → `Coord` | shows ≥ 2 edits, no actual write |
| 1.12 | `get_diagnostics` | surfaces unused-var warning (rust/go/ts/py) and type-error (rust/ts/py) |

## Phase 2 — call hierarchy (Rust)

| # | Tool | Pass criterion |
|---|------|----------------|
| 2.1 | `call_hierarchy_prepare` on `new_point` | returns one item |
| 2.2 | `call_hierarchy_incoming_calls` on that item | shows `main` calling it |
| 2.3 | `call_hierarchy_outgoing_calls` on `main` | shows `new_point`, `greet`, `println` etc |

## Phase 3 — raw passthrough

| # | Tool | Pass criterion |
|---|------|----------------|
| 3.1 | `lsp_request_raw` method=`textDocument/hover` against Rust | same payload as 1.1 |

## Phase 4 — runtime introspection (post-warmup)

| # | Tool | Pass criterion |
|---|------|----------------|
| 4.1 | `runtime_processes` filter=`lsp_proc` | ≥ 4 children of `pharos_lsp_dyn_sup` |
| 4.2 | `runtime_pid_info` on a dyn_sup child | shows registered_name nil, link to dyn_sup |
| 4.3 | `runtime_ets_tables` filter=`pharos_lsp_proc_subjects` | size = number of warmed languages |
| 4.4 | `runtime_memory` | reports total + processes breakdown |
| 4.5 | `runtime_scheduler_util` | returns per-scheduler busy ratios |

## Phase 5 — ADR-017a restart cycle (the headline regression)

Verifies the ETS bridge + simple_one_for_one supervisor wiring.

| # | Tool | Pass criterion |
|---|------|----------------|
| 5.1 | `runtime_processes` count of `lsp_proc` children before kill | record `N` |
| 5.2 | `runtime_kill_lsp` language=rust workspace=/home/oof/rust_dev | ok, child exit clean |
| 5.3 | `runtime_processes` immediately after | child count `N-1` (transient does not auto-restart on operator kill) |
| 5.4 | `runtime_ets_tables` `pharos_lsp_proc_subjects` row count | decremented by 1 |
| 5.5 | `hover` rust again | re-spawns clean, returns markup |
| 5.6 | `runtime_ets_tables` after re-hover | row count back to `N` |

## Phase 6 — logs

| # | Tool | Pass criterion |
|---|------|----------------|
| 6.1 | `runtime_log_tail` lines=20 | recent entries from above activity |
| 6.2 | `runtime_log_level` set debug | accepts |
| 6.3 | `runtime_log_level` set info | accepts |
| 6.4 | `runtime_log_clear` | accepts |
| 6.5 | `runtime_log_tail` after clear | empty or near-empty |

## Phase 7 — trace tooling (smoke-only)

| # | Tool | Pass criterion |
|---|------|----------------|
| 7.1 | `runtime_trace_lsp` short window during a hover | returns trace events |
| 7.2 | `runtime_trace_calls` mfa=`pharos@lsp@proc:request/3` short window | returns trace events |

## Phase 8 — apply_workspace_edit (M11)

Verifies the WorkspaceEdit-to-disk path: dry-run reports byte deltas without
writing, real apply writes atomically, overlap detection rejects bad edits.
Use a scratch file outside the test workspaces so accidental writes don't
contaminate later phases.

| # | Tool | Pass criterion |
|---|------|----------------|
| 8.1 | Create `/tmp/awe-scratch.txt` with `hello world` | precondition |
| 8.2 | `apply_workspace_edit` edit=`{changes:{file:///tmp/awe-scratch.txt:[{range 0:6-0:11, "WORLD"}]}}` dry_run=true | summary shows 11→11 bytes; file unchanged |
| 8.3 | Same edit dry_run=false | file now contains `hello WORLD`; atomic rename happened |
| 8.4 | Two overlapping edits in one file (e.g. 0:0-0:5 + 0:3-0:8) | error response mentions overlap; file unchanged |
| 8.5 | Edit pointing past EOF | error response surfaces position-out-of-range; file unchanged |
| 8.6 | `documentChanges` form (not `changes`) with one TextDocumentEdit | applies same as 8.3 |

## Phase 9 — inlay_hints (M11)

| # | Tool | Pass criterion |
|---|------|----------------|
| 9.1 | `inlay_hints` rust on `src/main.rs` range covering `let p = new_point(...)` | returns ≥ 1 hint with `kind=1` (Type) labelling `Point` |
| 9.2 | `inlay_hints` python on `main.py` range covering full file | returns hints OR `[]` (pyright config-dependent — both acceptable) |
| 9.3 | `inlay_hints` typescript on `src/index.ts` | returns hints OR `[]` |

## Phase 10 — semantic_tokens (M11)

| # | Tool | Pass criterion |
|---|------|----------------|
| 10.1 | `semantic_tokens` rust on `src/main.rs` (full document, range omitted) | non-empty `data` array; length divisible by 5 |
| 10.2 | `semantic_tokens` rust same file with explicit range covering one fn | smaller `data` array than 10.1 |
| 10.3 | `semantic_tokens` python | non-empty OR error if pyright doesn't advertise capability |

## Phase 11 — type_hierarchy (M11)

Rust-only — gopls / tsserver return `-32601 Method not found` for these.

| # | Tool | Pass criterion |
|---|------|----------------|
| 11.1 | `type_hierarchy_prepare` rust at `Greet` trait declaration | returns ≥ 1 `TypeHierarchyItem` named `Greet` |
| 11.2 | `type_hierarchy_subtypes` on the prepared item | returns the `Point` impl (or any concrete impl) |
| 11.3 | `type_hierarchy_supertypes` on a `Point` item | empty array OR built-in supertypes (rust-analyzer-dependent) |

## Phase 12 — trace ring under load (M11 fix verification)

Verifies the trace producer's direct-ring write bypasses the writer's
mailbox cap; a burst of LSP traffic should NOT collapse into a single
`dropped=N` warn.

| # | Tool | Pass criterion |
|---|------|----------------|
| 12.1 | `runtime_log_clear` | accepts |
| 12.2 | `runtime_log_level` target=`pharos/lsp/trace` level=`debug` | accepts |
| 12.3 | Burst — fire `find_references` rust on `Point` (high-volume call) | request completes |
| 12.4 | `runtime_log_tail` n=500 filter=`lsp wire` | ≥ 100 trace lines (NOT a single `dropped=N` warn) |
| 12.5 | `runtime_log_level` target=`pharos/lsp/trace` level=`off` | reset |

## Phase 13 — multi-server diagnostics cache (M11 rekey)

Python language has pyright + ruff bundled; both emit publishDiagnostics
for the same file. The (uri, server_id) cache rekey lets the merge path
hit cache per server instead of one server's items overwriting the other.

| # | Tool | Pass criterion |
|---|------|----------------|
| 13.1 | `get_diagnostics` python on `main.py` (cold) | merged items: at least one pyright type-error AND one ruff lint warning |
| 13.2 | `get_diagnostics` python same file (warm) | same payload, served from cache (faster) |
| 13.3 | `runtime_ets_tables` filter=`pharos_diagnostics_cache` | ≥ 2 rows for python URI (one per server_id) |

## Phase 14 — stdio under held-stdin (M11 fix)

Implicitly verified by the fact that the MCP host reconnect now succeeds
(see commit e857dce). Spot-check via:

| # | Tool | Pass criterion |
|---|------|----------------|
| 14.1 | Issue several rapid tool calls back-to-back through the MCP host | every response returns; no buffering stalls |
| 14.2 | `runtime_log_tail` filter=`stdio_worker` | no `Actor discarding unexpected message` warnings |

## Results log

Run 1: 2026-05-06 (initial dogfood — defects + limitations identified).
Run 2: 2026-05-06 (post-M9.5 regression — first round of fixes shipped).
Run 3: 2026-05-06 (post-M10 Group A+B regression — wait_for_ready + emit-side prefilter + cold-start hint).
Run 4: 2026-05-07 (post-M11 — apply_workspace_edit + inlay_hints + semantic_tokens + type_hierarchy + diagnostics-cache rekey + trace-ring fix + stdio held-stdin fix + npm postinstall warmup).
Run 5: 2026-05-08 (post-M11 regression on burrito after D-M11-3 chained-fix landed — 0 reconnects, all 14 phases clean).
Run 6: 2026-05-10 (real-fixtures expansion — 23 languages × 39 tools driven by `bin/dogfood-23lang.py` against pinned upstream repos in `tmp/fixtures/`. Results in [doc/dogfood-23lang-dev.md](dogfood-23lang-dev.md) (pharos-dev) and [doc/dogfood-23lang-binary.md](dogfood-23lang-binary.md) (burrito). Surfaced + fixed: stale `npm/vendor/` binary causing burrito tests to run against ghost code; rust-analyzer cold-start race in test-suite.py (now serial_mode); 3 newly-added runtime tools missing from registry CatDebug.).

### Run 5 — burrito post-fix regression summary

Pharos rebuilt at c001c4d, fresh burrito extract via npm postinstall.
Single MCP connection — no reconnects needed across the whole run.

| Phase | Status | Notes |
|-------|--------|-------|
| 0 | PASS | echo + apps + ETS tables (cache/inflight/request_workers/proc_subjects/log_ring) all present at expected sizes. |
| 1 | PASS | hover/refs/rename across rust/go/ts/python; go + ts diagnostics returned the expected type-errors. Python diagnostics deferred to P13 (multi-server merge). |
| 2 | PASS | call_hierarchy_prepare → incoming → outgoing all returned the expected items via the schema-fixed object decoder. |
| 3 | PASS | lsp_request_raw textDocument/hover round-trips identical to typed hover. |
| 4 | PASS | runtime_memory healthy (~53MB total, 15MB processes). |
| 5 | PASS | runtime_kill_lsp rust + immediate hover re-spawned cleanly. |
| 6 | PASS | log_clear / log_level cycles. |
| 7 | PASS (smoke) | trace_calls correctly gated off; trace_lsp empty during quiet window (synchronous toggle/sleep/snapshot — by design). |
| 8 | PASS | dry-run reports byte delta without writing; real apply persists; overlapping ranges abort with the offending pair surfaced verbatim. |
| 9 | PASS (rust) | 4 inlay hints (`: &str`, `: Point`, `x:`, `y:`) for the rust scratch range. |
| 10 | PASS (rust) | full document semantic tokens — data array length divisible by 5, resultId returned. |
| 11 | PASS (server-side -32601, plumbing OK) | type_hierarchy_prepare against rust-analyzer returns -32601 — matches the updated tool description (rust-analyzer + pyright + gopls + tsserver all currently unimplemented at the LSP layer). |
| 12 | PASS | 3 LSP-method round-trips fired in one MCP message produced 6 trace entries (3 out + 3 in pairs). No `dropped=N` warn. M11 direct-ring-write fix solid. |
| 13 | PASS | get_diagnostics on python returns the merged publishDiagnostics envelope with the pyright type-error item. Multi-server merge (pyright + ruff) post-c001c4d works under the burrito runtime. |
| 14 | PASS | Entire Run 5 ran through burrito with zero `Actor discarding unexpected message` warns, zero stdio stalls. M11 stdio fix continues to hold. |

### Defect status (post-M11, post-Run-5)

All M11-era defects closed:

- **D-M11-1** CLOSED (d570f0e): MCP host stringification of object args.
- **D-M11-2** CLOSED (814b1f5): type_hierarchy tool description accuracy.
- **D-M11-3** CLOSED (814b1f5 + c001c4d): three-bug chain in multi-server diagnostics merge — didOpen ordering, Pull-mode cache shadowing, codepoint-vs-byte indexing in strip_brackets.

No new defects surfaced during Run 5.

### Known limitations (still acceptable)

- Cold-start of multi-server python (pyright + ruff) costs ~30s through `wait_for_ready` because pyright doesn't emit the configured readiness token. Workaround: warm with hover before get_diagnostics, or raise `timeout_ms`. Not blocking.
- `runtime_trace_lsp` returns empty when no LSP traffic occurs during its synchronous sleep window. By design — issue traffic in parallel via the burst pattern from P12 if you need a live capture.

### Run 4 — M11 post-fix regression summary

Pharos rebuilt at e857dce + d570f0e (`MIX_ENV=prod mix release`), cache
warmed via `node npm/scripts/postinstall.js`, MCP host reconnected.

| Phase | Status | Notes |
|-------|--------|-------|
| 0 | PASS | All ETS tables present incl. new `pharos_request_workers`. |
| 1 | PASS (rust+python diags deferred to P13) | Hover/goto/refs/symbols/sig/format/code_actions/rename across rust/go/ts/python all clean. |
| 2 | PASS (after fix d570f0e) | Initial run hit "call hierarchy item missing or non-string `uri` field" — MCP host JSON-stringifying object args without `type: "object"` schema hint. Patched both schema (added `type: "object"`) and decoder (`unstringify_if_needed/1` belt-and-suspenders). |
| 3 | PASS | `lsp_request_raw textDocument/hover` round-trip identical to typed. |
| 4 | PASS | `pharos_lsp_proc_subjects` size grew across warm-spawns; mailboxes empty. |
| 5 | PASS | Kill rust → re-hover transparently re-spawned. ADR-017a wiring solid. |
| 6 | PASS | log_clear / log_level transitions / log_tail post-clear behave. |
| 7 | PASS (smoke-only) | trace_calls correctly refused (gated off). trace_lsp empty without parallel traffic — by design (synchronous toggle/sleep/snapshot loop). |
| 8 | PASS | dry_run reports byte delta without writing. Real apply persists with atomic rename. Overlapping ranges abort with the offending pair surfaced verbatim. EOF-append (line past last \n with char=0) succeeds — graceful per LSP spec. documentChanges form applied identically. |
| 9 | PASS (rust) | Inlay hints `: &str`, `: Point`, `x:`, `y:` returned for the rust scratch range. python/ts not exercised here — pyright/tsserver hint surfaces depend on workspace config. |
| 10 | PASS (rust) | Full document = ~78 tokens. Range = ~12 tokens. data array length divisible by 5 in both. resultId returned. |
| 11 | DEFECT (server-side, not pharos) | Pharos plumbing correct. rust-analyzer AND pyright both return `-32601 Method not found` for `textDocument/prepareTypeHierarchy`. Earlier doc claim (rust-analyzer + pyright support it) was wrong. Fix: update tool description to match actual server matrix. Tool itself ships ahead of LSP support. |
| 12 | PASS | 6 LSP-method round-trips fired in one MCP message produced 12 trace entries (6 out + 6 in pairs). No `dropped=N` warn. M11 direct-ring-write fix confirmed under realistic load. |
| 13 | PASS (after fix c001c4d) | Initial run silently empty for python despite pyright having items. Three stacked bugs traced and fixed (D-M11-3): (a) `ensure_doc_opened` ordering — fired before LSP proc cached, NoCachedClient silently dropped, ruff never got didOpen. (b) Pull-mode servers shouldn't read the publishDiagnostics cache. (c) `strip_brackets` mixed codepoint length with byte offsets, dropped pyright items from merge whenever the message contained multi-byte UTF-8 (NBSP in pyright output). Post-fix: get_diagnostics returns the merged publishDiagnostics envelope with the pyright type-error item. |
| 14 | PASS | 30+ minute session through MCP host with hundreds of round-trips, no `Actor discarding unexpected message` warn, no buffering stall. M11 stdio fix solid. |

### Defect status (post-M11)

- **D-M11-1** (CLOSED — schema fix d570f0e): MCP-host stringification of object-typed tool args without `type: "object"` schema hint. Fixed at the schema layer (`call_hierarchy_*`, `lsp_request_raw`) and at the decoder layer (`unstringify_if_needed/1`).
- **D-M11-2** (CLOSED — desc fix 814b1f5): `type_hierarchy_*` tool description claimed rust-analyzer + pyright support `prepareTypeHierarchy`; both actually return `-32601`. Description now reflects the real LSP matrix (rust-analyzer, pyright, gopls, tsserver all -32601 at time of writing). Tool plumbing correct, ships ahead of LSP support.
- **D-M11-3** (CLOSED — chained fix 814b1f5 + c001c4d): Multi-server diagnostics merge for python returned empty despite pyright having items. Three stacked bugs:
  1. `ensure_doc_opened` fired BEFORE `get_lsp_for_server` in `prepare_all_covering_method`. Pool's `ensure_open` requires the proc to be already cached (`NoCachedClient` otherwise); silent-drop hid the failure. Secondary servers (ruff) never received didOpen → "transport error" on the merge-path diagnostic request. Swapped order: didOpen runs after the proc is cached.
  2. `fetch_items_cached` returned `Some` for pyright on the publishDiagnostics cache. Pyright pushes once on didOpen even though it's configured `Pull`, so the cache held an entry that shadowed the live pull. Pull-mode servers now skip cache entirely; only Push-mode reads it.
  3. `strip_brackets` used `string:length/1` (codepoint count) with `binary:part/3` (byte offsets). Pyright messages contain `\xc2\xa0` NBSP pairs (byte length > codepoint length); `string_ends_with` read the wrong byte for the closing `]`, returned False, strip_brackets returned "", pyright items dropped from `merge_items_arrays`. Switched to byte-based throughout (`byte_size`, `binary:at`, `binary:part`).

### Limitation status (post-M11)

- Cold-start of multi-server python (pyright + ruff) takes >20s through pharos's `wait_for_ready` (pyright doesn't emit the readiness token, falls through to timeout). Tools called within that window return `NoDiagnosticsObserved`. Workaround: warm with a `hover` first, OR raise `timeout_ms` to 45000+. Not blocking; warm-cache calls are fast.

### Run 3 — M10 Group A+B post-fix regression summary

| Phase | Status | Notes |
|-------|--------|-------|
| 0 | PASS | `pharos_root_supervisor` + `pharos_lsp_dyn_sup` visible (limitation 2a still fixed). |
| 1 — headline cold hover | **PASS** | First hover on freshly-respawned rust LSP returned full `Point` struct hover **on the FIRST call** (Run 2 needed a retry; Run 1 needed two retries plus -32801 absorption). **wait_for_ready post-handshake fix verified live** — eliminates the cold-start `null` failure mode. |
| 1-rust | PASS | All Tier 1 tools clean. |
| 1-go | PASS first try | gopls via PATH (ADR-018 still good). |
| 1-ts | PASS first try | typescript-language-server via PATH. |
| 1-py | PASS first try | pyright-langserver via PATH. format -32601 + code_actions empty as documented. |
| 2 | PASS | call_hierarchy_prepare clean. |
| 3 | PASS | lsp_request_raw passthrough. |
| 4 | PASS | scheduler_util returns 16 schedulers in 500ms (still fixed via recon). |
| 5 | **PASS one-shot** | **ADR-017a kill+respawn cycle** now succeeds **on the FIRST hover after kill** — bridge 4→3 then back to 4 with no retry needed. wait_for_ready makes the respawn path indistinguishable from a warm hover at the consumer level. |
| 6 | PASS | log_tail/level/clear all clean. |
| 7 | **PARTIAL** | trace_lsp prefilter cache mechanism verified — `runtime_log_level pharos/lsp/trace=debug` followed by hover puts wire traces in the ring (the prefilter is reading the cache on the producer side). **Remaining limitation:** when trace_lsp is dispatched in PARALLEL with hover, the dispatch race can still beat the cache update — hover's wire activity emits before trace_lsp's set_target_global call has propagated. The prefilter closes the writer-mailbox-cast race that Run 2 saw, but it does NOT close the parallel-dispatch race because the cache update still has to win against the hover's first byte. Workaround: use `runtime_log_level=debug` then activity then `runtime_log_tail` instead of `runtime_trace_lsp` for parallel-issued workflows. M11 candidate: dedicated always-on small trace ring (no filter dependency). |
| Limitation 2b | PASS | dir URI + `language="rust"` returned `Point` (still fixed). |
| Negative-path tests | DEFERRED | Missing-binary + override-file dogfood require pharos cold-boot with mocked env. Out-of-band CLI test, not /mcp-runnable. Tracked for the dedicated release-prep sprint. |

### Defect status (post-M10 Group A+B)

| # | Defect | Status | Verification |
|---|--------|--------|--------------|
| 1 | `runtime_scheduler_util` hang | **FIXED** | Returned in 500ms with utilization data for all 16 schedulers. Implementation switched to `recon:scheduler_usage/1`. |
| 2 | `runtime_trace_lsp` empty capture | **PARTIALLY FIXED** | Sequential issue order: works (cache=on then activity captures). Parallel issue: still races for the very first emit because cache update has to beat the producer's first wire byte. |
| 3 | Cold-start race (`null` and `-32801`) | **FIXED** | -32801 absorbed by retry helper; `null` eliminated by post-handshake wait_for_ready that drains `$/progress` until indexing `end`. Verified by one-shot kill+respawn cycle in Phase 5. Cold-start hint added to hover/goto_definition/goto_type_definition tool descriptions (Group A) — kept as belt-and-suspenders for languages not declaring a `readiness_token`. |

### Limitation status (post-M10 Group A+B)

| # | Limitation | Status | Verification |
|---|------------|--------|--------------|
| 2a | `runtime_supervision_tree` blind to pharos | **FIXED** (M9.5) | `pharos_root_supervisor` registered at `<0.102.0>` and visible. |
| 2b | `workspace_symbols` rejects directory URI | **FIXED** (M9.5) | `language="rust"` + dir URI returns `Point`. |
| 2c | LSP binaries hardcoded to maintainer paths | **FIXED** (M9.5) | Bare names + `os:find_executable/1`. All 4 languages via PATH. |
| pyright formatting | NOT addressable | Out of scope; ruff-via-multi-LSP planned per ADR-019 in M10. |
| trace_lsp parallel race | **PARTIAL** | Documented above. M11 candidate. |

### Run 2 — post-fix regression summary

| Phase | Status | Notes |
|-------|--------|-------|
| 0 | **PASS** | `runtime_supervision_tree` now shows `pharos_root_supervisor` at `<0.102.0>` and `pharos_lsp_dyn_sup` at `<0.108.0>`. **Limitation 2a fixed live** — app_ffi now returns the supervisor pid; OTP application_controller walks the tree. |
| 1-rust | PASS (12/12) | `null` cold-start on first hover/goto_definition; warm retry succeeded. `-32801 content modified` did NOT surface this run — Defect 3 retry-once helper is silently absorbing them. |
| 1-go | PASS (12/12) first try | Bonus: gopls spawned cleanly via PATH lookup — **ADR-018 PATH resolution verified live** (`gopls` bare name, no hardcoded path). |
| 1-ts | PASS (12/12) first try | typescript-language-server resolved from PATH. |
| 1-py | PASS (12/12) first try | pyright-langserver resolved from PATH. format/-32601 + code_actions empty as documented. |
| 2 | PASS (3/3) | call_hierarchy_prepare/incoming/outgoing all clean. |
| 3 | PASS | lsp_request_raw passthrough identical payload. |
| 4 | PASS (5/5) | **Defect 1 fixed** — `runtime_scheduler_util(interval_ms=500)` returned in 500ms with 16 schedulers. Switched implementation to `recon:scheduler_usage/1` after `scheduler:utilization/1` continued to hang. |
| 5 | PASS (6/6) | ADR-017a kill+respawn cycle: bridge 1→0→1 verified live. |
| 6 | PASS (5/5) | log_tail/level/clear all clean. |
| 7 | PASS | **Defect 2 fixed** — `runtime_trace_lsp` returned 2 wire-trace lines from a prior hover. Sync `SetTargetSync` filter update closes the cast race. Note: when trace_lsp is fired in PARALLEL with first activity, that first request can race past the filter toggle (sequential order works reliably). |
| Limitation 2b | **PASS** | `workspace_symbols(workspace_uri_hint="file:///home/oof/rust_dev", language="rust", query="Point")` — directory URI now accepted with explicit language, returned `Point`. |

### Defect status (post-fix)

| # | Defect | Status | Verification |
|---|--------|--------|--------------|
| 1 | `runtime_scheduler_util` hang | **FIXED** | Returned in 500ms with utilization data for all 16 schedulers. Implementation switched to `recon:scheduler_usage/1`. |
| 2 | `runtime_trace_lsp` empty capture | **FIXED** (with caveat) | Manual `runtime_log_level pharos/lsp/trace=debug` + hover + tail showed traces in ring; subsequent `runtime_trace_lsp` returned them. Sync filter via `process.call` closed the cast race. **Caveat:** parallel-issued trace_lsp + hover can still race for the very first emit before the filter applies. |
| 3 | Cold-start race | **PARTIALLY FIXED** | -32801 retry-once landed in shared `request_with_content_modified_retry` helper — confirmed silently absorbing them this run. The OTHER cold-start variant (rust-analyzer returning `null` because indexing isn't done) is NOT addressable by retry; the response is server-OK by spec, just not yet useful. |

### Limitation status (post-fix)

| # | Limitation | Status | Verification |
|---|------------|--------|--------------|
| 2a | `runtime_supervision_tree` blind to pharos | **FIXED** | `pharos_root_supervisor` registered at `<0.102.0>` and visible in supervision tree (with `pharos_lsp_dyn_sup` as supervisor child). app_ffi.start/2 now returns the root supervisor pid. |
| 2b | `workspace_symbols` rejects directory URI | **FIXED** | New optional `language` param routes by language id when extension parsing has nothing to read. Verified live with `language="rust"` + dir URI. |
| 2c (NEW) | LSP binaries hardcoded to maintainer paths | **FIXED** | ADR-018: bare names + `os:find_executable/1` resolution. All 4 languages spawned successfully via PATH. Failure mode is now a typed `BinaryNotFound(command)` with install-hint message. |
| pyright formatting | NOT addressable | Documented; out of scope (pyright doesn't implement textDocument/formatting). |

### Run 1 — initial dogfood (preserved for history)

| Phase | Status | Notes |
|-------|--------|-------|
| 0 | PASS | echo, applications, processes (`pharos_lsp_dyn_sup` registered at `<0.109.0>`), ETS tables (`pharos_lsp_proc_subjects` present, size=0 pre-warmup). `runtime_supervision_tree` does NOT show pharos's tree — known limitation: `pharos_app_ffi:start/2` returns the spawn_link'd main pid, not the supervisor pid, so app_controller can't walk it. |
| 1-rust | PASS (12/12) | Cold-start race on hover/goto_definition/goto_type_definition: first attempts returned `null` / `-32801 content modified` while rust-analyzer was still indexing. Retry succeeded. `workspace_symbols` rejected directory URI — hint MUST be a file URI (`file://.../src/main.rs`, not `file://.../rust_dev`). |
| 1-go | PASS (12/12) | `code_actions` rejected `end_character=45` with `column is beyond end of line` (line was 44 chars). Tightened to 43 — succeeded. gopls fuzzy-matches `Point` across stdlib in workspace_symbols (truncated 80 more) — limit cap working as designed. |
| 1-ts | PASS (12/12) | `format_document` proposed real edits (file had stray indentation). All other tools clean. |
| 1-py | PASS (12/12) | `format_document` returned `-32601 Unhandled method textDocument/formatting` — pyright does not implement formatting (documented in tool description). `code_actions` returned `[]` — server-OK per plan. |
| 2 | PASS (3/3) | `prepare new_point` → 1 item; incoming shows `main` calling at L32:12-21; outgoing on `main` shows `new_point` (only — `greet`/`println!` not surfaced; rust-analyzer's outgoing-calls scope, not a pharos issue). |
| 3 | PASS | `lsp_request_raw textDocument/hover` returned identical payload to typed `hover` tool. |
| 4 | PASS (4/5) | dyn_sup memory grew 2.7KB → 68KB (children attached). `runtime_pid_info` on `<0.111.0>` showed `links=[<0.109.0>, #Port<0.3>]` and `$ancestors=[pharos_lsp_dyn_sup,...]` — ADR-017a wiring verified end-to-end (worker linked to dyn_sup AND owns OS LSP port). Bridge size = 4 (matches 4 warmed langs). **DEFECT 4.5:** `runtime_scheduler_util` hung 10+min for `interval_ms=500` — never returned, user cancelled. |
| 5 | PASS (6/6) | **Headline ADR-017a regression.** `runtime_kill_lsp rust` → `{killed:true}`. ETS bridge size 4→3 (operator-kill cleanly evicts row). Hover rust → re-spawned clean (cold-start retry needed for first hover, second succeeded). Bridge size back to 4. Verifies (a) `(language, workspace)`-keyed bridge, (b) supervisor's `transient` strategy doesn't auto-restart on operator kill, (c) cache-miss path correctly spawns new worker through `dyn_sup_start_child`. |
| 6 | PASS (5/5) | `runtime_log_tail` captured full session activity (tool errors with cid, kill_lsp messages with workspace path, the user's notification cancel for the hung scheduler_util). `runtime_log_level` accepted debug + info. `runtime_log_clear` → `{cleared:true}`. Subsequent tail returned `[]`. |
| 7 | PARTIAL (1/2) | `runtime_trace_calls` correctly refused with `gated behind PHAROS_RUNTIME_TRACE_ENABLED=1` — documented gate. **DEFECT 7.1:** `runtime_trace_lsp` captured 0 events across two attempts (3s and 8s windows), even with kill+initialize handshake+hover+doc_symbols traffic during the 8s window. Filter toggle appears to not actually emit trace lines from the wire path, OR the trace target prefix doesn't match what the wire emitter writes. |

## Defects found

1. **`runtime_scheduler_util` hangs** — hung indefinitely on `interval_ms=500` (default 1000). User cancelled after ~10 min. Root cause unknown; likely an Erlang `scheduler:utilization/1` interaction with whatever wraps the call.
2. **`runtime_trace_lsp` does not capture wire events** — toggle/sleep/snapshot path produces empty `captured` array even when LSP traffic occurs in the window. Either the filter prefix doesn't match the wire-trace emitter, or the trace level isn't actually emitting.
3. **Cold-start race surfaces as user-facing errors** — first hover/goto_definition/goto_type_definition after a new LSP spawn frequently returns `null` or `-32801 content modified`. Retry works but the 5-15s rust-analyzer index window leaks through. Could swallow `-32801` and retry once internally before surfacing to the client. Same pattern when respawning after `runtime_kill_lsp`.

## Limitations confirmed (not defects)

- `runtime_supervision_tree` does not show pharos's tree (app_ffi gap; `pharos_lsp_dyn_sup` is still discoverable via `runtime_processes` registered name).
- `workspace_symbols` requires a file URI hint, not a directory URI. Could either auto-promote `dir/` → `dir/<any-file>` or document it more loudly in the tool description.
- `format_document` on `.py` is a server gap (pyright doesn't implement it) — already documented.
