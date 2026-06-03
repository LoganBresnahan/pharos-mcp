# Changelog

All notable changes to pharos-mcp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] — 2026-06-03

Fossil-fix patch release. No behavior changes; only error-message
and tool-description wording. The v0.1.0 → v0.1.1 ship gates
defined in `doc/m14-test-plan.md` (Gate 1 dogfood-23lang + Gate 2
owner MCP-host dogfood) were waived for this release because the
patch is strictly wording.

### Fixed

- `get_diagnostics` and other tools routed through
  `describe_diagnostics_error` no longer say
  `rust-analyzer failed to spawn:` when a non-Rust LSP fails to
  start. The message is now language-neutral:
  `LSP spawn failed: <reason>`. Matches the wording already used by
  `describe_session_error` in `src/pharos/tools/session.gleam`.
- `get_diagnostics` no longer claims
  `v0.1 only supports .rs files; got: <uri>` when called on a URI
  whose extension has no registered language. Replaced with the
  neutral `unsupported file type: <uri>` used elsewhere.
- Tool JSON-schema descriptions for `goto_definition`,
  `get_diagnostics`, and one sibling tool no longer use
  `file:///home/user/project/src/main.rs` as the example file URI;
  replaced with the language-neutral `file:///path/to/file`.
- `timeout_ms` description on `get_diagnostics` no longer singles
  out `gopls and rust-analyzer` as the slow LSPs.
- Internal doc comments in `src/pharos/lsp/lifecycle.gleam`,
  `src/pharos/mcp/content_block.gleam`, and
  `src/pharos/lsp/framing.gleam` no longer frame their conventions
  as "v0.1 only" behaviors.

### Added

- CI grep-guard that fails the build if a non-test source file
  introduces hardcoded `rust-analyzer` / `v0.1 ` / `main.rs`
  outside an allowlist. Prevents the fossil class from returning.
- Unit tests under `test/mcp/server_error_messages_test.gleam`
  pinning the language-neutral wording so it cannot regress
  silently.

### Internal

- `describe_diagnostics_error` is now `pub` so the new test module
  can import it. Error rendering is part of the public MCP-client
  contract anyway.
- Bumped `@version_base` (mix.exs), `gleam.toml`, the four
  `server_version` constants (src/pharos.gleam, src/pharos/cli.gleam,
  src/pharos/mcp/server.gleam, plus matching inline literals in
  src/pharos/smoke.gleam and src/pharos/tools/session.gleam) from
  `0.1.0` to `0.1.1`.

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

[Unreleased]: https://github.com/LoganBresnahan/pharos-mcp/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.1
[0.1.0]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.0
