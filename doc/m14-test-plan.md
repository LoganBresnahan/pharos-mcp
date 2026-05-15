# M14 test plan — real-fixtures dogfood matrix

Owner-approved scope: M14 expands M13's per-tool × per-language test
matrix from synthetic 4-language workspaces (`/home/oof/<lang>_dev/`)
to pinned upstream repos cloned by `bin/dogfood-fixtures.sh`. Real
codebases surface different defects than synthetic targets — Run 6
of the 23-lang dogfood already proved that (rename_preview
null-handling, ruby-lsp Gemfile dependency, terraform-ls provider
init, gopls bad-target shape errors).

This doc captures the M14 matrix, harness changes, acceptance
criteria, and run-out checklist. Treat as the second release gate
after M13's tier1+HTTP regression.

## Why M14 (and not M13 follow-up)

M13's harness pattern: `bin/test-suite.py` + `bin/test-suite-http.py`
drive 24 tiny synthetic workspaces. Each `Point/new_point` lookup
exercises the dispatch machinery but never trips the long-tail bugs
that show up under real-world LSP indexing (multi-second
`workspace_symbols`, real diagnostic publish cadence, real provider
downloads, Gemfile inspection at handshake).

M13's 312/312 cells PASS does not imply pharos handles
`gleam-lang/stdlib`, `cabal-install`, or `terraform-aws-vpc`
gracefully. M14 closes that gap by replacing the synthetic fixtures
with real upstream code at pinned SHAs.

## Matrix

8 passes total — every combination of {pharos-dev, burrito} ×
{stdio, http} × {`tools = ["all"]`, `tools = ["default"]`}. Cells:

| Profile | Binary | Transport | Cells per pass |
|---------|--------|-----------|----------------|
| all     | dev    | stdio     | 23 × 22 + 17 = 523 |
| all     | dev    | http      | 23 × 22 + 17 = 523 |
| all     | binary | stdio     | 23 × 22 + 17 = 523 |
| all     | binary | http      | 23 × 22 + 17 = 523 |
| default | dev    | stdio     | 23 × 22 + 4 + 15 filter-rejections = 535 |
| default | dev    | http      | 23 × 22 + 4 + 15 filter-rejections = 535 |
| default | binary | stdio     | 23 × 22 + 4 + 15 filter-rejections = 535 |
| default | binary | http      | 23 × 22 + 4 + 15 filter-rejections = 535 |

The "default" passes also assert that the 15 non-default tools
return "Tool not enabled" responses (filter rejection is graceful,
not a crash).

## Tool inventory

39 distinct MCP tools shipped at M14 start. Categories per
`pharos/tools/registry.category_for/1`:

### Per-language LSP-bound (22 tools)

**Read (17):**
hover, goto_definition, goto_type_definition, goto_implementation,
find_references, document_symbols, workspace_symbols, signature_help,
get_diagnostics, inlay_hints, semantic_tokens,
call_hierarchy_prepare, call_hierarchy_incoming_calls,
call_hierarchy_outgoing_calls, type_hierarchy_prepare,
type_hierarchy_supertypes, type_hierarchy_subtypes

**Write (4):**
rename_preview, format_document, code_actions, apply_workspace_edit

**Raw (1):**
lsp_request_raw

### Language-agnostic (17 tools)

**Default (4)** — ship in production profile alongside read+write:
- echo (smoke test)
- runtime_set_tool_timeout (timeout-recovery escape hatch)
- runtime_effective_tool_config (timeout diagnostic)
- runtime_language_config (config introspection)

**Debug (13)** — opt-in only:
- runtime_processes, runtime_pid_info, runtime_supervision_tree,
  runtime_ets_tables, runtime_memory, runtime_applications,
  runtime_scheduler_util
- runtime_log_tail, runtime_log_clear, runtime_log_level
- runtime_trace_lsp, runtime_trace_calls
- runtime_kill_lsp

## Fixtures

23 pinned upstream repos cloned by `bin/dogfood-fixtures.sh` to
`tmp/fixtures/<lang>/`. See `bin/dogfood-fixtures.sh --list` for the
full table. Highlights:

| Lang | Repo | Notes |
|------|------|-------|
| rust | `rust-lang/cargo` | Workspace structure stress test |
| go | `prometheus/prometheus` | Idiomatic + diagnostics-rich |
| typescript | `prettier/prettier` | Monorepo (workspace_symbols stress) |
| haskell | `haskell/cabal` | HLS cold-build via cabal v2-repl |
| java | `apache/kafka` | jdtls + Gradle daemon cold-build |
| perl | `mojolicious/mojo` | PLS single-thread first cross-file query |
| ruby | `sinatra/sinatra` | + post-clone `bundle add ruby-lsp` |
| terraform | `terraform-aws-modules/terraform-aws-vpc` | + post-clone `terraform init` (845MB AWS provider) |

Per-language post-clone setup runs from `bin/dogfood-fixtures.sh`
when a missing dependency would block LSP handshake (ruby-lsp gem
must be in workspace's Gemfile.lock; terraform-ls needs `.terraform/`
populated).

## Harness — `bin/dogfood-23lang.py`

Single Python harness drives all 8 passes. Already covers the M13-era
stdio/all-tools axis. M14 adds:

### Required additions (M14 entry criterion)

1. **HTTP transport driver.** `--transport {stdio,http}` flag.
   HTTP path: spawn pharos with `PHAROS_TRANSPORT=http
   PHAROS_HTTP_PORT_FILE=/tmp/dogfood-port.txt`, poll the port file
   for the bound port, POST tool calls to `http://127.0.0.1:<port>/mcp`
   with the standard MCP-Session-Id round-trip. Reuse `_pharos_drive`
   helpers where they exist.

2. **`PHAROS_TOOLS=<profile>` env propagation.** `--profile
   {all,default}` flag toggles the env var the spawned pharos sees:
   - `all` → `PHAROS_TOOLS=all` (every category exposed)
   - `default` → `PHAROS_TOOLS=default` (read + write +
     CatDefault essentials only; 15 debug + raw tools filtered out)

3. **Retry-on-timeout via `runtime_set_tool_timeout`.** When
   `call_one` parses a `tool timeout: ...` response from pharos,
   the harness fires
   `runtime_set_tool_timeout(tool=<failed>, language=<t.id>,
   timeout_ms=<2× current>)` then re-fires the original call once.
   Records the escalation as part of the cell outcome:
   - `OK (1st try)` — direct pass
   - `OK (after retry)` — passed after timeout-bump
   - `FAIL (retry exhausted)` — second attempt also timed out
   - `GAP (server -32601)` — same as today; not retried

   Mirrors the LLM-realistic recovery path documented in ADR-021.
   Validates the `runtime_set_tool_timeout` tool itself under load.

### Already done (carried over from M13 dogfood)

- 23-fixture target table (`TARGETS` in dogfood-23lang.py)
- Per-target `timeout_override_ms` for known-slow LSPs (perl 240s,
  java 180s, scala/haskell/elixir 60s)
- Chained tool plumbing (call_hierarchy_prepare →
  incoming/outgoing, type_hierarchy_prepare → super/subtypes)
- Markdown report generation, one file per pass

### `"all"` filter alias

`config.tool_allowed/3` extended to recognise the literal
`"all"` entry in the filter list. `tools = ["all"]` (or
`PHAROS_TOOLS=all`) short-circuits to "every category exposed" —
shorthand for `["read", "write", "debug", "raw", "default"]`. Lands
together with the harness changes.

## Acceptance criteria per cell

Same shape as M13:

- **OK** — pharos returned a non-error result.
- **GAP** — pharos returned `isError=true` whose body matches one of:
  `-32601`, "Method not found", "unsupported file type". The LSP
  doesn't implement the method; pharos plumbing fine.
- **OK (after retry)** — first call hit `tool timeout`, harness
  fired `runtime_set_tool_timeout` to bump, second call passed.
  Counts as PASS.
- **FAIL** — anything else, including:
  - Non-timeout server errors (`server error 0: <reason>`)
  - Pharos-side decode errors
  - LSP spawn failures (server transport, missing binary)
  - Retry-exhausted timeouts

A pass is **green** when every cell is OK / GAP / OK-after-retry.
A small number of FAIL cells is acceptable when documented as
LSP-side issue and tracked in a defect entry below; it's not a
release blocker.

## Phase plan

### Phase 1 — Harness expansion (M14 entry)

Land:
1. `"all"` filter alias in `pharos/config.tool_allowed/3` + tests.
2. `--transport {stdio,http}` flag + HTTP driver in
   `bin/dogfood-23lang.py`. Reuse `_pharos_drive` patterns.
3. `--profile {all,default}` flag.
4. `runtime_set_tool_timeout` retry-on-timeout in `call_one`.
5. Smoke run: dev stdio all-tools (1 pass) — verify cell counts
   match expectation.

Acceptance: 1 pass green-or-tracked-defects, harness usable for
the remaining 7 passes.

### Phase 2 — All-tools matrix (4 passes)

Run, in order:
1. `dev / stdio / all` → `doc/dogfood-23lang-dev-stdio-all.md`
2. `dev / http / all` → `doc/dogfood-23lang-dev-http-all.md`
3. `binary / stdio / all` → `doc/dogfood-23lang-binary-stdio-all.md`
4. `binary / http / all` → `doc/dogfood-23lang-binary-http-all.md`

Each pass: ~30-45 min wall time (LSP cold-starts dominate).

Verify per-pass:
- Total cell count matches profile expectation
- Same 4 binary × transport reports show the same per-language
  cell totals (production code identical across them; differences
  are flake / LSP non-determinism, NOT pharos defects)

### Phase 3 — Default-profile matrix (4 passes)

Run, in order:
5. `dev / stdio / default`
6. `dev / http / default`
7. `binary / stdio / default`
8. `binary / http / default`

Each pass: ~20-30 min (24 tools × 23 langs + 15 filter-rejection
assertions = 552 cells; faster than all-tools because no LSP-bound
calls for filtered debug tools).

Verify per-pass:
- The 15 filtered tools return "Tool not enabled" responses
  (graceful filter rejection — no -32602 dispatcher errors)
- The 24 visible tools work identically to their all-profile
  counterparts (filter is non-destructive; same code paths)

### Phase 4 — Cross-pass diff

After all 8 passes complete, write `doc/dogfood-23lang-summary.md`
that diff-walks the per-language scores across binary × transport
× profile dimensions.

Expected zero diff between:
- Same profile, same lang, dev vs. binary (npm/vendor refresh
  proven by Run 6; releases ship matching code)
- Same profile, same lang, stdio vs. http (transport is
  cosmetic; same dispatch path under the hood)

Any per-language score divergence is a defect — investigate
before tag.

## Defect entry template

For every FAIL cell that survives Phase 4:

```
### D-M14-N <short title>

* **Cell**: <profile>/<binary>/<transport>/<lang>.<tool>
* **Symptom**: <verbatim error message>
* **Root cause**: <pharos-side, LSP-side, fixture-side, env>
* **Fix**: <patch landed | tracked | won't-fix-because>
* **Verification**: <re-run incantation>
```

## Acceptance criterion for v0.1.0 → v0.1.1 (M14 ship gate)

Two-gate policy mirroring M13:

* **Gate 1** — `bin/dogfood-23lang.py` green-or-tracked for both
  pharos-dev and binary, on stdio AND http, on `all` AND `default`
  profiles. (8 passes.)

* **Gate 2** — owner-driven live MCP-host dogfood. Run pharos under
  Claude Code or another MCP host against an unfamiliar codebase.
  Use only the default-profile tools. Confirm the LLM-self-service
  recipes work end-to-end (timeout escalation via
  `runtime_set_tool_timeout`, etc.).

Both gates must be green to tag.

## Out of scope for M14

- Cross-LSP semantic correctness (e.g., "does rust-analyzer's
  hover for Vec<T> correctly mention generic type parameters") —
  that's an LSP problem, not pharos's.
- Performance benchmarking (cold-start latency, P99 tool-call
  time). Captured anecdotally in pass logs; formal SLI
  measurement waits for a dedicated milestone.
- Stress testing (concurrent tool calls, mailbox backpressure).
  M11 / M12 covered the architecture; not re-litigated here.
- New language additions. The 23 currently bundled is the M14
  scope. Adding a 24th lang triggers an M14b mini-cycle.

## Tracked defects

### D-M14-001 PLS hangs on `goto_type_definition`

* **Cell**: all profiles/all binaries/all transports/perl.goto_type_definition (and the per-target tools serialized behind it: `goto_implementation`, `find_references`, then the short-circuited tail)
* **Symptom**: tool times out at 285s wall-clock (override × harness slack). Pharos's probe budget is satisfied — PLS answered hover/document_symbols/workspace_symbols/get_diagnostics/goto_definition in the same lang section. Specifically `textDocument/typeDefinition` never responds.
* **Root cause**: PLS does not implement `textDocument/typeDefinition` for Perl (no static type system), but instead of returning `-32601 Method not found`, it hangs the request indefinitely. LSP-side bug in `FractalBoy/perl-language-server`.
* **Fix**: won't-fix-pharos. Upstream tracking only. Pharos's `apply_workspace_edit` plus the 5 working PLS tools stay green; the cascading short-circuit is a harness artifact (3 strikes for unrelated `goto_*` calls), not a pharos defect.
* **Verification**: re-run `bin/dogfood-23lang.py perl --label "D-M14-001 check"`. Expect first 5 tools PASS, then 3 consecutive 285s wall-clock failures, then short-circuit. Pattern stable across passes.

## Phase results (rolling)

_Phase 1 with ADR-024 readiness gate landed: 351/524 cells PASS (67%).
18/23 languages working (vs 7/23 pre-ADR-024). 5 short-circuits:
scala (metals crash mid-probe), java/erlang/gleam (per-server
`ready_timeout_ms` bumped post-Pass-1), perl (D-M14-001). Update after
each subsequent phase lands._
