# Changelog

All notable changes to pharos-mcp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] — 2026-07-10

### Fixed

- **`--version` and MCP `serverInfo` no longer drift from the release.**
  pharos's own version was hardcoded as a string literal in five source
  files; 0.1.3 bumped the package metadata but not those literals, so it
  shipped identifying itself as `0.1.2` to every MCP client. The version
  is now read once at runtime from the OTP application `vsn` (derived
  from `mix.exs` / `gleam.toml`), and CI asserts `pharos --version`
  matches the release tag so this can't recur.

## [0.1.3] — 2026-07-10

### Changed

- **License: relicensed from AGPL-3.0-only to Apache-2.0.** Pharos
  is now permissively licensed — free to embed and ship inside
  closed-source and commercial products, with an express patent
  grant and no network-use source-disclosure obligation. The former
  dual-license commercial track (`COMMERCIAL.md`) is retired, and
  the Contributor License Agreement is replaced by a lightweight
  [Developer Certificate of Origin](DCO) sign-off (`git commit -s`),
  enforced by a new DCO check in CI.

## [0.1.2] — 2026-06-03

Bug-fix patch release. Repairs `pharos --doctor` and
`pharos --purge-cache`, both of which silently pointed at a path
Burrito never creates on every supported platform. No tool-surface
or MCP-protocol changes.

### Fixed

- **`pharos --doctor`** now reports the real Burrito cache root
  (`$XDG_DATA_HOME/.burrito` or `~/.local/share/.burrito` on Linux,
  `~/Library/Application Support/.burrito` on macOS,
  `%LOCALAPPDATA%\.burrito` on Windows) and a non-zero cache size
  after a warm run. Previously printed
  `~/.cache/burrito_runtime/_/pharos` (a directory Burrito never
  creates) and always reported `0 bytes`, regardless of how warm the
  real cache was. The doctor line is the operator-facing diagnostic
  for cache state, so the old output was the worst kind of cosmetic
  bug — it confidently lied.
- **`pharos --purge-cache`** actually deletes pharos's extracted
  release directories now. Previously no-op'd against the same
  phantom path while the real ~50 MB cache persisted untouched, with
  output that looked like success (`no Burrito cache at ...; exit 0`).
- **Cross-app isolation guarantee on purge:** `--purge-cache` now
  scopes its `rm -rf` to entries starting with `pharos_` under the
  shared `.burrito` root. Caches belonging to other Burrito-packaged
  tools (`next_ls_*`, etc.) are explicitly left alone. Stray
  non-directory files in the shared root also survive purge.
- **`npm/pharos-mcp/scripts/postinstall.js` `cache_root()`** now
  matches the FFI on every platform: adds a macOS branch (was falling
  through to the Linux path, so every macOS install was looking at
  the wrong dir for the cache-warmed check), and switches Windows
  from `%APPDATA%` (Roaming) to `%LOCALAPPDATA%` (Local) to match Zig
  0.13's `fs.getAppDataDir`, which is what Burrito's `wrapper.zig`
  actually calls.

### Added

- `pharos_runtime_ffi:list_pharos_extracts/0` — enumerates
  pharos-only entries under the shared Burrito root so callers can
  size/clean only this app's extracts. Honors the
  `PHAROS_INSTALL_DIR` env override (matches Burrito's
  `{UPPER_RELEASE_NAME}_INSTALL_DIR` convention from
  `deps/burrito/src/wrapper.zig`).
- Unit tests in `test/runtime_ffi_test.gleam` pinning the cache-root
  path shape (must end with `.burrito`, must not contain
  `burrito_runtime`), the `PHAROS_INSTALL_DIR` override semantics,
  the missing-root behavior (empty list, no crash), and the
  `list_pharos_extracts` filtering (accepts `pharos_*` directories,
  rejects sibling-app directories like `next_ls_*`, rejects stray
  files).
- CI grep-guard step forbidding the bug-class patterns
  `filename:basedir(user_cache, …)` and `burrito_runtime` anywhere in
  source, plus bare `process.env.APPDATA` in postinstall. Catches the
  whole fossil class on re-entry, not just the literal old strings.

### Internal

- `pharos_runtime_ffi:burrito_cache_root/0` rewritten to mirror
  Burrito's `deps/burrito/src/wrapper.zig` byte-for-byte across all
  three platforms. Platform branches use `os:type/0` directly rather
  than `filename:basedir/2`, because Erlang's `user_data` returns
  `%APPDATA%` on Windows while Zig 0.13 (and therefore Burrito) reads
  `%LOCALAPPDATA%`.
- Bumped `@version_base` (mix.exs), `gleam.toml`, the four
  `server_version` constants (src/pharos.gleam, src/pharos/cli.gleam,
  src/pharos/mcp/server.gleam, plus inline literals in
  src/pharos/smoke.gleam and src/pharos/tools/session.gleam) from
  `0.1.1` to `0.1.2`.

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

[Unreleased]: https://github.com/LoganBresnahan/pharos-mcp/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.2
[0.1.1]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.1
[0.1.0]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.0
