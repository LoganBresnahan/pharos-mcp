# 002. JSON-RPC library: pollux native, no wrapper, no own implementation

**Status:** Accepted
**Date:** 2026-05-02

## Context

The project speaks JSON-RPC 2.0 on three protocol surfaces (MCP stdio, MCP HTTP, LSP stdio). It needs:

- Typed Request / Response / Notification structs
- Validation: enforce `jsonrpc == "2.0"`, valid id types, optional vs required fields
- Encoding/decoding to/from JSON
- Error code constants from the spec

Three options were evaluated:

**Option A — Use the Hex package `json_rpc` (Elixir, by mkruse).**
v0.1.0 from 2021. 219 total downloads, 3/week. Single release, abandoned. Not production quality.

**Option B — Use the Hex package `jsonrpc2_spec` (Elixir, by undr).**
Active (v0.1.1, Dec 2025). Provides Request, Response, Result, Error, Batch structs with predefined error codes. Solid quality. **Two issues:** (1) `Request.parse/1` requires a `"params"` key to be present, but the JSON-RPC 2.0 spec defines `params` as optional — notification-without-params and request-without-params return `{:invalid, _}`. (2) No Notification type — must wrap. Both are workable but mean writing a thin classifier on top.

**Option C — Use the Hex package `pollux` (Gleam, by crowdhailer).**
v1.0.0 (Dec 2025), 8.7k downloads, 300/week. Actively used in EYG. Type-parametric `Request(r, n)` sum — Notification is a variant, not a separate type. Source contains the comment `// In mcp there are optional fields` — author already considered MCP and handles missing `params` (defaults to empty object, fixing exactly the bug `jsonrpc2_spec` has). Decoder-driven dispatch built in. Strong `Id` sum type (StringId / NumberId). Result-shaped Response (`Result(t, ErrorObject)` enforces XOR at the type level).

**Option D — Wrap pollux from Elixir.** Costs ~150-200 lines of Elixir wrapper to translate Gleam tagged tuples into Elixir structs. Loses Gleam's compile-time type safety at the boundary. Wrong economics for a small library.

**Option E — Write our own.** ~200 lines of Gleam for spec entities + codec. Gives full control but reinvents what `pollux` already provides cleanly. Slow path — only worth it if `pollux` had a fundamental mismatch with our needs.

The decision to use Gleam (ADR-001) makes Option C native — `pollux` is a Gleam library that fits without translation. The MCP-awareness of `pollux` is the deciding factor: we'd otherwise have to write workarounds for the same case the author already handled.

## Decision

Use `pollux` directly as a Hex dependency (`{:pollux, "~> 1.0"}`). Its types — `Request(r, n)`, `Response(t)`, `Id`, `ErrorObject` — are imported and used throughout the codebase. No wrapper layer.

For MCP's specific dispatch needs (`initialize`, `tools/list`, `tools/call`, etc.), our `mcp/server.gleam` module composes pollux's decoders with method-specific payload decoders. Each method gets a typed params record; the decoder is constructed at module level once and reused.

For LSP's specific request types, similarly — each LSP method we expose has a typed request/response pair, decoded with method-specific decoders combined with pollux's envelope handling.

The one thing pollux does not provide is a `Batch` type. JSON-RPC 2.0 batch was removed from MCP in the 2025-03-26 spec revision and is not used by LSP. Not needed.

## Consequences

**Easier:**
- Optional `params` works correctly out of the box — no `jsonrpc2_spec`-style bug to work around
- Notification is a first-class variant of `Request(r, n)` — pattern match handles both arms exhaustively
- Strongly typed `Id` (StringId / NumberId) catches misuse at compile time
- `Response(t)` uses Gleam's `Result` type — can't construct a response with both result and error
- Author actively maintains the package (real usage in EYG)

**Harder:**
- We are coupled to `pollux`'s API. If crowdhailer makes breaking changes in v2, we adapt. Mitigated by pinning `~> 1.0` and reading changelogs before upgrading.
- `pollux` is decoder-first: every method we support needs its own decoder constructed at compile time. This is the right pattern but means each new tool/LSP method is a few lines of decoder code. Trade-off vs auto-gen from JSON Schema is taken in ADR-006.

**Living with:**
- No Batch support. If a future MCP client expects batch (none currently do), we add it ourselves.
- Tied to BEAM/Gleam. If we ever pivot language, `pollux` is unportable; the protocol code rewrites.

## Alternatives considered

- **Option A: `json_rpc` Hex pkg** — abandoned, 3 downloads/week. Skip.
- **Option B: `jsonrpc2_spec` Hex pkg** — Elixir, has the optional-params bug, requires wrapping for Notification. Workable but not clean.
- **Option D: Wrap pollux from Elixir** — scoped out when ADR-001 chose Gleam. Wrapping a small library to lose its type safety is anti-economic.
- **Option E: Write our own** — ~200 lines we don't need to write. `pollux` is well-shaped.
