# 006. Curated tool surface, no auto-generation from LSP JSON Schema

**Status:** Accepted
**Date:** 2026-05-02

## Context

There is a community-generated JSON Schema describing every LSP method's params and result types (~50 methods). `jonrad/lsp-mcp` (the prior-art TypeScript MCP-LSP bridge) uses this schema to auto-generate one MCP tool per LSP method: tool names, input schemas, and dispatch logic come from iterating the schema at startup. Zero hand-written tool code.

This is genuinely clever. Three properties make it attractive: (1) complete LSP coverage with no per-tool work, (2) automatic adaptation to LSP spec evolution if the schema is regenerated, (3) zero bias in tool selection — power users get every method, no editorial choices.

But for our project, three concerns weigh against it:

**Tool-list bloat.** Exposing ~50 tools to an LLM is noisy. Many LSP methods are server→client only (`window/logMessage`, `$/progress`, `telemetry/event`) and useless as tools. Many are UI-shaped (`documentHighlight`, `foldingRange`, `selectionRange`, `codeLens`, `documentLink`) — designed for editors, not for semantic understanding by an LLM. LLMs handed a long tool list pick wrong tools more often, and every tool description spent on irrelevant LSP methods costs context.

**Loss of compile-time type safety.** Auto-gen tools take their params and results as `Dynamic` JSON values — there is no Gleam record describing a `HoverParams` or `RenameParams` because those types come from a runtime-loaded schema. ADR-001's whole rationale for choosing Gleam was compile-time enforcement of protocol shapes. Auto-gen abandons that for the tool surface — exactly the layer where shape matters most.

**Result types are LSP-flavored, not LLM-flavored.** LSP results are designed for editors. `Hover` returns `MarkupContent | string | MarkedString[]` — a three-way sum that needs translation to readable markdown for an LLM. `WorkspaceEdit` has both `changes` and `documentChanges` forms; raw return is confusing. Auto-gen surfaces the LSP shape verbatim; we'd lose the chance to produce content blocks shaped for LLM consumption.

**Stateful workflows are not captured.** Some methods require sequencing — `textDocument/hover` is meaningless without prior `textDocument/didOpen`. Auto-gen exposes hover as if it were stateless; a naive LLM call gets back nothing because the document was never opened. Hand-written tools encapsulate the open-then-query pattern.

A middle ground exists: hand-curate the small set of tools LLMs actually use, and add a single `lsp_request_raw` escape-hatch tool that takes any LSP method name plus params and forwards verbatim. Power users / agentic clients that read the LSP spec can drive the escape hatch when they need a method we did not curate. This preserves type safety for the common case while keeping the long tail accessible.

## Decision

Hand-curate tools in tiers. Each curated tool is a Gleam module with:
- Typed params record (`pub type Params { Params(uri: String, line: Int, character: Int) }`)
- Typed result type
- A `tool_definition()` function returning the MCP tool definition with description and input schema
- A `handle/2` function that takes typed params + an LSP client handle and returns a content block

Tier breakdown (full list in `init.md` § Tool surface):

- **Tier 1 (v0.1):** 6 read tools — `get_diagnostics`, `hover`, `goto_definition`, `find_references`, `document_symbols`, `workspace_symbols`
- **Tier 2 (v0.2):** deeper read + non-mutating writes — `goto_type_definition`, `goto_implementation`, `signature_help`, `call_hierarchy_*`, `code_actions`, `rename_preview`, `format_document`
- **Tier 3 (v0.3+):** specialized — `inlay_hints`, `semantic_tokens`, `prepare_rename`, `type_hierarchy_*`
- **Skipped:** `completion` (noisy, position-sensitive, LLMs don't need autocomplete); UI-only methods (`documentHighlight`, `foldingRange`, `selectionRange`, `codeLens`, `documentLink`, `onTypeFormatting`); editor lifecycle (`willSave*`, `didSave`)

One escape-hatch tool ships in Tier 2: **`lsp_request_raw`** takes a `method` string and `params` as `Dynamic` JSON, forwards to the appropriate LSP, returns the raw result wrapped in a JSON content block. No type safety on this tool's params/result. It exists for power users and agentic clients that know the LSP spec.

Edit tools in Tier 2 (`rename_preview`, `format_document`, `code_actions`) **never apply edits**. They return `WorkspaceEdit` data as content blocks (both raw JSON and a unified-diff rendering). The LLM uses its host's existing file-edit tools to apply if desired. Edit-as-data preserves exploratory flows and audit clarity.

## Consequences

**Easier:**
- Compile-time type safety across the tool surface — adding a new tool is a Gleam module that won't compile if shapes are wrong
- LLM-friendly tool descriptions, hand-tuned for the kinds of questions LLMs actually ask
- Output formatted as MCP content blocks with both structured (JSON) and human-readable (markdown / unified diff) representations
- Stateful workflows (open-then-query) encapsulated inside tool handlers
- Small default tool list (6 in v0.1) keeps LLM context lean
- `lsp_request_raw` keeps the long tail accessible without polluting the default tool list

**Harder:**
- Each new tool is ~50-100 lines of Gleam (module, types, schema, handler) instead of zero lines via auto-gen
- LSP spec evolves; we manually pull in new methods rather than regenerating
- Tool selection involves editorial judgment — what to expose, what to skip — and that's a recurring decision

**Living with:**
- The total amount of tool code is bounded — Tier 1+2 caps around 15 tools, ~1000-1500 lines total. Manageable.
- A user who needs an obscure LSP method can always use `lsp_request_raw`. The escape hatch keeps us from being a bottleneck.
- Bias is acknowledged: we're picking what we think LLMs need. We may be wrong about specific tools; correctible by user feedback.

## Alternatives considered

- **Auto-gen all ~50 tools from the LSP JSON Schema (jonrad/lsp-mcp approach)** — rejected for the four reasons above (bloat, lost type safety, LSP-flavored results, no stateful workflows).
- **Auto-gen + filter list** — bundle the schema, but only register the ~15 tools we want. Halfway compromise. Still loses type safety for the registered tools because the params/results are dynamic from the schema. Doesn't gain coverage either, because we filtered. Worst of both worlds.
- **No escape hatch (curated only)** — tighter surface, but every new use case requires a curated tool. The escape hatch is cheap (~30 lines) and avoids us being a gating bottleneck.
- **Auto-apply edit tools instead of edit-as-data** — discussed and rejected. Two-step (return edit, LLM applies via file tools) is safer, more composable, and gives audit clarity. A future `apply_workspace_edit` tool can be added if a clear use case emerges.
