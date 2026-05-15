# LSP capability matrix

Per-language LSP support, derived from dogfood passes.

Last refresh: 2026-05-15 (pass 19 stdio/all + pass 20c stdio/all symbol cells).

## How to read

Cells:

- **✓** — tool returned a response without `isError` (OK).
- **G** — server gap: LSP responded with `-32601 / Method not found` or
  `unsupported file type`, OR pharos's capability gate short-circuited
  because the LSP did not advertise the relevant `ServerCapabilities`
  field. Plumbing fine; the LSP doesn't implement it.
- **F** — non-gap failure: timeout, decode error, hierarchy-prepare
  returned no item, etc. Often a fixture/timing issue, sometimes a
  server bug.
- **—** — not measured (no fixture symbol probe for that lang yet, or
  the tool isn't relevant).

The 22 per-call LSP-bound tools collapse here into 14 columns —
`call_hierarchy_incoming_calls` / `_outgoing_calls` / `type_hierarchy_*`
roll up into the `call-h` / `type-h` columns (they share a capability
with their `*_prepare` parent). `apply_workspace_edit` and
`lsp_request_raw` are universal — not shown.

## Per-language tool support (pass 19 baseline)

| Lang | LSP | hov | doc-sym | ws-sym | refs | diag | def | type-def | impl | sig | fmt | code-act | rename | inlay | sem | call-h | type-h |
|------|-----|-----|---------|--------|------|------|-----|----------|------|-----|-----|----------|--------|-------|-----|--------|--------|
| bash       | bash-language-server          | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | G | G | ✓ | ✓ | ✓ | G | G | G | G |
| clojure    | clojure-lsp                   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | ✓ | G |
| cpp        | clangd                        | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | ✓ |
| css        | vscode-css                    | ✓ | ✓ | G | ✓ | ✓ | ✓ | G | G | G | ✓ | ✓ | ✓ | G | G | G | G |
| elixir     | next-ls                       | ✓ | ✓ | F | F | ✓ | F | G | G | G | F | ✓ | G | G | G | G | G |
| erlang     | elp                           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | G | ✓ | ✓ | ✓ | ✓ | ✓ | G |
| gleam      | gleam-lsp                     | ✓ | ✓ | F | ✓ | F | ✓ | ✓ | F | ✓ | ✓ | ✓ | ✓ | G | G | G | G |
| go         | gopls                         | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | ✓ |
| haskell    | hls                           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | G |
| html       | vscode-html                   | ✓ | ✓ | G | ✓ | ✓ | ✓ | G | G | ✓ | ✓ | ✓ | ✓ | G | G | G | G |
| java       | jdtls                         | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F |
| json       | vscode-json                   | ✓ | ✓ | G | G | ✓ | G | G | G | G | ✓ | ✓ | G | G | G | G | G |
| lua        | lua-language-server           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | G |
| markdown   | marksman                      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | G | G | G | ✓ | ✓ | G | ✓ | G | G |
| perl       | perlnavigator                 | ✓ | ✓ | ✓ | G | ✓ | ✓ | G | G | ✓ | ✓ | ✓ | G | G | G | G | G |
| python     | pyright (+ ruff)              | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | ✓ | ✓ | ✓ | G | G | ✓ | G |
| ruby       | ruby-lsp                      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ |
| rust       | rust-analyzer                 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G |
| scala      | metals                        | ✓ | ✓ | F | ✓ | F | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F | ✓ | ✓ |
| terraform  | terraform-ls                  | ✓ | ✓ | ✓ | ✓ | ✓ | F | G | G | ✓ | ✓ | ✓ | G | G | G | G | G |
| typescript | typescript-language-server    | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G |
| yaml       | yaml-language-server          | ✓ | ✓ | G | G | ✓ | ✓ | G | G | G | ✓ | ✓ | ✓ | G | G | G | G |
| zig        | zls                           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | G |

## Symbol-layer support (ADR-026, pass 20c)

Four tools: `find_symbol`, `get_symbols_overview`,
`find_referencing_symbols`, `edit_at_symbol`. `find_symbol` falls back
to single-file drill against `scope_uri` when the LSP does not
advertise `workspaceSymbolProvider`.

| Lang | find_symbol | overview | refs | edit | fallback active? |
|------|-------------|----------|------|------|------------------|
| python | ✓ | ✓ | ✓ | ✓ | no |
| rust | ✓ | ✓ | ✓ | ✓ | no |
| typescript | ✓ | ✓ | ✓ | ✓ | no |
| gleam | ✓ | ✓ | ✓ | ✓ | **yes** — gleam-lsp does not advertise `workspaceSymbolProvider` |
| (others) | — | — | — | — | — (fixture probes not added yet) |

## Per-LSP notes

- **jdtls (java)** — cold Gradle build of `kafka` fixture takes 5–10 min;
  fixture carries `timeout_override_ms=600_000`.  `goto_type_definition`
  reliably FAILs on the dogfood target (no type at the symbol's
  position, jdtls error rather than -32601). `call_hierarchy_*` and
  `type_hierarchy_supertypes/_subtypes` FAIL on the prepare result —
  jdtls's prepare returns items but the chained calls reject them.
- **gleam-lsp** — `workspace/symbol` and `textDocument/diagnostic`
  serialise the entire build (single-threaded), so on big fixtures both
  consistently timeout at 645s. Does not advertise
  `workspaceSymbolProvider` → symbol layer routes through the fallback.
- **hls (haskell)** — `Cabal/src/Distribution/Simple.hs` fixture
  triggers ~3 min cold build; `timeout_override_ms=180_000`.
- **metals (scala)** — strict identifier validator (rename_preview must
  match Scala identifier rules); 5 min cold build on the Scala 3
  `library` fixture → `timeout_override_ms=300_000`. `workspace_symbols`
  + `get_diagnostics` + `inlay_hints` + `semantic_tokens` regularly
  timeout out on cold workspace.
- **perlnavigator (perl)** — replaced PLS in pass 20+ era. Stable; no
  per-call tuning beyond the 240s override carried from PLS era.
- **gopls (go)** — `call_hierarchy_prepare` returns an item but the
  chained `_incoming` / `_outgoing` reject it for the dogfood target;
  unclear if a real bug or test position. `type_hierarchy_*` works.
- **clangd (cpp)** — `call_hierarchy_*` chain fails like gopls; treat
  as a known limitation on the protobuf fixture position.
- **next-ls (elixir)** — most aggressive non-cap failure list across
  the 23: `workspace_symbols`, `find_references`, `goto_definition`,
  `format_document`, `signature_help` all F. Considered swapping for
  `elixir-ls` if dogfood signal stays bad; deferred.
- **ruby-lsp** — `goto_type_definition` and `goto_implementation`
  FAIL on the `Base` symbol; may be a sinatra fixture issue not an
  LSP issue.
- **vscode-{html,css,json}** + **yaml-language-server** — uniform
  small surface (hover + doc_symbols + format only). Multiple G cells
  expected.
- **rust-analyzer** — most-complete surface in the matrix; one of three
  servers (also typescript-language-server, clangd) where
  `call_hierarchy_*` reliably round-trip.

## How to refresh this matrix

After a `bin/dogfood-23lang.py` run:

1. Parse each `## <lang> (N/M)` section's table into per-lang
   `{tool → OK | GAP | FAIL}` dicts.
2. Diff against the rows here; update any flipped cells.
3. Note any newly-tuned `timeout_override_ms` from
   `bin/dogfood-23lang.py`'s `TARGETS` list in the per-LSP notes.
4. Re-run the symbol-cell rollout when new languages get
   `symbol_name_path` fixtures.

## Score history

| Pass | Date | Score | Note |
|------|------|-------|------|
| pass 18 | 2026-05 | 413/524 (78.8%) | Pre-ADR-026 baseline; first SASL-clean pass after handle_ensure_open containment work. |
| pass 19 | 2026-05-15 | 435/524 (83.0%) | Compressed tool descriptions + capability gate + symbol-layer registration (no tests via the 4 symbol cells yet). +22 cells over baseline; cap gate flips several `inlay_hints`/`semantic_tokens` from F → G. |
| pass 20c | 2026-05-15 | 108/122 (88.5%) | 4-lang stage; symbol layer all-green (incl. gleam via scope_uri fallback). Subset only — not directly comparable to 19. |
