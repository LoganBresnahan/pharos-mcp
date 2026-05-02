# 004. Distribution: GitHub Releases plus npm with optional-dependencies pattern

**Status:** Accepted
**Date:** 2026-05-02

## Context

The binary needs to reach users across Linux, macOS, Windows, and across MCP clients (Claude Code, Claude Desktop, Cursor, headless agents). Distribution choices affect adoption directly — friction at install time is the largest barrier for an unknown tool.

MCP clients commonly accept either a `command` path (any executable) or `npx <package>` style configs. The `npx` pattern is dominant in MCP server distribution today: `@modelcontextprotocol/server-filesystem`, `@modelcontextprotocol/server-github`, etc., all ship via npm. Users copy a one-line config snippet, npx fetches at first invocation, and the server runs.

For a Burrito-built Gleam binary (single self-extracting executable, no Node runtime), three distribution strategies were considered:

**Strategy 1 — GitHub Releases only.**
Tag triggers CI matrix building per-platform binaries, attached to a GitHub Release. Users curl the right binary, chmod, place on PATH, point MCP config at absolute path. No middleman. Familiar to CLI users; foreign to most MCP-config UX.

**Strategy 2 — npm postinstall download.**
Single npm package with a `postinstall` script that detects platform and downloads the right binary from GitHub Releases. Pros: small npm package, easy to set up. Cons: requires network at install (breaks airgapped, slow on CI), `npm install --ignore-scripts` (used by some security-conscious orgs) skips it silently, postinstall scripts are deprecated by some package managers.

**Strategy 3 — npm optional-dependencies pattern (esbuild / swc / biome / rolldown style).**
Meta package `llm-lsp-mcp` declares per-platform sub-packages as `optionalDependencies`. Each sub-package targets exactly one platform via `os` + `cpu` fields and contains exactly one binary. npm only installs the matching sub-package; others are silently skipped (that's what `optional` means in this context). Meta package's `bin` is a tiny Node shim that resolves the matching sub-package and `spawn`s its binary. No postinstall, no network at install (binaries are inside the npm packages already). Robust, fast, used in production by major projects.

Strategies are not mutually exclusive — the same CI matrix can populate both GitHub Releases and npm.

## Decision

Ship through both **GitHub Releases** and **npm using the optional-dependencies pattern**, from the same CI matrix on every tag push.

### npm structure

Six packages published per release, all at the same exact version:

| Package | Contents | `os` / `cpu` |
|---------|----------|--------------|
| `@llm-lsp-mcp/linux-x64` | one binary | linux / x64 |
| `@llm-lsp-mcp/linux-arm64` | one binary | linux / arm64 |
| `@llm-lsp-mcp/darwin-x64` | one binary | darwin / x64 |
| `@llm-lsp-mcp/darwin-arm64` | one binary | darwin / arm64 |
| `@llm-lsp-mcp/win32-x64` | one binary (.exe) | win32 / x64 |
| `llm-lsp-mcp` | Node shim + `optionalDependencies` of all five above pinned to exact version | (any) |

Meta package's `bin/llm-lsp-mcp.js`:
```javascript
#!/usr/bin/env node
const { spawn } = require('child_process')
const pkg = `@llm-lsp-mcp/${process.platform}-${process.arch}`
const ext = process.platform === 'win32' ? '.exe' : ''
const bin = require.resolve(`${pkg}/llm-lsp-mcp${ext}`)
spawn(bin, process.argv.slice(2), { stdio: 'inherit' })
  .on('exit', code => process.exit(code))
```

User config:
```json
{ "mcpServers": { "llm-lsp-mcp": { "command": "npx", "args": ["-y", "llm-lsp-mcp"] } } }
```

### GitHub Releases

Same five binaries plus `checksums.txt` attached to the tag's release. README documents the curl install path for direct download.

### Versioning

Single source of truth: git tag `vX.Y.Z`. CI release script bumps versions in `mix.exs`, `gleam.toml`, and all `package.json` files atomically. `optionalDependencies` in meta package pinned to exact version (not `^`) — binary and shim must always match.

## Consequences

**Easier:**
- `npx` UX matches every other MCP server; users have one mental model
- No postinstall, no network at install — works offline once npm cache is warm
- Power users (CI, headless, custom paths) use GitHub Releases unchanged
- Same CI matrix produces both — no duplicate build pipeline

**Harder:**
- Six npm packages to publish per release. Slightly more pipeline complexity.
- Cross-compile to Windows from Linux is a Burrito feature, but ARM64 macOS from x86_64 macOS may need an Apple Silicon GitHub runner.
- npm scope `@llm-lsp-mcp/*` must be claimed and configured. `NPM_TOKEN` must have publish permission on the scope.
- Version drift between meta package and a sub-package would silently break — exact pinning prevents this but means we cannot release just the meta package or just one sub-package.

**Living with:**
- Burrito binaries are ~30-50MB each (ERTS + BEAM + app). Across five platforms, that's ~150-250MB per release in the npm registry. Within reasonable npm package sizes (esbuild's binaries are similar).
- npm cold start: `npx -y llm-lsp-mcp` first-time fetch is slower than `cargo install` style. Subsequent runs are fast (cached).
- Burrito self-extract on first run adds ~1s. Users see a one-time delay; then it's fast.

## Alternatives considered

- **Strategy 1 alone (releases only)** — friction for typical MCP users who expect `npx` to work. We'd cede the npm UX to lsp-mcp and similar.
- **Strategy 2 (postinstall download)** — works but fragile. Skipped due to `--ignore-scripts` and offline-install issues.
- **Homebrew tap** — possible follow-on for macOS/Linux users who prefer brew. Defer; npm + Releases covers ~95% of users.
- **OS package managers (apt / dnf / scoop)** — multiplies maintenance for marginal gain. Not in v0.1 scope.
- **Container image (Docker / OCI)** — `jonrad/lsp-mcp` does this. Works but adds Docker dependency. Out of scope; stdio-via-Docker is awkward for MCP config.
