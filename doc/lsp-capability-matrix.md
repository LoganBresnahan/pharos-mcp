# LSP capability matrix

Per-language LSP support, derived from dogfood passes.

Last refresh: 2026-05-25 (pass 27 stdio/all, pre-v0.1.0 — see
[Pass 27 results](#pass-27-results-2026-05-25-pre-v010) below).
Per-tool cells from passes 19/24 are kept as historical detail
because per-tool behaviour is stable: pass 27's 23-language
aggregate (565/656, 86.1%) confirms the prior topology. ADR-029
(`jdt://` URI scheme + relaxed session gate + `fetch_uri_contents`
tool) landed 2026-05-20 and is validated separately — see
[Custom URI schemes](#custom-uri-schemes-adr-029) below.

## Pass 27 results (2026-05-25, pre-v0.1.0)

First full pass against the 0.1.0-stamped binary. Profile: `all`
(includes debug + raw categories). Transport: stdio. **565/656
cells PASS = 86.1%.** Per-language breakdown (each cell = one of
the 27 LSP-bound + symbol-layer tools):

| Lang | Score | Notes |
|------|-------|-------|
| clojure | 25/27 | Fully green; the 2 misses are LSP-side call-h/type-h gaps |
| cpp | 25/27 | Fully green; same gap class |
| erlang | 25/27 | Fully green; ELP doesn't advertise call-h |
| haskell | 25/27 | Fully green |
| java | 25/27 | Fully green; jdt:// validated separately (ADR-029) |
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

**Failure modes are LSP-side, not pharos plumbing.** Most "23/27"
cells share an identical call-hierarchy / type-hierarchy gap
pattern that boils down to the LSP not advertising those server
capabilities (clean GAP, not a defect). The two outliers (elixir,
scala) reflect known timeout / cold-index behaviour in next-ls
and metals respectively — also LSP-side. Pass 24's "17/23 fully
green + 3 functional-with-legit-gap + 3 LSP-side" topology
holds; pass 27 just brings the score history forward by 9 days
and confirms parity against the freshly-stamped 0.1.0 binary.



## Custom URI schemes (ADR-029)

The matrix below covers `file://` URIs. Custom URI schemes are
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

## Symbol-layer support (ADR-026, pass 24 — stdio + http)

After pass-23 fixes landed (two-tier fuzzy match, find_referencing_symbols
Resolution envelope + cross-workspace URI swallow, universal Latin-1
fallback in `lifecycle.classify`) and pass-24 follow-ups
(empty-`workspace/symbol` fallback to `scope_uri` drill,
`references_response_decoder` accepting Location / LocationLink / null,
fixture tunes for html + markdown).

**Stdio and HTTP transports are at full parity** — every lang's
symbol-cell result is identical across `--transport stdio` and
`--transport http`. HTTP plumbing (mist + JSON-RPC handler) does not
introduce drift.

| Lang | find_sym | overview | refs | edit | notes |
|------|----------|----------|------|------|-------|
| bash       | ✓ | ✓ | ✓ | ✓ | Fix B (legacy `SymbolInformation[]`) active |
| clojure    | ✓ | ✓ | ✓ | ✓ | |
| cpp        | ✓ | ✓ | ✓ | ✓ | Fix A (cross-workspace URI swallow) active |
| css        | ✓ | ✓ | ✓ | ✓ | tier-2 fuzzy (case-insensitive `root` ↔ `:root`) |
| elixir     | F | ✓ | F | F | next-ls `-32603 Timeout` on workspace/symbol (LSP-side) |
| erlang     | ✓ | ✓ | ✓ | ✓ | empty-`workspace/symbol` → scope_uri fallback |
| gleam      | ✓ | ✓ | ✓ | ✓ | `workspaceSymbolProvider` not advertised → scope_uri fallback |
| go         | ✓ | ✓ | ✓ | ✓ | |
| haskell    | ✓ | ✓ | ✓ | ✓ | |
| html       | ✓ | ✓ | ✓ | ✓ | fixture symbol_name_path tuned to `h1` |
| java       | ✓-NF | ✓ | F | F | jdtls cold-build returns empty workspace/symbol + scope_uri drill doesn't surface `KafkaClient` — LSP-side fixture issue |
| json       | ✓ | ✓ | G | ✓ | refs GAP (no `referencesProvider`) |
| lua        | ✓ | ✓ | ✓ | ✓ | Latin-1 fallback active; references decoder accepts null |
| markdown   | ✓ | ✓ | ✓ | ✓ | fixture symbol_name_path tuned to `GitHub Docs` |
| perl       | ✓ | ✓ | G | ✓ | refs GAP (no `referencesProvider`) |
| python     | ✓ | ✓ | ✓ | ✓ | |
| ruby       | ✓ | ✓ | ✓ | ✓ | |
| rust       | ✓ | ✓ | ✓ | ✓ | |
| scala      | F | ✓ | F | F | metals `workspace/symbol` timeout on cold workspace (LSP-side) |
| terraform  | ✓ | ✓ | ✓ | ✓ | |
| typescript | ✓ | ✓ | ✓ | ✓ | |
| yaml       | ✓ | ✓ | G | ✓ | refs GAP (no `referencesProvider`) |
| zig        | ✓ | ✓ | ✓ | ✓ | |

Legend: `✓` = OK. `✓-NF` = OK but `not_found` (downstream tools skip).
`F` = FAIL. `G` = GAP (-32601, cap not advertised — legit).

**17/23 langs fully green, 3/23 functional with legit refs-GAP, 3/23
hard-fail on LSP-side issues:**

- **elixir / scala**: workspace/symbol timeouts originate in the LSP
  (next-ls, metals on cold workspace). Both servers eventually
  respond on the second call but exceed the per-tool budget; bumping
  `timeout_override_ms` further runs into the harness wall clock.
  Not a Pharos defect.

- **java (jdtls)**: cold-build returns `[]` for workspace/symbol
  during the first ~60s of indexing, and `documentSymbol` on the
  fixture file lists method-level symbols without surfacing the
  containing `KafkaClient` interface as a top-level entry. Both the
  empty-workspace fallback and tier-2 fuzzy run cleanly; the symbol
  simply isn't in jdtls's documentSymbol output. Likely fixture
  positioning interacts poorly with jdtls's outline mode.

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

## Symbol-layer support (ADR-026, pass 22 — superseded)

After pass-21 fixes A (cross-workspace URI swallow), B (legacy
`SymbolInformation[]` decoder), C (fuzzy drill name match) committed
in 9342897.

| Lang | find_sym | overview | refs | edit | notes |
|------|----------|----------|------|------|-------|
| bash       | ✓ | ✓ | ✓ | ✓ | Fix B unlocked (was decode FAIL) |
| clojure    | ✓ | ✓ | ✓ | ✓ | |
| cpp        | ✓ | ✓ | ✓ | ✓ | Fix A unlocked (was cross-workspace FAIL) |
| css        | ✓-NF | ✓ | F | F | `root` not in doc-symbol tree |
| elixir     | F | ✓ | F | F | next-ls `-32603 Timeout` on workspace/symbol |
| erlang     | ✓-NF | ✓ | F | F | fuzzy drill didn't catch — `main` not surfacing in workspace_symbol result |
| gleam      | ✓ | ✓ | ✓ | ✓ | fallback active |
| go         | ✓ | ✓ | ✓ | ✓ | (spawn flake from pass 21 cleared) |
| haskell    | ✓ | ✓ | ✓ | ✓ | |
| html       | ✓-NF | ✓ | F | F | `html` not in vscode-html doc-symbol output |
| java       | ✓-NF | ✓ | F | F | jdtls doc-symbol naming pattern not yet covered |
| json       | ✓ | ✓ | G | ✓ | refs GAP (legit cap absent) |
| lua        | F | ✓ | F | F | **NEW**: response decode error: body is not valid UTF-8 |
| markdown   | ✓-NF | ✓ | F | F | marksman names headings differently |
| perl       | ✓ | ✓ | G | ✓ | Fix B unlocked; refs GAP (legit cap absent) |
| python     | ✓ | ✓ | ✓ | ✓ | |
| ruby       | ✓ | ✓ | F | ✓ | refs FAIL only — investigate |
| rust       | ✓ | ✓ | ✓ | ✓ | |
| scala      | F | ✓ | F | F | metals workspace/symbol still timing out |
| terraform  | ✓-NF | ✓ | F | F | terraform-ls names blocks not covered by fuzzy match |
| typescript | ✓ | ✓ | ✓ | ✓ | |
| yaml       | ✓ | ✓ | G | ✓ | refs GAP (legit cap absent) |
| zig        | ✓ | ✓ | ✓ | ✓ | |

Legend: `✓` = OK. `✓-NF` = OK but `not_found` (downstream tools skip).
`F` = FAIL. `G` = GAP (-32601, cap not advertised).

**11/23 langs fully green** (was 9/23 in pass 21). +4 from fixes:
bash, cpp, go, perl. perl/json/yaml return refs as legitimate
capability GAP — useful UX signal, not a defect.

**Outstanding follow-ups for next iteration:**

1. **6 NF langs (css, erlang, html, java, markdown, terraform)** —
   fuzzy drill didn't widen find_symbol's net. Either fixture's
   `symbol_name_path` doesn't match how the LSP names that symbol in
   either `workspace/symbol` or `documentSymbol` responses, or the
   LSP indexes the fixture differently. Most likely a fixture-quality
   issue per lang, not a layer bug.

2. **lua UTF-8 decode error (new)** — `response decode error: body
   is not valid UTF-8`. lua-language-server emitted bytes the JSON
   framing layer rejected. Investigate whether the response is a
   legitimate non-UTF-8 path or a framing-layer corruption.

3. **ruby refs FAIL** — find_symbol PASSes but
   find_referencing_symbols fails. Either ruby-lsp returns
   references in a shape symbols.gleam doesn't decode, or the
   handle's `selection_line/character` is off by one on
   ruby-lsp's doc-symbol output.

4. **3 LSP timeouts/spawns (elixir, lua, scala)** — separate
   LSP-side issues. Track outside symbol-layer scope.

## Symbol-layer support (ADR-026, pass 21 — superseded)

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
| pass 22  | 2026-05-15 | 505/616 (82.0%) | Fixes A+B+C landed (9342897). 11/23 langs symbol-layer green; +4 langs (bash, cpp, go, perl) over pass 21. NF-class fixture issues + lua UTF-8 framing + ruby refs FAIL pending. |
| pass 23  | 2026-05-16 | 512/616 (83.1%) | Two-tier fuzzy + refs Resolution envelope + Latin-1 fallback (9c705d8). 13/23 green; tier-2 unlocked css/terraform; Latin-1 unlocked lua find_symbol. Surfaced lua refs decoder gap (Location[]/LocationLink[]/null) + 4 NF-on-empty-ws cases. |
| pass 24  | 2026-05-16 | 519/616 (84.3%) | Empty-ws fallback + LocationLink/null refs decoder + html/markdown fixture tunes (3a91eaf). **17/23 fully green + 3 refs-GAP-legit = 20/23 functional.** Remaining 3 are LSP-side issues. |
| pass 24h | 2026-05-16 | 519/616 (84.3%) | Same as pass 24 over HTTP transport. **Perfect parity stdio↔http** across all 23 langs × 26 tools. |
| pass 26  | 2026-05-17 | 536/633 (84.7%) | Post-`memory_audit` regression. 4-way parity: pharos-dev × Burrito-binary × stdio × http all return identical 536/633 with identical lang-level + tool-level failures. Memory probe 17/17 on every combination. |
| pass 27  | 2026-05-25 | 565/656 (86.1%) | **Pre-v0.1.0 refresh.** First pass against the 0.1.0-stamped binary. +29 cells over pass 26 from `runtime_pid_info` + `runtime_lsp_state` global cells + extra memory-probe variants. 8 langs at 25/27 (clojure, cpp, erlang, haskell, java, python, rust, typescript); 9 at 23/27; elixir lowest at 16/27 (next-ls -32603 Timeout on workspace/symbol, goto_definition, find_references, format_document — LSP-side, not pharos). ADR-029 jdt:// validated separately via `bin/dogfood-adr-029.py`. |
