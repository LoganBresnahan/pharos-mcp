# pharos

MCP (Model Context Protocol) server that exposes LSP (Language Server Protocol) capabilities as MCP tools, so an LLM can ask "what's the type of this expression?", "where is this defined?", "find all references", etc., backed by real language server analysis.

Distributed as a single self-contained binary via [Burrito](https://github.com/burrito-elixir/burrito), shipped through GitHub Releases and npm. Optionally augmented by a thin VSCode extension (separate repo) that exposes unsaved-buffer state.

> **Status:** Pre-alpha, Milestone 10 (pre-distribution polish).
> Tier 1 + Tier 2 tools complete (hover, goto, references, document/workspace
> symbols, signature help, call hierarchy, rename preview, format, code
> actions, diagnostics, raw passthrough), runtime introspection tier
> shipped, four languages (rust / go / typescript / python) bundled.
> Distribution wiring (npm publish + GH release matrix) lands in M13.
> See [doc/init.md](doc/init.md) for the milestone plan.

## Install

Three channels, in order of recommended UX. **All produce the same
`pharos` binary**; pick whichever fits your workflow.

### 1. npm via `npx` (recommended — works on every platform)

Add this to your MCP host's config (`.mcp.json`, `claude_desktop_config.json`,
Cursor's per-server config, etc.):

```jsonc
{
  "mcpServers": {
    "pharos": {
      "command": "npx",
      "args": ["-y", "pharos"]
    }
  }
}
```

`npx` fetches the meta package; npm resolves only the matching
`@pharos/<platform>-<arch>` sub-package and skips the others. Node shim
inside spawns the binary with stdio piped. Cross-platform out of the box
(Linux / macOS / Windows / WSL).

After install, **warm the Burrito extract cache** so the first MCP host
spawn does not pay cold-extract latency (~1–3s):

```bash
npx pharos --doctor
```

### 2. Direct download from GitHub Releases

For users who prefer not to depend on Node. Pick the binary for your
platform from the [latest release](https://github.com/LoganBresnahan/pharos/releases/latest)
and place it on PATH.

| OS / arch | Recommended install path | On default PATH? |
|-----------|---------------------------|------------------|
| Linux x86_64 | `~/.local/bin/pharos` | yes (XDG; bash & zsh ship it) |
| Linux aarch64 | `~/.local/bin/pharos` | yes |
| macOS x86_64 (Intel) | `~/.local/bin/pharos` or `/usr/local/bin/pharos` | yes |
| macOS aarch64 (Apple Silicon) | `~/.local/bin/pharos` | yes |
| Windows x86_64 | `%LOCALAPPDATA%\Programs\pharos\pharos.exe` | needs PATH addition (see below) |
| WSL | same as Linux (it IS Linux) | yes |

Linux / macOS:
```bash
mkdir -p ~/.local/bin
curl -L https://github.com/LoganBresnahan/pharos/releases/latest/download/pharos-linux-x64 \
  -o ~/.local/bin/pharos
chmod +x ~/.local/bin/pharos

# Verify + warm the cache
pharos --doctor
```

Replace `linux-x64` with your target: `linux-arm64`, `darwin-x64`,
`darwin-arm64`. For Windows, download `pharos-win-x64.exe` to
`%LOCALAPPDATA%\Programs\pharos\pharos.exe` and add that directory to
your `Path` user environment variable:

```powershell
$dir = "$env:LOCALAPPDATA\Programs\pharos"
New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest `
  -Uri https://github.com/LoganBresnahan/pharos/releases/latest/download/pharos-win-x64.exe `
  -OutFile "$dir\pharos.exe"
[Environment]::SetEnvironmentVariable(
  "Path", "$env:Path;$dir", "User"
)

# Restart your terminal so PATH refreshes, then verify + warm:
pharos --doctor
```

If `~/.local/bin` is not in your PATH, add it:

```bash
# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
# zsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Then point your MCP host config at the absolute path:

```jsonc
{
  "mcpServers": {
    "pharos": {
      "command": "/home/<you>/.local/bin/pharos"
    }
  }
}
```

### 3. Build from source

See [Development](#development) below. Use this only when iterating on
pharos itself.

## Language servers (install separately)

pharos does not bundle language servers. Install whichever you need;
pharos resolves them via PATH at runtime, with a clear error if missing.

| Language | Server | Install |
|----------|--------|---------|
| Rust | `rust-analyzer` | `rustup component add rust-analyzer` |
| Go | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| TypeScript / JavaScript | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
| Python | `pyright-langserver` | `npm install -g pyright` |

Override the resolved binary path per language in `~/.config/pharos/pharos.toml`:

```toml
[languages.rust]
command = "/opt/custom/rust-analyzer-nightly"
```

Run `pharos --doctor` to verify each server resolves on PATH.

## Configuration

pharos reads configuration in this precedence order (later wins):

1. Compiled-in defaults (no config required)
2. `~/.config/pharos/pharos.toml` — global per-user
3. `./.pharos.toml` — per-project; walked up from the cwd pharos was launched in
4. `PHAROS_*` environment variables — final override

To start customising, dump the canonical TOML with comments:

```bash
mkdir -p ~/.config/pharos
pharos --print-default-config > ~/.config/pharos/pharos.toml
$EDITOR ~/.config/pharos/pharos.toml
```

The full schema lives in [doc/example-pharos.toml](doc/example-pharos.toml).

### Tool filter (`tools = [...]`)

Four categories cover every MCP tool pharos exposes:

| Category | Members |
|----------|---------|
| `read` | non-mutating LSP queries (hover, goto, references, symbols, diagnostics, signature help, call hierarchy) — 12 tools |
| `write` | edit-producing LSP tools that return `WorkspaceEdit` data (rename_preview, format_document, code_actions) — 3 tools |
| `debug` | pharos runtime introspection (processes, supervision tree, ETS, log tail, kill_lsp, …) — 14 tools incl. `echo` |
| `raw` | power-user escape hatch (`lsp_request_raw`) — 1 tool |

Mix categories with literal tool names freely:

```toml
tools = ["read"]                       # query-only agent
tools = ["read", "write"]              # full LSP surface
tools = ["read", "runtime_log_tail"]   # category + one extra
tools = ["hover", "goto_definition"]   # fully explicit
```

Default: all categories on.

## CLI flags

pharos has no runtime-configuration CLI flags — every knob lives in
TOML or `PHAROS_*` env vars. Flags are limited to operational meta
commands.

| Flag | What it does |
|------|--------------|
| `--version`, `-V` | Print version and exit. |
| `--help`, `-h` | Print usage and exit. |
| `--print-default-config` | Print the canonical pharos.toml starter file with comments. |
| `--doctor` | Self-diagnostic. Resolves Config the same way a normal boot does, probes each language server's binary on PATH, reports anything that would break. Doubles as a Burrito-cache warmup — run once after install so the first MCP host spawn is fast. |
| `--purge-cache` | Remove Burrito's extracted ERTS+BEAM payload at `<user_cache>/burrito_runtime/_/pharos/`. Next run re-extracts (~1–3s). Does **not** remove the binary itself or your config files. |

## Updating

There is no `--update` flag. Use the channel-appropriate recipe:

```bash
# npm install
npm update -g pharos

# Direct download (replace the platform suffix)
curl -L https://github.com/LoganBresnahan/pharos/releases/latest/download/pharos-linux-x64 \
  -o ~/.local/bin/pharos
chmod +x ~/.local/bin/pharos

# After update, recommended:
pharos --purge-cache       # clear stale Burrito extract from prior version
pharos --doctor            # warm fresh cache + re-verify
```

## Uninstalling

```bash
pharos --purge-cache              # remove Burrito's extracted payload

# Then per channel:
npm uninstall -g pharos           # if installed via npm
rm ~/.local/bin/pharos            # if installed via direct download

# Optional cleanup:
rm -rf ~/.config/pharos           # config files (TOML + language registry)
rm -rf ~/.cache/pharos            # log files
```

## Why?

LLMs talk MCP. Editors talk LSP. Both already speak JSON-RPC 2.0 over stdio. Nothing bridges them generically. This project is that bridge. See [doc/init.md](doc/init.md) for the full vision.

## Documentation

- [doc/init.md](doc/init.md) — vision, architecture, repo layout, distribution pipeline, roadmap
- [doc/adr/](doc/adr/) — accepted Architecture Decision Records (language, JSON-RPC library, distribution, build chain, etc.)
- [doc/bridge-protocol.md](doc/bridge-protocol.md) — local HTTP API the optional VSCode extension exposes (forthcoming)

## Development

Requires Erlang/OTP 28, Elixir 1.19, Gleam 1.16+, rebar3 3.27+. Pinned versions in [.tool-versions](.tool-versions) (`asdf install`).

```bash
# One-time: install the Gleam compiler archive (LoganBresnahan/mix_gleam fork —
# tracks Elixir 1.15+ and Gleam 1.x; upstream gleam-lang/mix_gleam is dormant
# and pinned to Gleam pre-1.0 on Hex).
mix archive.install --force github LoganBresnahan/mix_gleam

mix deps.get                             # fetches Hex dependencies (Gleam + Elixir)
mix compile                              # compiles Gleam → BEAM via mix_gleam
mix gleam.test                           # runs gleeunit tests
mix start                                # runs the stdio MCP server (reads stdin, writes stdout)
```

### Smoke-testing the stdio server

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}' \
  | mix start
```

Expected: three JSON-RPC responses on stdout (initialize → tools/list → tools/call echo), with `[info]` log lines on stderr. The notification line produces no response, by spec.

### Wiring as a real MCP server

`mix start` is fine for the smoke test above (where stdout is captured into a variable), but it cannot be used directly as an MCP server `command` because Mix prints compile progress to stdout, corrupting the JSON-RPC stream. Two ways to wire pharos as a real MCP server:

**Burrito binary (recommended, M6 path).** Build once, then point your MCP host at the resulting binary:

```bash
MIX_ENV=prod mix release   # produces burrito_out/pharos_<target>
```

```json
{
  "mcpServers": {
    "pharos": {
      "command": "/absolute/path/to/pharos/burrito_out/pharos_linux_x64"
    }
  }
}
```

The binary is self-contained (Erlang runtime included), produces only JSON-RPC frames on stdout, and routes logger output to stderr. M10 ships pre-built binaries via GitHub Releases; until then, build locally.

**Dev wrapper (`bin/pharos-dev`).** Bash wrapper that compiles silently (all output to stderr) then boots Erlang directly. Useful while iterating on Gleam code because it picks up edits without a release rebuild:

```json
{
  "mcpServers": {
    "pharos": {
      "command": "/absolute/path/to/pharos/bin/pharos-dev"
    }
  }
}
```

Restart the host (or use its MCP reconnect command) after changing config. Once registered, the LLM has tools named `mcp__pharos__<tool>` available.

**Naming convention recap.** The config key (`pharos`) is arbitrary but conventionally matches the BEAM identifier and repo directory. The binary's executable filename (`pharos`) and npm package name (`pharos`) use hyphens because their respective ecosystems require it (Unix CLI tradition; npm package-naming rule). Stay underscored on the BEAM side, hyphenated on the distribution-channel side.

For binary builds (requires Zig 0.15.2 + xz, see [Burrito's setup notes](https://github.com/burrito-elixir/burrito#preparation-and-requirements)):

```bash
MIX_ENV=prod mix release                 # produces Burrito binaries in burrito_out/
```

`MIX_ENV=prod mix release` produces multi-target binaries (`pharos_linux_x64`, `pharos_linux_arm64`, `pharos_darwin_x64`, `pharos_darwin_arm64`). Windows requires `7z`/`7zz` on PATH; without it that target is skipped (other targets still build).

### Build note: hpack_erl naming workaround

`mix.exs` runs a `fix_app_names` hook after `deps.compile` to work around a hex-package-name vs OTP-application-name mismatch in `hpack_erl` (transitive via `mist`). The hook writes a wrapper `<hex_name>.app` so Mix's `validate_app/1` filename check passes; runtime behavior is unaffected. See [doc/adr/011-mix-app-name-symlink-workaround.md](doc/adr/011-mix-app-name-symlink-workaround.md). Removed when the upstream Gleam publish fix lands and `mist` republishes against it.

## Companion repos

- [pharos_ext](https://github.com/LoganBresnahan/pharos_ext) — optional VSCode extension (bootstrapped separately)

## License

MIT — see [LICENSE](LICENSE).
