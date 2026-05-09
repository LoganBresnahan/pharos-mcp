# 021. Timeout resolution stack, per-tool × per-lang config, and LLM-driven session overrides

**Status:** Accepted
**Date:** 2026-05-09

## Context

Pharos has had multiple timeout knobs accreted across milestones, each
solving one specific problem and most landing without coordinated
documentation:

- **Per-call `timeout_ms`** — passed by the LLM as a tool argument.
  Wired today on only 5 of 21 LSP-bound tools (the ones whose schemas
  accept it): `get_diagnostics`, `find_references`, `format_document`,
  `semantic_tokens`, `inlay_hints`. The other 16 tools have no
  per-call escape hatch.
- **`[tool_config.<name>] default_timeout_ms`** — TOML override for
  per-tool default, M13 Phase 12. Currently wired for the same 5
  tools as per-call.
- **`[[languages.<id>.servers]] readiness_timeout_ms`** — post-handshake
  / post-didOpen indexing-drain budget per server. M12.
- **`[[languages.<id>.servers]] initialize_timeout_ms`** — LSP
  `initialize` handshake budget per server. M12.
- **Compile-time per-tool consts** — fallback when nothing else applies.
  `workspace_symbols` is at 10s (too tight for gopls fuzzy-match
  across stdlib); most others at 30s; `find_references` at 60s.

Three problems with this state:

1. **Coverage gap.** 16 tools have no per-call timeout argument and
   no `tool_config` override path. A user with a slow workspace and
   slow `hover` calls cannot tune without editing pharos source.
2. **Granularity gap.** `tool_config.<name>.default_timeout_ms`
   applies globally across languages. A jdtls workspace where
   `type_hierarchy_prepare` takes 60s wants a higher default than a
   rust-analyzer workspace where the same call returns in <1s.
   Setting one global default either wastes time on rust or breaks
   on java.
3. **Error rendering gap.** When a per-tool timeout fires (port
   read window expires), the LLM sees `"LSP transport error"` —
   the same string emitted when the LSP process actually died. The
   LLM cannot tell whether to retry with a larger `timeout_ms` or
   surface a real failure.

A separate but adjacent question: should pharos let the LLM bump
timeout defaults at runtime, surviving across requests in the same
session? Three shapes were considered:

- **TOML-mutating tool** — LLM writes to user's `pharos.toml`.
  Crosses ownership boundary; user's hand-edited file gets touched.
  TOML round-trip preservation (comments, formatting) is non-trivial.
  Rejected.
- **Pharos-owned cache file** (`~/.cache/pharos/learned-overrides.toml`) —
  pharos writes, pharos reads, never user-edited. No round-trip
  problem. But persistence across sessions silently drifts behavior
  and the user has no way to know without inspecting the cache.
  Defer.
- **Process-state session override** — held in actor state /
  persistent_term, lost on pharos restart. LLM-explicit, audit-trail
  in tool-call log, no file mutation. Accepted.

## Decision

**Four-layer timeout resolution stack.** Per-call argument wins,
falling back through layers in this order (later wins):

1. Compile-time `default_timeout_ms` const in each tool module
2. `[tool_config.<name>] default_timeout_ms` in TOML
3. `[tool_config.<name>.<lang>] default_timeout_ms` in TOML
   (per-tool × per-language; `<lang>` matches the workspace's
   resolved language id)
4. Process-state session override applied via
   `runtime_set_tool_timeout` MCP tool
5. Per-call `timeout_ms` argument

**Wire `timeout_ms` and `resolve_tool_timeout` through every
LSP-bound tool.** All 21 tools accept an optional `timeout_ms` in
their schema and pull their default through the four-layer stack.
Backwards-compatible — adds an optional field to existing schemas.

**Bump `workspace_symbols` default from 10s to 30s.** The 10s floor
predates `tool_config` and is too tight for warm-cache fuzzy matches
on large repos.

**Split `client.PortReceiveError` rendering** in
`tool_helpers.describe_request_error`. `port.Timeout` →
`"tool timeout: LSP did not respond in <N>ms; pass a larger
timeout_ms, call runtime_set_tool_timeout, or retry"`.
`port.PortClosed(_)` →
`"LSP process exited unexpectedly (transport closed)"`. The two
collapse to one string today, hiding the distinction the LLM needs
to decide its next action.

**Add MCP tool `runtime_set_tool_timeout({tool, language?,
timeout_ms})`.** Writes to a process-state override map; survives
the session, resets on pharos restart. Logged at INFO under target
`pharos/tool_config/autotune` so the override is auditable in
`runtime_log_tail`. Belongs to the `debug` tool category.

**Defer LLM-driven config persistence.** Neither user-TOML mutation
nor pharos-owned learned-overrides cache file ships in this round.
The combination of per-call `timeout_ms`, session-scoped
`runtime_set_tool_timeout`, and the introspection tool
`runtime_effective_tool_config` (ADR 022) covers the immediate
needs without committing to a persistence design.

**Per-tool × per-language recommended-defaults table** lives in
`doc/example-pharos.toml` and the README — paste-ready stanzas for
heavy LSPs (jdtls, metals, gopls big-mod) so users have starting
numbers without trial-and-error.

## Consequences

**Easier:**

- LLM can tune any tool's timeout per-call without source edits.
- Slow-workspace users get one TOML place to set durable defaults
  (`[tool_config.<name>.<lang>]`) without writing per-LSP overrides.
- Timeout failures are visually distinct from transport-died failures
  so the LLM picks the right next action.
- Recommendations table makes the heavy-LSP onboarding path concrete.

**Harder:**

- The resolution stack is five layers (counting compile-time const
  as layer 0). New maintainers must understand the precedence to
  debug "why is my timeout X?". The introspection tool
  (`runtime_effective_tool_config`) is the user-facing answer.
- Every LSP-bound tool's schema gets a new optional field. MCP
  hosts that cache schemas must refresh.

**Live with:**

- Session overrides via `runtime_set_tool_timeout` are lost on
  pharos restart. Persistence is intentionally deferred — users
  who want durable bumps edit `pharos.toml`.
- The autotune-via-LLM pattern is opt-in by design: pharos never
  silently bumps timeouts without an explicit tool call, so config
  drift is bounded by what's in the conversation log.

## Alternatives considered

- **Pharos auto-bumping on observed timeout-then-retry pattern.** Hidden
  state changes; no audit trail; what trigger heuristic? Rejected
  in favor of LLM-driven explicit tool calls (matches the
  `apply_workspace_edit` "explicit, owned, auditable" pattern).
- **TOML-mutation tool** — see Context. Crosses user-ownership
  boundary; round-trip preservation hard.
- **Pharos-owned `learned-overrides.toml` cache** — defer; revisit
  if real users ask for cross-session persistence after v0.1.0
  ships.
- **Per-tool × per-lang as a runtime override only, no TOML knob.**
  Works for one-off tuning but loses durability. Rejected — TOML
  knob is small additional complexity for a real use case.
