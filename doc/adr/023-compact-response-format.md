# 023. Compact response format option for list-shaped tools

**Status:** Accepted
**Date:** 2026-05-10

## Context

Tools today return `tool_helpers.json_encode(result)` — raw LSP JSON
verbatim. ADR-006 chose this on purpose: predictable LSP shapes are
in-distribution for LLMs (models have seen `Hover`, `Location`,
`Diagnostic` in training data), and pass-through avoids coupling the
tool surface to a transformation layer that has to evolve with the
spec. That stance is load-bearing and worth preserving.

But pass-through has a cost on **list-shaped responses**. A
`find_references` call with 30 results in one workspace produces
something like:

```json
[
  {"uri":"file:///home/oof/pharos-mcp/src/session.gleam","range":{"start":{"line":42,"character":8},"end":{"line":42,"character":15}}},
  {"uri":"file:///home/oof/pharos-mcp/src/session.gleam","range":{"start":{"line":78,"character":12},"end":{"line":78,"character":19}}},
  ...
]
```

Per-row ~150 chars, ~70% of which is the repeated URI prefix and JSON
envelope. 30 refs ≈ 5400 chars (~1350 tokens) of which roughly 950
tokens are redundancy. The same data in a workspace-relative compact
form fits in ~250 tokens — a 5-7× reduction with no information loss.

This pattern repeats for `workspace_symbols`, `document_symbols`,
`get_diagnostics`, and the `goto_*` family — all return arrays of
shapes containing a full `Location` or `Range`. Token cost dominates
LLM operation; redundant context is the lever, not round-trip count.

Three design tensions:

1. **Default flip vs opt-in.** Compact-as-default maximizes savings
   but breaks ADR-006's pass-through guarantee. Opt-in preserves the
   guarantee at the cost of LLMs not knowing to ask. Pre-publish
   (v0.0.1, never published) the cost of either choice is bounded.
2. **Per-tool arg vs session-level knob.** Per-tool is composable
   (LLM picks per call). Session-level is set-and-forget (mirrors
   `runtime_set_tool_timeout` from ADR-021). Could ship both.
3. **Format vocabulary.** Two formats (`compact | json`) is the
   minimum useful set. Adding `markdown` / `tsv` invites bikeshedding
   without concrete demand. Defer.

A separate question is whether the formatter layer should *also*
transform the data (filter, dedupe, sort, limit, aggregate). It
should not. Aggregation is composed-tools territory — Tier 2 in
ADR-006, deliberately deferred. The formatter renders the result,
nothing more.

**Prior-art check (completed 2026-05-10).** Surveyed three
LSP-MCP bridges (anonymised here). No emerging convention exists;
each picks a different point on the JSON↔prose axis:

- **Bridge A** — raw LSP JSON pass-through, `file://` URIs, no
  transformation. Validates raw-JSON viability but does not help
  token-conscious agents.
- **Bridge B** — plaintext only (no JSON escape), absolute
  filesystem paths, grouped by file with `---` separators,
  `L<line>:C<col>` notation, embeds 5 lines of surrounding code
  context per reference.
- **Bridge C** — transformed-JSON only (no raw escape),
  workspace-relative paths, grouped by `kind` and
  `relative_path`, embeds 1-line snippets, ships
  shortened-result-factories that auto-degrade to counts when
  output exceeds a char budget.

Two design details from the survey worth borrowing into pharos's
compact format spec below:

- **File grouping.** When ≥2 hits share a file, emit the file path
  on its own line and indent the locations beneath. Compresses
  better than repeating the path on every row.
- **Workspace-relative paths + emit `workspace_root` once.**
  Absolute per-row paths burn tokens; relative + once-emitted
  root strips them. Pharos already proposed this; survey
  confirms it's the better choice.

**Three differentiators retained** vs the surveyed bridges:

1. **JSON-default opt-in compact.** The two opinionated bridges
   above do not offer a raw-JSON escape; that loses agents who
   want the LSP shape they were trained on. Pharos's
   pass-through stance (ADR-006) keeps the LSP shape primary.
2. **`path:line:col-col` (grep-style).** No surveyed bridge uses
   exactly this shape, but it parses identically to `L%d:C%d`
   and matches grep/ripgrep/editor conventions agents already
   know.
3. **Spelled-out symbol kinds (`fn`/`class`/`var`).** Surveyed
   bridges use either numeric `SymbolKind` or long names. Short
   tokens are a pharos choice; document the vocabulary in the
   tool description.

**Deferred for follow-up** (orthogonal to this ADR): a tiered
degradation pattern (response-size cap → auto-summarize) similar
to Bridge C's. Worth considering once usage data shows real runs
hitting context-window limits on huge `find_references` results.

## Decision

Add an optional `format` parameter to list-shaped tools, accepting
`"compact" | "json"`, defaulting to `"json"`. JSON default preserves
ADR-006's pass-through stance and the LLM's in-distribution prior.
Compact is opt-in.

**Affected tools (Tier 1 + Tier 2 list-shaped):**

- `find_references`
- `workspace_symbols`
- `document_symbols`
- `goto_definition`, `goto_type_definition`, `goto_implementation`,
  `goto_declaration`
- `get_diagnostics`
- `call_hierarchy_incoming_calls`, `call_hierarchy_outgoing_calls`
- `type_hierarchy_supertypes`, `type_hierarchy_subtypes`

**Not affected** (single-shape or non-list responses, pass-through
already efficient): `hover`, `signature_help`, `prepare_rename`,
`format_document`, `code_actions`, `rename_preview`, `semantic_tokens`,
`inlay_hints`, `lsp_request_raw`. Revisit if usage shows token waste.

**Compact format spec:**

- Text content block (not JSON-stringified).
- Header line: `workspace_root: <abs path>` emitted once per response.
  LLM reconstructs absolute URIs on demand.
- Paths: workspace-relative.
- Locations: `path:line:col-col` per row, grouped by file when ≥2 hits
  share a file:
  ```
  workspace_root: /home/user/proj
  src/session.gleam
    42:8-15
    78:12-19
  src/main.gleam
    12:4-11
  ```
- Symbols: `<kind> <name> path:line` (kind spelled — `fn`, `class`,
  `var`, `mod` — not numeric `SymbolKind`).
- Diagnostics: `<severity> path:line:col <message>` per row.
- Lines, columns: 0-based to match LSP. No silent off-by-one
  translation.

**Implementation surface:**

- New module `src/pharos/tool_format.gleam` with formatter functions
  per response shape (`format_locations`, `format_symbols`,
  `format_diagnostics`).
- Each affected tool gains an optional `format` field in its input
  schema and routes through the formatter when `compact`.
- Workspace root threaded from `session.prepare/2` (already
  available).

**Session-level default deferred.** Per-tool param only in this
round. If usage shows users repeatedly setting the same value,
revisit with a `runtime_set_response_format` knob mirroring
ADR-021's pattern. Not in this ADR.

**Formatter is rendering only.** Never drops, reorders, dedupes,
filters, or aggregates data. Aggregation is composed-tools
territory (deferred per ADR-006).

## Consequences

**Easier:**

- 5-7× token reduction on high-volume list tools when LLM opts in.
- Compact responses are readable in conversation transcripts —
  debugging an agent run no longer requires JSON-pretty-printing.
- Default unchanged — existing consumers (dogfood harness, raw-JSON
  callers) keep working without a flag day.
- Path-relative output makes file references easier to scan and
  matches how unix tools (`grep`, `rg`) present location lists.

**Harder:**

- Each affected tool's MCP schema gains an optional field. Hosts
  that cache tool schemas must refresh.
- Two output paths to maintain per affected tool. Tests must cover
  both formats.
- Compact format becomes a public contract once shipped — downstream
  parsers may pin to its line shape; future changes need coordination
  via an ADR amendment.

**Live with:**

- Default JSON means most LLM calls won't get the savings unless the
  tool description nudges them. Tool descriptions should mention
  `format: "compact"` explicitly so the LLM knows the lever exists.
- Session-level default deferred. Users who want durable compact
  output across a session set it per-call until usage data justifies
  the knob.
- Composed intent tools (e.g., `understand_symbol`) remain deferred
  per ADR-006. This ADR neither blocks nor accelerates that work —
  composed tools can sit on top of either format.

## Alternatives considered

- **Compact-as-default.** Rejected for now. Pre-publish risk is low,
  but ADR-006's pass-through stance is load-bearing and worth
  preserving until usage data justifies a flip. Default can be
  changed in a follow-up ADR with concrete numbers.
- **Session-level override only (no per-call arg).** Rejected.
  Composability matters; an LLM may want raw JSON for one tool and
  compact for another in the same conversation. Per-call is the
  primitive; session-level is a convenience that can be added later.
- **Multi-format vocab from day one (`compact | markdown | tsv |
  json`).** Speculation without concrete demand. Defer; expand
  vocabulary when a real consumer asks.
- **Transformation layer (filter/dedupe/sort/limit).** Out of scope.
  That's composed-tools territory and crosses ADR-006's "no
  aggregation in primitives" line. The formatter renders only.
- **Skip this ADR; rely on LLM-side post-processing.** Workable but
  burns the redundancy on the way in to the model. The savings only
  land if pharos compresses before the response is returned.
