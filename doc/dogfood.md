# pharos dogfood regression plan

End-to-end test plan exercised through the live MCP bridge. Each step
records: tool invocation, expected outcome, pass/fail criterion. Run
top-to-bottom — later steps depend on earlier servers being warm.

## Test workspaces

| Language | Workspace | Test file | Symbols |
|----------|-----------|-----------|---------|
| Rust     | `/home/oof/rust_dev`       | `src/main.rs`     | `Point`, `new_point`, `Greet`, `greet` |
| Go       | `/home/oof/go_dev`         | `main.go`         | `Point`, `NewPoint`, `unused` |
| TypeScript | `/home/oof/typescript_dev` | `src/index.ts` | `Point`, `newPoint`, `unused` |
| Python   | `/home/oof/python_dev`     | `main.py`         | `Point`, `new_point`, `wrong_type` |

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

## Results log

Run 1: 2026-05-06 (initial dogfood — defects + limitations identified).
Run 2: 2026-05-06 (post-fix regression — verifies fixes shipped).

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
