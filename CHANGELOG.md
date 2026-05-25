# Changelog

All notable changes to pharos-mcp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-05-25

Initial public release. Headless LSP↔MCP bridge for AI agents.

### Added

- **MCP server** speaking 2024-11-05 protocol over stdio. Compatible
  with Claude Code, Cursor, and any MCP-aware host.
- **23 language adapters** wrapping real LSP servers — rust
  (rust-analyzer), go (gopls), typescript
  (typescript-language-server), python (pyright + ruff), java
  (jdtls), gleam (gleam-lsp), cpp (clangd), elixir (next-ls),
  ruby (ruby-lsp), zig (zls), scala (metals), clojure
  (clojure-lsp), haskell (hls), perl (perlnavigator), erlang
  (elp), lua (lua-language-server), bash (bash-language-server),
  terraform (terraform-ls), yaml (yaml-language-server), markdown
  (marksman), html / css / json (vscode-langservers-extracted).
  Capability matrix at `doc/lsp-capability-matrix.md`.
- **Symbol-layer tools** (ADR-026) — `find_symbol`,
  `find_referencing_symbols`, `get_symbols_overview`,
  `containing_symbol`, `edit_at_symbol`. Symbol-name-anchored
  navigation that doesn't require line/column coordinates.
- **Universal editor bridge** (ADR-028) — `apply_workspace_edit`
  and `rename_preview` produce LSP-shaped `WorkspaceEdit`
  documents that any editor or AI host can apply.
- **Custom URI schemes** (ADR-029) — `jdt://` (Java external types)
  flows through navigation tools transparently; `fetch_uri_contents`
  reads the raw text for any scheme the active LSP supports.
- **Compact response format** (ADR-023) — opt-in `format: "compact"`
  on list-shaped tools (find_references, workspace_symbols,
  get_diagnostics, goto_*, hierarchy_*) for ~5-7× token reduction.
- **Process lifecycle hardening** (ADR-030) — graceful exit on
  stdin EOF, crash-repro suite, cleanup CLI; `pharos warm <lang>...`
  and `pharos warm --all` pre-spawn LSPs for disk-cache warmup.
- **Per-tool timeout overrides** via `runtime_set_tool_timeout`
  (ADR-021).
- **Project memory tools** — `memory_save`, `memory_get`,
  `memory_list`, `memory_audit`, `memory_prune` for per-project
  curated notes.
- **npm distribution** — `npm i pharos-mcp` resolves the right
  platform binary via scoped `optionalDependencies`
  (`@pharos-mcp/linux-x64`, `@pharos-mcp/darwin-arm64`, etc.).
  Trusted-publisher OIDC; no NPM_TOKEN in CI.
- **Direct binary downloads** attached to each GitHub Release for
  the 5 supported targets: linux-x64, linux-arm64, darwin-x64,
  darwin-arm64, win-x64.

### Known limitations

- `fetch_uri_contents` is only meaningful for LSPs that emit
  non-`file://` URIs (Java/jdtls). Clojure and Scala adapters do
  not currently surface their virtual schemes — tracked for a
  future release.
- Elixir adapter passes 16/27 dogfood cells; ElixirLS does not
  implement several LSP features the matrix probes. Use with
  awareness.
- `warm --all` uses workspace root markers to decide which
  languages to spin up. The `.git` marker shared by TS/JS/HTML/
  CSS/JSON means those will all attempt to warm in any git
  project; pass explicit languages (`pharos warm rust go`) for
  precise control.

[Unreleased]: https://github.com/LoganBresnahan/pharos-mcp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.0
