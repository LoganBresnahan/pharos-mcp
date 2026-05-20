# 026. Symbol-layer MCP tools above the raw LSP primitives

**Status:** Accepted
**Date:** 2026-05-15

## Context

Pharos currently exposes raw LSP methods 1:1 as MCP tools — `hover`,
`goto_definition`, `find_references`, `document_symbols`,
`apply_workspace_edit`, etc. These are correct, complete, and the
foundation any higher-level tool will compose. They are also,
empirically, the wrong shape for an LLM.

The reason is simple: **LSP was designed for editors with cursors.**
A request like `textDocument/hover` takes a `TextDocumentPositionParams`
— file URI plus zero-based line and character. That contract assumes a
client (VS Code, Neovim) that already knows where the user's caret is.
LLMs have no caret. They have a *mental model* of code: "the
`authenticate` method on the `User` class," "the function that calls
`compute_total`," "everything that imports `lib/payments`." Forcing
the LLM to translate that mental model into line/column on every call
costs tokens, latency, and correctness — line numbers drift on every
edit, and an off-by-one in a body-range computation silently corrupts
files.

This shows up concretely in our dogfood: tools like `apply_workspace_edit`
PASS because we can issue them, but LLMs in practice fall back to
`Edit`/`grep` for refactors because composing 5–6 primitive calls
(`workspace_symbols` → `documentSymbol` → read file → compute range →
build `WorkspaceEdit` → apply) is more work than just textually
matching `def authenticate(` and rewriting around it. The LSP
knowledge stays unused.

Serena (oraios/serena) addresses this with a symbol-oriented tool
surface — `find_symbol`, `replace_symbol_body`, `insert_after_symbol`,
`find_referencing_symbols`, `get_symbols_overview`. Its tools take a
`name_path` like `"User/authenticate"` rather than coordinates, and
return symbol records the LLM can chain into edit operations
without ever holding a line number. Real-usage data on its tracker
(serena#1491) shows symbol tools dominate tool-call volume across 21k
calls over 21 days; LLMs reach for them when they exist.

We have all the LSP primitives Serena composes. We can do better than
copy because Serena has accumulated bug reports that point at fixable
design choices:

- **Stale symbol cache** (serena#issues several): Serena maintains its
  own symbol index alongside the LSP's. Edits made through Serena
  desync the cache from the file on disk.
- **Hardcoded per-language body-range heuristics** (Python regex against
  source text to find the closing brace, indented block, etc.) — brittle,
  has bug reports per language.
- **Early ambiguity collapse**: `find_symbol` for an overloaded name
  returns the first match or errors, losing information the LLM could
  have used. The set of candidates is the answer in many cases.
- **No multi-server fan-out**: Serena assumes one LSP per workspace.
  Pharos's pool supports several (`pyright` + `ruff` for python under
  ADR-019); symbol lookup should query whichever advertises
  `documentSymbolProvider`.
- **Untyped `name_path`**: a string parameter, with parsing errors
  surfacing late.

There is also a deeper question about how `find_symbol` should treat
ambiguity. LSP returns a *set* of matches for any name that exists in
multiple scopes. Pretending the set is deterministic (collapse to
first / error on ties) loses information. The set itself is the
answer the LLM should consume — alongside enough metadata (container,
location, kind) to pick the right one. This is the non-determinism
that algebraic effects make explicit in languages that ship them; we
will model it as data in Gleam.

## Decision

Ship a `pharos/tools/symbols` module with **four** MCP tools, not the
six Serena exposes. The edit-trio (`replace_symbol_body`,
`insert_before_symbol`, `insert_after_symbol`) take identical
arguments — a `SymbolHandle` and a content string — and differ only
in where the content lands. We consolidate them under one tool with
an enum mode parameter. This holds because: (a) the args are
structurally identical, so the LLM does not lose schema clarity; (b)
the three modes form a well-named axis ("relative to the symbol's
body"); (c) future mutations (`delete_symbol`, `wrap_symbol`) grow
the same enum rather than the tool list.

```
find_symbol(name_path, scope_uri, policy)        -> Resolution
get_symbols_overview(file_uri)                   -> SymbolTree
find_referencing_symbols(symbol_handle)          -> List(SymbolMatch)
edit_at_symbol(symbol_handle, mode, content)     -> Result(EditPreview)

where mode = ReplaceBody | InsertBefore | InsertAfter
```

Token cost: four tools at ~250 tokens of description each beats
six × 250 by ~500 tokens off every MCP session's system prompt.
Same selection clarity for the LLM — each tool name carries its
intent.

Built entirely as a composition of existing LSP primitives we already
ship. No new persistent state. Every call goes to the LSP fresh — the
LSP server's own index is the source of truth.

### Tool-description compression policy

LSP-primitive MCP tools (hover, goto_definition, find_references,
document_symbols, apply_workspace_edit, etc.) currently ship with
verbose descriptions (~300–400 tokens each) explaining what the
underlying LSP method does. Claude's training already covers the LSP
spec — repeating it is dead tokens in every system prompt.

Compress primitive-tool descriptions to **one-line spec reference +
pharos-specific quirks only**:

```
hover:
  "LSP textDocument/hover. Position is zero-based (line, character).
   Returns MarkupContent or null."

inlay_hints:
  "LSP textDocument/inlayHint. Range-scoped. Returns InlayHint[] or
   null. Returns -32601 if server did not advertise
   inlayHintProvider during initialize (ADR 8A)."

rename_preview:
  "LSP textDocument/rename, never writes. Returns the proposed
   WorkspaceEdit. Apply via apply_workspace_edit."
```

What MUST stay explicit, even compressed:

1. Coordinate system. Zero-based, UTF-16 code units. LLMs sometimes
   guess one-based; one foot-gun's worth of tokens prevents many
   wasted calls.
2. Pharos behaviour that diverges from raw LSP — readiness gating,
   automatic retry on `-32801`, the capability-gate `-32601` shape,
   `_preview` semantics that mean "don't write."
3. Argument shape when our wrapper flattens or reorders params from
   the raw LSP shape.

Symbol-layer tools (find_symbol, get_symbols_overview,
find_referencing_symbols, edit_at_symbol) get **fuller descriptions**
— ~250 tokens — because the surface is pharos-specific, the
non-determinism model is novel, and Claude has no training prior on
this exact API. The two-call protocol (`find_symbol` returning a
`Resolution` set, then operating on a `SymbolHandle`) needs to be
spelled out so the LLM uses it correctly.

Total token-budget impact: ~25 primitives × 80 tokens + 4 symbol
tools × 250 tokens ≈ 3000 tokens, down from current ~8000-10000.

Caveat: weaker models (Haiku) have less reliable LSP-spec recall
than Opus. Add an opt-in `--verbose-tool-docs` flag that re-expands
primitive descriptions for those deployments. Default stays
compressed.

Design choices that diverge from Serena:

1. **No symbol cache.** Always re-fetch via `workspace/symbol` +
   `textDocument/documentSymbol`. Avoids the stale-after-edit class
   of bugs entirely. LSP is fast enough on hot indexes; cold indexes
   are slow regardless.

2. **Body-range derived from LSP's own data, not text heuristics.**
   `DocumentSymbol.range` covers the full symbol; `DocumentSymbol.
   selectionRange` covers just the identifier. The body lives in
   `range` strictly after `selectionRange`. For finer precision on
   replacements, call `textDocument/prepareRename` which returns the
   editable range the server itself considers the body. Both work
   per-language because the LSP server already knows the language's
   grammar; we never parse source text.

3. **Resolution returns the set, not a collapsed value.** The
   `Resolution` type encodes ambiguity explicitly:

   ```
   pub type Resolution {
     /// Exactly one match. The handle is safe to pass to edit
     /// operations.
     Single(SymbolMatch)
     /// Multiple matches with the same name_path. The caller (LLM)
     /// picks one and re-calls with the chosen handle. Each match
     /// includes container/location/kind metadata for the
     /// disambiguation prompt.
     Multiple(List(SymbolMatch))
     /// No matches found. The list of near-misses (Levenshtein-close
     /// names within scope) is included so the LLM can correct
     /// typos without re-listing the file.
     NotFound(near_misses: List(String))
   }
   ```

   Edit operations take a `SymbolHandle` (opaque, returned from a
   prior `find_symbol`) — not a `name_path`. This forces a two-call
   protocol: locate, then operate. The LLM has to confirm uniqueness
   itself, and we cannot accidentally edit the wrong match because
   the handle carries the exact (uri, range) pair.

4. **`Disambiguation` policy as a `find_symbol` parameter** for the
   cases where the LLM does want collapse:

   ```
   pub type Disambiguation {
     AllMatches               // default — return the set
     FirstMatch               // collapse to first; ignore rest
     ClosestScope             // collapse to match with shortest path
     StrictSingle             // 0 or >1 → NotFound / Multiple
   }
   ```

   This is the "non-determinism as data" pattern: the caller picks the
   handler, not the library. We do not have algebraic effect handlers
   in Gleam, so the policy is a tagged-union parameter rather than a
   true effect context, but the semantics are isomorphic.

5. **Type-safe `NamePath`**: an opaque type with a constructor that
   rejects empty, malformed, or whitespace-only paths. Edits to the
   public API cannot accidentally pass `""` or `"/"`.

6. **Multi-server fan-out for symbol lookup.** When a workspace has
   several servers configured (per ADR-019 `methods.By` routing),
   `find_symbol` queries every server that advertises
   `documentSymbolProvider` / `workspaceSymbolProvider` and merges
   their results, deduplicating by `(uri, range)`. pyright + ruff
   on a python file both contribute.

7. **Capability gate from ADR 8A** wraps every symbol call. A server
   that did not advertise `documentSymbolProvider` returns
   `Unsupported` immediately rather than burning the per-tool budget
   on a method that will silently never reply.

8. **`SymbolTree` reshape on `get_symbols_overview`.** LSP's nested
   `DocumentSymbol[]` is good for editors that draw outline panes.
   We render it for an LLM: indent by depth, suppress noise
   kinds (Variable inside Function bodies, anonymous closures),
   include `selectionRange.start.line` as the only coordinate the
   LLM needs.

9. **`EditPreview` return on every edit operation.** Edits never
   write by default — they return the proposed `WorkspaceEdit` plus
   a rendered diff. The LLM reviews and decides whether to call
   `apply_workspace_edit` (we already ship that tool from M11.1).
   This matches our existing safety default for `rename_preview`.

Implementation is pure composition above the existing tools. No new
FFIs, no new actor types, no new persistent state. The module lives
at `src/pharos/tools/symbols.gleam` and registers four new MCP tools.

## Consequences

What becomes easier:

- LLMs can address code by intent ("the `authenticate` method on `User`")
  rather than by coordinate. Edits compose without line-number drift
  bugs.
- We close a feature gap with Serena while keeping the raw-LSP primitive
  surface available for advanced use.
- Ambiguity surfaces to the LLM rather than being silently collapsed
  by the tool. The LLM gets to use context (recent file, current
  conversation, type information) to disambiguate.
- The `EditPreview` pattern keeps the LLM in the review loop on every
  refactor — no surprise writes.

What becomes harder:

- New tools to maintain — four MCP entries with their own JSON-schema
  surface, prompts, and golden-output tests.
- The `Resolution` set-returning shape is novel; LLMs trained on
  Serena's collapsed API will need to learn the two-call protocol.
  Mitigation: tool descriptions explicitly explain `Multiple ->
  re-call with chosen handle` flow.
- Multi-server fan-out is fan-in too: we have to dedupe `(uri,
  range)` pairs that come back from independently-indexed servers,
  and resolve conflicts when ranges overlap but do not match.
- Body-range extraction will still fail on languages with
  unusual grammars (where `range` and `selectionRange` overlap or
  `selectionRange` is empty). We fall back to `prepareRename` first,
  and if that also fails, surface a typed `BodyRangeUnknown` error
  rather than guessing.

Risks and follow-up:

- **Tool description token cost.** Four symbol tools plus
  re-compressed primitives net ~3000 tokens of system-prompt
  surface (down from ~8000 today). We measure on the next
  dogfood pass; if the primitive compression regresses
  tool-selection accuracy on Haiku, fall back to a
  `--verbose-tool-docs` flag that re-expands the primitives only
  for that deployment.
- **Server quality varies.** `gleam` LSP returns Method symbols
  without children even for simple definitions; tree-walk
  disambiguation may collapse there. Capability gate plus a typed
  `IncompleteSymbolTree` warning in the response handles this; the
  underlying LSP fix is outside our scope.
- **`SymbolHandle` invalidation.** A handle issued at time T0 may
  refer to a range that no longer exists at T1 (file edited
  through another channel). Edit operations must re-verify by
  calling `documentSymbol` against the handle's URI and confirming
  the symbol with matching `(name, selectionRange.start.line)`
  still exists. If not: return `HandleStale(near_position)`.

## Alternatives considered

- **Don't add symbol layer — just document the LSP primitive flow.**
  Loses the empirical evidence from Serena that LLMs avoid composing
  primitives. Documentation does not change LLM behavior.
- **Six separate edit tools (Serena's shape).** Three of them
  (`replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`)
  take identical arguments and differ only in placement. One tool
  with a `mode` enum collapses them without losing schema clarity —
  the LLM still picks by intent because `edit_at_symbol(mode:
  ReplaceBody)` reads like a single operation. Saves ~500 tokens
  off every system prompt for no behavioural cost.
- **One polymorphic `symbol_op` tool covering all four operations.**
  Goes too far the other direction. Tool-selection research and
  Anthropic's own tool-use guides show LLMs pick tools more
  accurately when names carry semantic weight. `find_symbol` and
  `edit_at_symbol` have meaningfully different intents and return
  shapes; collapsing them forces the LLM into a two-stage decision
  ("symbol_op + which sub-op"). Hybrid (four tools, edit-trio
  consolidated) keeps the names where they matter.
- **Copy Serena verbatim.** Inherits the stale-cache, hardcoded-
  body-range, and early-collapse bugs we know about from its tracker.
  No reason to ship the same defects.
- **Build on top of tree-sitter rather than LSP.** Tree-sitter has
  grammars for every language already and a stable concrete syntax
  tree. But the LSP server already knows symbol kinds and scopes
  semantically (not just syntactically) — `prepareRename` and
  `documentSymbol` know what is a class vs an annotation vs a type
  alias. Reusing the LSP's work is correct; tree-sitter would be a
  parallel, duplicating grammar layer.
- **Algebraic effect handlers for non-determinism.** Right model,
  wrong language. Gleam has no effect-handler primitive. The
  `Disambiguation` enum + `Resolution` return type approximates it
  with concrete data; semantically equivalent for our use case.
- **Symbol cache to amortize repeated lookups.** Serena tried this
  and the failure mode (cache vs disk skew after edits) is worse
  than the cost it saves. Our LSP servers cache internally; we
  re-query them each time and let them decide what is fresh.
