# Architecture Decision Records

ADRs capture significant, hard-to-reverse decisions and the context behind them. Each ADR is a small immutable document. When a decision is later overridden, write a new ADR that supersedes the old one — never edit the original.

## Format

Each ADR uses `template.md`. Required sections:

- **Status** — Proposed / Accepted / Superseded by NNN
- **Context** — what made this decision necessary; constraints and forces
- **Decision** — what we chose, in active voice
- **Consequences** — what becomes easier, what becomes harder, what we now have to live with

## Numbering

Sequential, zero-padded to three digits: `001-`, `002-`, etc. Numbers are immutable. If an ADR is rejected before merging, its number is still consumed (gaps are fine — they preserve history).

## Accepted ADRs

| # | Title | Status |
|---|-------|--------|
| 001 | [Language: Gleam over Elixir](001-language-gleam.md) | Accepted |
| 002 | [JSON-RPC: pollux native, no wrapper](002-pollux-for-jsonrpc.md) | Accepted |
| 003 | [Standalone binary, optional VSCode extension as buffer-state booster](003-standalone-with-extension-bridge.md) | Accepted |
| 004 | [Distribution: GitHub Releases + npm optional-deps pattern](004-distribution-npm-and-releases.md) | Accepted |
| 005 | [Build chain: Mix + mix_gleam, source 100% Gleam](005-mix-gleam-build-chain.md) | Accepted |
| 006 | [Curated tool surface, no LSP JSON Schema auto-gen](006-curated-tools-no-schema.md) | Accepted |
| 007 | [Two-repo split: binary and extension as independent repos](007-two-repo-split.md) | Accepted |
| 008 | [Fork mix_gleam to remove third-party stall risk on the build chain](008-fork-mix-gleam.md) | Accepted |
| 009 | [Dogfood the MCP server via Claude Code at every milestone](009-dogfood-via-claude-code.md) | Accepted |

## Anticipated future ADRs

Written when the corresponding decision actually arises with tradeoffs — not pre-committed:

| # | Title | Trigger |
|---|-------|---------|
| 010 | Tool result format: MCP content blocks | First real tool ships, rendering choices firm up |
| 011 | Config file format and location | Language-registry config gets implemented |
| 012 | LSP lifecycle policy: kept-warm vs spawn-per-call | rust-analyzer cold-start hits in real use |
| 013 | Bridge port discovery mechanism | Extension repo bootstraps |
| 014 | Workspace root determination | First multi-root project test runs |
| 015 | Error surfacing: MCP error vs content-block-with-error | LSP error scenarios surface in tool tests |
