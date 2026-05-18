# Dogfood Pass 26 — full regression across 4 surfaces

Date: 2026-05-17

First post-`memory_audit` regression run. Validates that the ADR-027
`memory_audit` tool (17-cell probe extended from pass 25's 11) ships
clean on both `pharos-dev` and the Burrito-built release binary, and
that stdio↔http transport parity holds end-to-end.

## Result matrix

| build       | transport | cells | PASS | rate   | memory probe |
|-------------|-----------|-------|------|--------|--------------|
| pharos-dev  | stdio     | 633   | 536  | 84.7 % | 17/17        |
| pharos-dev  | http      | 633   | 536  | 84.7 % | 17/17        |
| **binary**  | stdio     | 633   | 536  | 84.7 % | 17/17        |
| **binary**  | http      | 633   | 536  | 84.7 % | 17/17        |

**Perfect 4-way parity.** Identical `536/633` across every
combination, identical lang-level failures, identical tool failures.
Burrito release (under `-noshell -mode embedded -noinput`) behaves
exactly like `bin/pharos-dev`. Memory probe is 17/17 on every build
× transport pairing.

## Pass-over-pass

| pass | denom | PASS | rate   | delta |
|------|-------|------|--------|-------|
| 25b  | 627   | 530  | 84.5 % | —     |
| 26   | 633   | 536  | 84.7 % | +6 cells (memory_audit) |

Denominator grew by 6 (the new `memory_audit` cells 8a–f); every new
cell passed. No pharos plumbing regressions vs pass 25b.

## Memory probe (17 cells)

Run once per pass against scratch dirs set via `PHAROS_MEMORY_ROOT`
and `PHAROS_USER_MEMORY_ROOT`. Sequence:

1. `memory_list` (empty layers)
2. `memory_save` project
3. `memory_get`
4. `memory_list` filtered
5. `memory_save` dup → `Conflict`
6. `memory_save` overwrite
7. `memory_save` user-layer
8. `memory_list` cross-layer
8a. `memory_audit` defaults → clean (0 stale, 0 dup)
8b. `memory_save` near-dup-seed
8c. `memory_audit` defaults → 1 dup detected
8d. `memory_audit` `include_duplicates=false` → 0 dup
8e. `memory_audit` `stale_threshold_days=0` → ≥1 stale (every entry)
8f. `memory_prune` dup-seed
9. `memory_prune` project
10. `memory_get` → `NotFound`
11. `memory_prune` user-layer

All 17/17 PASS on every pass × transport. Shape, similarity scoring,
threshold plumbing, and deterministic ordering all verified
end-to-end (call body parsed via `call_with_payload`).

## Failures (19 cells, identical across all 4 passes — all pre-existing)

| language | tool                          | failure         |
|----------|-------------------------------|-----------------|
| go       | call_hierarchy_prepare        | gopls `flagConfig is not a function` |
| elixir   | workspace_symbols             | next-ls timeout |
| elixir   | goto_definition               | next-ls timeout (Enumerable protocol err) |
| elixir   | find_references               | next-ls timeout |
| elixir   | format_document               | next-ls timeout |
| elixir   | find_symbol                   | next-ls timeout |
| ruby     | goto_type_definition          | solargraph timeout |
| ruby     | goto_implementation           | solargraph timeout |
| scala    | workspace_symbols             | metals timeout  |
| scala    | get_diagnostics               | metals timeout  |
| scala    | inlay_hints                   | metals timeout  |
| scala    | semantic_tokens               | metals timeout  |
| scala    | find_symbol                   | metals timeout  |
| terraform| goto_definition               | -32098 no reference origin (legit) |
| java     | goto_type_definition          | jdtls timeout   |
| gleam    | workspace_symbols             | gleam-lsp timeout on big ws |
| gleam    | get_diagnostics               | gleam-lsp timeout |
| gleam    | goto_implementation           | gleam-lsp timeout |
| global   | runtime_trace_calls           | opt-in (disabled by default) — expected |

Only difference between stdio and http rows is timeout wording
(`no response within Xs` vs `protocol error -32001: transport:
TimeoutError`). Same root cause, two transports.

## Headline takeaways

1. **Pharos plumbing is green at every surface.** Burrito release
   matches dev-mode behaviour cell-for-cell. No module-loading
   gaps, no extract-cache staleness, no `-32601` method-not-found
   discrepancies.

2. **Transport parity holds.** stdio and http differ only in error
   message text on timeouts. Aggregate, per-lang, per-tool
   identical.

3. **`memory_audit` is production-ready.** 17/17 across 4 surfaces;
   shape, similarity scoring, threshold plumbing, deterministic
   ordering all verified.

4. **All 19 failures are LSP-side, not pharos defects.** Next-ls,
   metals, jdtls, solargraph indexing timeouts on large workspaces;
   one gopls bug; one disabled-by-default opt-in (trace_calls).

## Artifacts

- `/tmp/pass26-stdio.md` / `/tmp/pass26-stdio.log` (pharos-dev stdio)
- `/tmp/pass26-http.md`  / `/tmp/pass26-http.log`  (pharos-dev http)
- `/tmp/pass26-bin-stdio.md` / `/tmp/pass26-bin-stdio.log` (binary stdio)
- `/tmp/pass26-bin-http.md`  / `/tmp/pass26-bin-http.log`  (binary http)

## Reproduce

```bash
# pharos-dev stdio
python3 bin/dogfood-23lang.py --label pass-26-stdio --out /tmp/pass26-stdio.md

# pharos-dev http
python3 bin/dogfood-23lang.py --transport http --label pass-26-http --out /tmp/pass26-http.md

# burrito build
rm -rf ~/.local/share/.burrito/pharos_erts-*
MIX_ENV=prod mix release --overwrite
mkdir -p npm/vendor
for f in burrito_out/pharos_*; do cp "$f" "npm/vendor/$(basename $f)"; done
node npm/scripts/postinstall.js

# binary stdio
PHAROS_TEST_BIN="$PWD/burrito_out/pharos_linux_x64" \
  python3 bin/dogfood-23lang.py --label pass-26-bin-stdio --out /tmp/pass26-bin-stdio.md

# binary http
PHAROS_TEST_BIN="$PWD/burrito_out/pharos_linux_x64" \
  python3 bin/dogfood-23lang.py --transport http --label pass-26-bin-http --out /tmp/pass26-bin-http.md

# memory-only fast loop
python3 bin/dogfood-23lang.py --memory-only --out /tmp/pharos-memory.md
```
