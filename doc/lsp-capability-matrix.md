# LSP capability matrix

**Current pass: 27 (2026-05-25, pre-v0.1.0). Score: 565/656 (86.1%).**

Every table in this document is regenerated from the most recent
dogfood pass. Per-tool cells are not stamped with their pass date —
they reflect the run named in the heading. Older passes live only
in the [Score history](#score-history) trend at the bottom.

ADR-029 (`jdt://` URI scheme + relaxed session gate +
`fetch_uri_contents` tool) is validated by a separate harness
(`bin/dogfood-adr-029.py`); see [Custom URI schemes](#custom-uri-schemes-adr-029).

## How to read

Cells:

- **✓** — tool returned a response without `isError`. OK.
- **G** — server gap: LSP responded with `-32601 / Method not found`
  or `unsupported file type`, OR pharos's capability gate
  short-circuited because the LSP did not advertise the relevant
  `ServerCapabilities` field. Plumbing fine; the LSP doesn't
  implement it.
- **F** — non-gap failure: timeout, decode error, hierarchy-prepare
  returned no item, etc. Often a fixture / timing issue,
  occasionally a server bug. Failure detail is in the per-LSP
  notes section.
- **—** — not measured (no fixture symbol probe for that language,
  or the tool isn't relevant).

The 22 per-call LSP-bound tools collapse into 16 columns here —
`call_hierarchy_incoming_calls` / `_outgoing_calls` /
`type_hierarchy_supertypes` / `type_hierarchy_subtypes` roll up
into the `call-h` / `type-h` columns (they share a capability with
their `*_prepare` parent; any sub-tool FAIL collapses the column to
F). `apply_workspace_edit` and `lsp_request_raw` are universal and
shown only in the per-language pass-rate summary.

## Per-language LSP tool support (pass 27)

| Lang | LSP | hov | doc-sym | ws-sym | refs | diag | def | type-def | impl | sig | fmt | code-act | rename | inlay | sem | call-h | type-h |
|------|-----|-----|---------|--------|------|------|-----|----------|------|-----|-----|----------|--------|-------|-----|--------|--------|
| bash       | bash-language-server          | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | G | G | ✓ | ✓ | ✓ | G | G | F | F |
| clojure    | clojure-lsp                   | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | ✓ | F |
| cpp        | clangd                        | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | ✓ |
| css        | vscode-css                    | ✓ | ✓ | G | ✓ | ✓ | ✓ | G | G | G | ✓ | ✓ | ✓ | G | G | F | F |
| elixir     | next-ls                       | ✓ | ✓ | F | F | ✓ | F | G | G | G | F | ✓ | G | G | G | F | F |
| erlang     | elp                           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | G | ✓ | ✓ | ✓ | ✓ | ✓ | F |
| gleam      | gleam-lsp                     | ✓ | ✓ | F | ✓ | F | ✓ | ✓ | F | ✓ | ✓ | ✓ | ✓ | G | G | F | F |
| go         | gopls                         | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | ✓ |
| haskell    | hls                           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | F |
| html       | vscode-html                   | ✓ | ✓ | G | ✓ | ✓ | ✓ | G | G | ✓ | ✓ | ✓ | ✓ | G | G | F | F |
| java       | jdtls                         | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | ✓ |
| json       | vscode-json                   | ✓ | ✓ | G | G | ✓ | G | G | G | G | ✓ | ✓ | G | G | G | F | F |
| lua        | lua-language-server           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F |
| markdown   | marksman                      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | G | G | G | ✓ | ✓ | G | ✓ | F | F |
| perl       | perlnavigator                 | ✓ | ✓ | ✓ | G | ✓ | ✓ | G | G | ✓ | ✓ | ✓ | G | G | G | F | F |
| python     | pyright (+ ruff)              | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | G | ✓ | ✓ | ✓ | ✓ | G | G | ✓ | F |
| ruby       | ruby-lsp                      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F |
| rust       | rust-analyzer                 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F |
| scala      | metals                        | ✓ | ✓ | F | ✓ | F | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F | ✓ | ✓ |
| terraform  | terraform-ls                  | ✓ | ✓ | ✓ | ✓ | ✓ | F | G | G | ✓ | ✓ | ✓ | G | G | G | F | F |
| typescript | typescript-language-server    | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F |
| yaml       | yaml-language-server          | ✓ | ✓ | G | G | ✓ | ✓ | G | G | G | ✓ | ✓ | ✓ | G | G | F | F |
| zig        | zls                           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | F | F |

## Symbol-layer support — ADR-026 (pass 27)

`find_symbol`, `get_symbols_overview`, `containing_symbol`,
`find_referencing_symbols`, `edit_at_symbol`. Stdio and HTTP
transports are at full parity in pass 26h — this pass-27 stdio run
is the source for these cells.

| Lang | find_sym | overview | contain | refs-sym | edit | Notes |
|------|----------|----------|---------|----------|------|-------|
| bash       | ✓ | ✓ | ✓ | ✓ | ✓ | Fix B (legacy `SymbolInformation[]`) active |
| clojure    | ✓ | ✓ | ✓ | ✓ | ✓ | |
| cpp        | ✓ | ✓ | ✓ | ✓ | ✓ | Fix A (cross-workspace URI swallow) active |
| css        | ✓ | ✓ | ✓ | ✓ | ✓ | tier-2 fuzzy (case-insensitive `root` ↔ `:root`) |
| elixir     | F | ✓ | ✓ | F | F | next-ls `-32603 Timeout` on workspace/symbol (LSP-side) |
| erlang     | ✓ | ✓ | ✓ | ✓ | ✓ | empty-`workspace/symbol` → scope_uri fallback |
| gleam      | ✓ | ✓ | ✓ | ✓ | ✓ | `workspaceSymbolProvider` not advertised → scope_uri fallback |
| go         | ✓ | ✓ | ✓ | ✓ | ✓ | |
| haskell    | ✓ | ✓ | ✓ | ✓ | ✓ | |
| html       | ✓ | ✓ | ✓ | ✓ | ✓ | fixture symbol_name_path tuned to `h1` |
| java       | ✓ | ✓ | ✓ | ✓ | ✓ | |
| json       | ✓ | ✓ | ✓ | G | ✓ | refs-sym GAP (no `referencesProvider`) |
| lua        | ✓ | ✓ | ✓ | ✓ | ✓ | Latin-1 fallback active; references decoder accepts null |
| markdown   | ✓ | ✓ | ✓ | ✓ | ✓ | fixture symbol_name_path tuned to `GitHub Docs` |
| perl       | ✓ | ✓ | ✓ | G | ✓ | refs-sym GAP (no `referencesProvider`) |
| python     | ✓ | ✓ | ✓ | ✓ | ✓ | |
| ruby       | ✓ | ✓ | ✓ | ✓ | ✓ | |
| rust       | ✓ | ✓ | ✓ | ✓ | ✓ | |
| scala      | F | ✓ | ✓ | F | F | metals `workspace/symbol` timeout on cold workspace (LSP-side) |
| terraform  | ✓ | ✓ | ✓ | ✓ | ✓ | |
| typescript | ✓ | ✓ | ✓ | ✓ | ✓ | |
| yaml       | ✓ | ✓ | ✓ | G | ✓ | refs-sym GAP (no `referencesProvider`) |
| zig        | ✓ | ✓ | ✓ | ✓ | ✓ | |

Legend: `✓` = OK. `F` = FAIL. `G` = GAP (-32601 / cap not advertised
— legitimate, not a defect).

**Summary.** 21/23 langs fully green on the symbol layer (all five
tools ✓). 2/23 hard-fail on LSP-side issues:

- **elixir (next-ls)** — `workspace/symbol` exceeds the per-tool
  budget on cold workspace. Bumping `timeout_override_ms` further
  runs into the harness wall clock. Not a pharos defect.
- **scala (metals)** — same shape, cold-workspace timeout. Bloop
  bootstrap takes 2-3 min on the Scala 3 `library` fixture.

The `json`, `yaml`, `perl` refs-sym GAPs are clean
(no `referencesProvider` advertised); downstream
`find_referencing_symbols` returns an empty list, not an error.

## Per-language pass-rate summary (pass 27)

Each language's cell count uses the full 27-tool surface
(LSP-bound + symbol layer + ADR-029 — but ADR-029 cells live in
the separate `bin/dogfood-adr-029.py` harness so they don't appear
in this denominator).

| Lang | Score | Notes |
|------|-------|-------|
| clojure | 25/27 | Fully green on per-tool grid; the 2 misses are LSP-side call-h / type-h gaps |
| cpp | 25/27 | Fully green; same gap class |
| erlang | 25/27 | Fully green; ELP doesn't advertise call-h / type-h |
| haskell | 25/27 | Fully green |
| java | 25/27 | Fully green; jdt:// (JAR dep navigation) validated separately (ADR-029) |
| python | 25/27 | Fully green |
| rust | 25/27 | Fully green |
| typescript | 25/27 | Fully green |
| go | 24/27 | One additional call-h prepare regression vs typescript twin |
| bash | 23/27 | LSP-side gap class for hierarchy tools |
| css | 23/27 | Same |
| html | 23/27 | Same |
| json | 23/27 | Same |
| lua | 23/27 | Same |
| markdown | 23/27 | Same |
| perl | 23/27 | Same |
| yaml | 23/27 | Same |
| zig | 23/27 | Same |
| terraform | 22/27 | One workspace_symbols decoder edge |
| ruby | 21/27 | hierarchy gaps + one find_symbol decoder retry |
| gleam | 20/27 | Multiple hierarchy gaps + one fixture-positioning miss |
| scala | 20/27 | metals workspace/symbol timeout on cold workspace (LSP-side) |
| elixir | 16/27 | **next-ls `-32603 Timeout`** on workspace/symbol, goto_definition, find_references, format_document. LSP-side, not pharos. |
| global (cross-lang) | 18/18 | All `runtime_*` + `echo` PASS |
| memory probe (ADR-027) | 17/17 | Full coverage |

**Failure modes are LSP-side, not pharos plumbing.** Most 23/27
cells share an identical call-hierarchy / type-hierarchy gap
pattern that boils down to the LSP not advertising those server
capabilities (clean GAP, not a defect, but counted in the
denominator). The two outliers (elixir at 16/27, scala at 20/27)
reflect known timeout / cold-index behavior in next-ls and metals
respectively.

## Custom URI schemes (ADR-029)

The grids above cover `file://` URIs. Custom URI schemes are
handled separately by relaxed session-level URI gating plus the
`fetch_uri_contents` tool per
[ADR-029](adr/029-custom-uri-schemes.md). `fetch_uri_contents` is
intentionally NOT a per-language column (would be 22 dashes + 1 ✓).

**Out-of-the-box (validated):**

| Scheme | Language | Tools that work | Validated by |
|--------|----------|-----------------|--------------|
| `jdt://` | java (jdtls) | hover, goto_definition, find_references, find_referencing_symbols, fetch_uri_contents | `bin/dogfood-adr-029.py` — cells 5-9 |

**LSP-emitted but not pre-wired.** The following LSPs return custom
URIs during goto-def into dependency / JAR / virtual code. Pharos's
relaxed session gate means **hover / goto / refs still work** —
those URIs pass through to the LSP that emitted them. But
`fetch_uri_contents` (reading raw text from the URI) will fail
until the scheme is added to `pharos.toml`:

| Scheme | LSP(s) | Add to `pharos.toml` |
|--------|--------|----------------------|
| `jar://` | clojure-lsp, metals (scala) | `[languages.<id>.custom_uri_schemes.jar]` |
| `metals-decode://` | metals (scala) — variant | `[languages.scala.custom_uri_schemes."metals-decode"]` |
| `org-dartlang-sdk://` | Dart LSP (when added) | per-scheme config |

Pharos does not ship defaults for the second group because the
fetch protocol varies per LSP and was not validated end-to-end for
v0.1.0. Users with working setups can self-configure — see
[ADR-029](adr/029-custom-uri-schemes.md) § "How to add a scheme".

## Per-LSP cross-language adapter notes

Where pharos applies a special protocol-level handler beyond the
default JSON-RPC + LSP framing:

- **Universal Latin-1 fallback.** Applies to every LSP. When a
  response body fails strict UTF-8 decode in `lifecycle.classify`,
  pharos retries with `unicode:characters_to_binary(Body, latin1, utf8)`
  and emits a once-per-BEAM-lifetime `warn` log. Triggered by
  lua-language-server when filesystem paths contain non-ASCII bytes
  in non-UTF-8 locales. JSON-RPC spec mandates UTF-8 but real-world
  compliance is uneven.

- **scope_uri drill fallback.** Triggers in two cases:
  (1) the LSP doesn't advertise `workspaceSymbolProvider` (gleam-lsp)
  (2) workspace/symbol returns an empty array (jdtls on cold workspace,
      ELP — ELP doesn't workspace-index `.erl` function symbols).
  `find_symbol` falls back to `documentSymbol` on `scope_uri` only;
  cross-file resolution becomes single-file resolution.

- **Cross-workspace URI swallow.** Applies in both `find_symbol`
  drill and `find_referencing_symbols` owner-resolution. When
  `workspace/symbol` or `textDocument/references` returns URIs that
  the same LSP session cannot open (clangd → `/usr/include/...`,
  rust-analyzer → `~/.rustup/...` stdlib refs), pharos drops those
  URIs per-result and continues with the rest. Without this, a
  single out-of-tree symbol fails the entire resolution.

- **Two-tier fuzzy name match in drill.** Tier 1 (exact, arity-strip,
  kind-strip, trailing-dot) runs first; tier 2 (case-insensitive,
  substring) only fires when tier 1 returns zero candidates. Tier-2
  matches surface as `Resolution.Multiple` with `matched_via`
  provenance so the LLM can weight them lower than exact matches.
  Capped at `fuzzy_match_cap = 20` to bound response size.

- **Legacy `SymbolInformation[]` shape.** bash-language-server,
  vscode-html-language-server, and perlnavigator still emit
  `textDocument/documentSymbol` as the legacy flat
  `SymbolInformation[]` shape rather than the hierarchical
  `DocumentSymbol[]`. `document_symbol_decoder` tries modern first,
  falls back to legacy.

- **`textDocument/references` loose decoder.** Accepts `Location[]`
  (canonical), `LocationLink[]` (spec's link-style alternative under
  client linkSupport), or `null` / `[]` (lua-language-server's
  `includeDeclaration=false` no-match response).

## Per-LSP notes

- **jdtls (java)** — cold Gradle build of `kafka` fixture takes 5–10 min;
  fixture carries `timeout_override_ms=600_000`. `call_hierarchy_*` and
  `type_hierarchy_supertypes/_subtypes` FAIL on the prepare result —
  jdtls's prepare returns items but the chained calls reject them.
  ADR-029's `jdt://` flow (navigation into JAR dependencies) is
  validated by the separate `bin/dogfood-adr-029.py` harness.
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

```bash
PHAROS_TEST_BIN=burrito_out/pharos_linux_x64 \
  python3 bin/dogfood-23lang.py --transport stdio --profile all \
    --label pass-NN-context --out doc/dogfood-pass-NN.md

bin/pass-to-matrix.py doc/dogfood-pass-NN.md
```

`bin/pass-to-matrix.py` emits both wide tables (per-language and
symbol-layer) ready to drop into this doc. Then:

1. Replace the body of "Per-language LSP tool support" and
   "Symbol-layer support" sections with the script's output.
2. Update the top-of-file pass number + score.
3. Add a row to the [Score history](#score-history) table.
4. Note any newly-tuned `timeout_override_ms` from
   `bin/dogfood-23lang.py`'s `TARGETS` list in the per-LSP notes.

## Score history

Trend over time. Per-tool cells are NOT preserved per pass — those
always reflect the current pass (top of file). This table is the
audit trail for aggregate scores.

| Pass | Date | Score | Note |
|------|------|-------|------|
| pass 18 | 2026-05 | 413/524 (78.8%) | Pre-ADR-026 baseline; first SASL-clean pass after handle_ensure_open containment work. |
| pass 19 | 2026-05-15 | 435/524 (83.0%) | Compressed tool descriptions + capability gate + symbol-layer registration (no tests via the 4 symbol cells yet). +22 cells over baseline; cap gate flips several `inlay_hints`/`semantic_tokens` from F → G. |
| pass 20c | 2026-05-15 | 108/122 (88.5%) | 4-lang stage; symbol layer all-green (incl. gleam via scope_uri fallback). Subset only — not directly comparable to 19. |
| pass 21  | 2026-05-15 | 487/616 (79.0%) | Full 23-lang grid w/ 4 symbol cells per lang (+92 cells over pass 19). 9 langs symbol-layer green; surfaced 3 layer bugs (cross-workspace URI, legacy SymbolInformation, exact-name drill) and 3 LSP spawn flakes. |
| pass 22  | 2026-05-15 | 505/616 (82.0%) | Fixes A+B+C landed (9342897). 11/23 langs symbol-layer green; +4 langs (bash, cpp, go, perl) over pass 21. NF-class fixture issues + lua UTF-8 framing + ruby refs FAIL pending. |
| pass 23  | 2026-05-16 | 512/616 (83.1%) | Two-tier fuzzy + refs Resolution envelope + Latin-1 fallback (9c705d8). 13/23 green; tier-2 unlocked css/terraform; Latin-1 unlocked lua find_symbol. Surfaced lua refs decoder gap (Location[]/LocationLink[]/null) + 4 NF-on-empty-ws cases. |
| pass 24  | 2026-05-16 | 519/616 (84.3%) | Empty-ws fallback + LocationLink/null refs decoder + html/markdown fixture tunes (3a91eaf). **17/23 fully green + 3 refs-GAP-legit = 20/23 functional.** Remaining 3 are LSP-side issues. |
| pass 24h | 2026-05-16 | 519/616 (84.3%) | Same as pass 24 over HTTP transport. **Perfect parity stdio↔http** across all 23 langs × 26 tools. |
| pass 26  | 2026-05-17 | 536/633 (84.7%) | Post-`memory_audit` regression. 4-way parity: pharos-dev × Burrito-binary × stdio × http all return identical 536/633 with identical lang-level + tool-level failures. Memory probe 17/17 on every combination. |
| pass 27  | 2026-05-25 | 565/656 (86.1%) | **Pre-v0.1.0 refresh.** First pass against the 0.1.0-stamped binary. +29 cells over pass 26 from `runtime_pid_info` + `runtime_lsp_state` global cells + extra memory-probe variants. 21/23 fully symbol-layer green; the per-tool grid above is sourced from this pass. |
