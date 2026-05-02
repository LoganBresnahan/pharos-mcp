# 001. Language: Gleam over Elixir

**Status:** Accepted
**Date:** 2026-05-02

## Context

The project is a JSON-RPC bridge: protocol parsing, dispatch, transport, supervised subprocess management. Three languages were on the table: TypeScript, Elixir, Gleam. Each has tradeoffs.

**TypeScript** — the dominant language for MCP servers and most LSP servers. Largest ecosystem, mature MCP SDK, easy npm distribution, easy VSCode extension reuse if the project ever pivots. Loses on: runtime type safety only (zod adds runtime checks; nothing at compile time), Node single-threaded by default (workers for parallelism are awkward), concurrency for managing N child processes (LSPs) is doable but unergonomic, single-binary distribution is poor (Node runtime baggage, pkg/nexe are buggy).

**Elixir** — BEAM gives world-class concurrency for managing many subprocesses (each LSP = a supervised child). Pattern matching fits JSON-RPC envelope dispatch. OTP supervisors give crash recovery without try/catch. Loses on: dynamic typing (runtime errors only), no Hex package for MCP/LSP semantics, would need to write protocol structs from scratch with `jsonrpc2_spec` providing minimal Layer 2 help (and that has bugs around optional `params`).

**Gleam** — compiles to BEAM, so all the OTP wins from Elixir are available. Adds: static type system catches malformed messages at compile time (a major win for code that does nothing but pass typed messages around), `pollux` Hex package is MCP-aware out of the box (handles optional params, type-parametric Request/Notification sum), pattern matching with exhaustiveness checking. Loses on: smaller ecosystem (some Elixir libs need FFI wrapping), fewer learning resources, smaller community for SO answers, less common in production.

The user wanted typed-language practice and committed to Gleam early in planning. The protocol-heavy nature of the project (every layer is JSON-RPC envelopes flowing in and out) is a good fit — type errors at compile time eliminate a class of bugs the runtime-validation path (TS+zod or Elixir+jsonrpc2_spec) only catches at runtime.

## Decision

Gleam is the implementation language. All `.gleam` files live in `src/` and are compiled by `mix_gleam` as part of the Mix build pipeline (see ADR-005). Elixir is present only as a build-tool dependency; no `.ex` files in the codebase.

`pollux` (Hex) is the JSON-RPC protocol library — its types and decoders are used directly without a wrapper (see ADR-002).

OTP supervision via `gleam_otp`. Subprocess management (LSPs) via Erlang `Port`s accessed through `gleam/erlang` FFI.

## Consequences

**Easier:**
- Compile-time enforcement of protocol shape across the entire codebase — a typo in a record field is caught before tests run
- Pattern-match exhaustiveness on JSON-RPC variants (Request / Notification / Response) — Gleam complains if a case is missing
- OTP supervision tree is type-checked (child specs declare their message types)
- `pollux` works natively, no FFI ceremony

**Harder:**
- Smaller community → fewer Stack Overflow answers, fewer blog posts, fewer reusable libraries
- Some libraries we'd want (TOML parser, HTTP client features) only exist in Erlang/Elixir form and need FFI binding
- Onboarding contributors who don't know Gleam is a real cost; mitigated by Gleam's small surface area (it's a small language by design)
- Build chain has an extra tool (`mix_gleam` archive) compared to a pure-Elixir project

**Living with:**
- The user's typed-language practice goal is part of the project's value, not just an incidental preference. Re-evaluating language is a project-level pivot, not a routine refactor. Switching back to Elixir later means rewriting everything in `src/`.
- BEAM cold start is ~100-300ms — slow vs Go/Rust binaries, fine for a long-running MCP server. Burrito self-extract on first run adds ~1s once. Acceptable for our use case.

## Alternatives considered

- **TypeScript / Node.js** — biggest ecosystem, but already the language jonrad/lsp-mcp uses; differentiation is harder. Loses on type safety vs Gleam (TS types don't survive JSON boundary; zod is runtime). Single-binary distribution via pkg/nexe is fragile.
- **Elixir** — BEAM benefits without learning a new language, but loses compile-time type safety on the protocol layer. Would still depend on `jsonrpc2_spec` (which has known bugs around optional fields) plus a custom Notification classifier.
- **Rust** — fastest, smallest binaries. Wrong shape for managing N supervised child processes — async runtime works but doesn't give the OTP supervisor model out of the box. Bigger learning curve than Gleam for the user.
- **Go** — single static binary, good concurrency. No type-parametric protocol library available; would write everything from scratch. Lacks BEAM's supervision model.
