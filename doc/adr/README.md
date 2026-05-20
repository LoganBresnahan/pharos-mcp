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
| 010 | [Defer bidirectional LSP server-request handling until pre-Tier-2](010-defer-server-request-handling.md) | Accepted |
| 011 | [Local Mix.Task workaround for hex package name vs OTP application name mismatch](011-mix-app-name-symlink-workaround.md) | Accepted |
| 012 | [Bidirectional LSP server-request handling: registry, sessions, and SSE](012-bidirectional-lsp-and-sse.md) | Accepted |
| 013 | [Supervisor tree and per-LSP worker process](013-supervisor-tree-and-lsp-worker.md) | Accepted |
| 014 | [Runtime introspection tools](014-runtime-introspection-tools.md) | Accepted |
| 015 | [Multi-root rust-analyzer](015-multi-root-rust-analyzer.md) | Accepted |
| 016 | [Cancel propagation](016-cancel-propagation.md) | Accepted |
| 017 | [Supervision tree wiring](017-supervision-tree-wiring.md) | Accepted |
| 017a | [lsp_proc under simple_one_for_one](017a-lsp-proc-simple-one-for-one.md) | Accepted |
| 018 | [LSP binary path resolution](018-lsp-binary-path-resolution.md) | Proposed |
| 019 | [Multi-LSP method routing per language](019-multi-lsp-method-routing.md) | Proposed |
| 020 | [Hot code reload tool for dev iteration](020-hot-code-reload-dev-tool.md) | Proposed (Deferred) |
| 021 | [Timeout resolution stack, per-tool × per-lang config, LLM-driven session overrides](021-timeout-resolution-and-autotune.md) | Accepted |
| 022 | [Logging conventions: structured fields canonical, file rotation, ring target-prefix filter](022-logging-conventions.md) | Accepted |
| 023 | [Compact response format](023-compact-response-format.md) | Accepted |
| 024 | [LSP readiness gate](024-lsp-readiness-gate.md) | Accepted |
| 025 | [Pool off-actor spawn](025-pool-off-actor-spawn.md) | Accepted |
| 026 | [Symbol layer](026-symbol-layer.md) | Accepted |
| 027 | [Project-local memory tools for cross-MCP-client knowledge sharing](027-project-memory-tools.md) | Proposed |
| 028 | [Universal editor bridge: sensors and displays, never LSP host](028-universal-editor-bridge.md) | Proposed |

## Anticipated future ADRs

Written when the corresponding decision actually arises with tradeoffs — not pre-committed:

| # | Title | Trigger |
|---|-------|---------|
| 023 | Tool result format: MCP content blocks | First real tool ships, rendering choices firm up |
| 024 | Bridge port discovery mechanism | Extension repo bootstraps |
| 025 | Workspace root determination | First multi-root project test runs |
| 026 | Error surfacing: MCP error vs content-block-with-error | LSP error scenarios surface in tool tests |
| 027 | Config file format and location (formalize) | Override registry promoted to first-class config |
