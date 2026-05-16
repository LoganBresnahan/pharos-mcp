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

## Symbol-layer support (ADR-026, pass 21)

Four tools: `find_symbol`, `get_symbols_overview`,
`find_referencing_symbols`, `edit_at_symbol`. `find_symbol` falls back
to single-file drill against `scope_uri` when the LSP does not
advertise `workspaceSymbolProvider`.

| Lang | find_sym | overview | refs | edit | notes |
|------|----------|----------|------|------|-------|
| bash       | F | F | F | F | bash-language-server returns legacy `SymbolInformation[]`; decoder rejects shape (real bug) |
| clojure    | ✓ | ✓ | ✓ | ✓ | |
| cpp        | F | ✓ | F | F | workspace/symbol returns `/usr/include/...`; drill fails to open URI outside fixture workspace (real bug) |
| css        | ✓-NF | ✓ | F | F | find_symbol returns `not_found`; fixture `symbol_name_path` "root" doesn't match doc-symbol naming |
| elixir     | F | ✓ | F | F | next-ls returned `-32603 Timeout` on workspace/symbol |
| erlang     | ✓-NF | ✓ | F | F | ELP names functions `main/1` (arity-suffixed); fixture path "main" doesn't match exact |
| gleam      | ✓ | ✓ | ✓ | ✓ | **fallback active** — gleam-lsp doesn't advertise `workspaceSymbolProvider` |
| go         | F | ✓ | F | F | LSP spawn flaked: "initialize handshake failed: client transport failure" (separate issue) |
| haskell    | ✓ | ✓ | ✓ | ✓ | |
| html       | F | F | F | F | vscode-html-language-server documentSymbol shape — decode error like bash |
| java       | ✓-NF | ✓ | F | F | jdtls names classes with kind suffix; fixture "KafkaClient" doesn't exact-match |
| json       | ✓ | ✓ | G | ✓ | refs GAP: vscode-json doesn't advertise `referencesProvider` |
| lua        | F | ✓ | F | F | LSP spawn flaked |
| markdown   | ✓-NF | ✓ | F | F | fixture path doesn't match marksman doc-symbol naming |
| perl       | F | F | F | F | perlnavigator legacy shape (like bash) |
| python     | ✓ | ✓ | ✓ | ✓ | |
| ruby       | F | ✓ | F | F | LSP spawn flaked |
| rust       | ✓ | ✓ | ✓ | ✓ | |
| scala      | F | ✓ | F | F | metals workspace/symbol timed out |
| terraform  | ✓-NF | ✓ | F | F | terraform-ls names blocks with type prefix |
| typescript | ✓ | ✓ | ✓ | ✓ | |
| yaml       | ✓ | ✓ | G | ✓ | refs GAP: yaml-language-server doesn't advertise `referencesProvider` |
| zig        | ✓ | ✓ | ✓ | ✓ | |

Legend: `✓` = OK. `✓-NF` = OK but returned `not_found` (handle empty, downstream tools skip).
`F` = FAIL. `G` = GAP (-32601, advertised). `—` = not measured.

**9/23 langs fully green.** Three layer bugs surfaced for follow-up:
1. Cross-workspace URI drill (cpp) — find_symbol should swallow
   per-URI session failures and continue with the other URIs.
2. Legacy `SymbolInformation[]` shape (bash, html, perl) — decoder
   needs to try both modern and legacy shapes.
3. Exact-name match in drill (erlang/java/elixir/markdown/terraform)
   — strip arity/kind decorators when comparing. Alternative: tune
   per-lang `symbol_name_path` fixtures.

LSP-side flakes (go/lua/ruby spawn handshake) are not symbol-layer
issues but worth tracking separately.

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
| pass 21  | 2026-05-15 | 487/616 (79.0%) | Full 23-lang grid w/ 4 symbol cells per lang (+92 cells over pass 19). 9 langs symbol-layer green; surfaced 3 layer bugs (cross-workspace URI, legacy SymbolInformation, exact-name drill) and 3 LSP spawn flakes. |
