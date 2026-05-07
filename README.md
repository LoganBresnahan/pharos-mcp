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

## What pharos exposes

Hand-curated MCP tools backed by real LSP analysis. Pharos drives one
or more language servers per workspace and presents typed tools to the
LLM. Bundled languages and the tools they back:

| Category | Tools | LSP method backing |
|----------|-------|---------------------|
| **read** (12) | `hover`, `goto_definition`, `goto_type_definition`, `goto_implementation`, `find_references`, `document_symbols`, `workspace_symbols`, `signature_help`, `call_hierarchy_prepare`, `call_hierarchy_incoming_calls`, `call_hierarchy_outgoing_calls`, `get_diagnostics` | `textDocument/*` queries |
| **write** (3) | `rename_preview`, `format_document`, `code_actions` | `textDocument/rename`, `textDocument/formatting`, `textDocument/codeAction` — return `WorkspaceEdit` data, never auto-apply |
| **debug** (14) | `echo` + every `runtime_*` tool: `runtime_processes`, `runtime_supervision_tree`, `runtime_ets_tables`, `runtime_memory`, `runtime_applications`, `runtime_scheduler_util`, `runtime_pid_info`, `runtime_log_tail`, `runtime_log_clear`, `runtime_log_level`, `runtime_trace_lsp`, `runtime_trace_calls`, `runtime_kill_lsp` | pharos's own BEAM introspection |
| **raw** (1) | `lsp_request_raw` | any LSP method as escape hatch |

Filter the surface via `tools = [...]` in `pharos.toml` —
[Tool filter](#tool-filter-tools--).

## Install

> **Pre-distribution caveat (M10/M13).** npm publish and the GitHub
> Releases binary matrix are scheduled for M13. The `npx` and direct-
> download channels below describe the **target UX**; today both
> resolve to "build from source" (option 3). Once M13 ships the
> binaries, options 1 and 2 become live without any user-facing
> change.

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

The path most users take **today** while options 1 and 2 are unfinished.
Requires Erlang/OTP 28, Elixir 1.19, Gleam 1.16+, rebar3 3.27+ (pinned
versions in [.tool-versions](.tool-versions); `asdf install` reads them):

```bash
git clone https://github.com/LoganBresnahan/pharos.git
cd pharos
mix archive.install --force github LoganBresnahan/mix_gleam
mix deps.get
mix compile
bin/pharos-dev --doctor       # warm + verify
```

Then point your MCP host config at the dev wrapper:

```jsonc
{
  "mcpServers": {
    "pharos": {
      "command": "/absolute/path/to/pharos/bin/pharos-dev"
    }
  }
}
```

`bin/pharos-dev` runs `mix compile` (silent → stderr) and execs Erlang
directly so stdout stays reserved for JSON-RPC frames. See
[Development](#development) for the build-system details and the
[hpack_erl naming workaround](#build-note-hpack_erl-naming-workaround).

## Language servers (install separately)

pharos does not bundle language servers. Install whichever you need;
pharos resolves them via PATH at runtime and surfaces a clear error if
a binary is missing.

| Language | Server(s) | Install |
|----------|-----------|---------|
| Rust | `rust-analyzer` | `rustup component add rust-analyzer` |
| Go | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| TypeScript / JavaScript | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
| Python | `pyright-langserver` (types/hover/goto) **+** `ruff` (formatting / lint / fixes) | `npm install -g pyright` and `pip install ruff` (or `uv tool install ruff`) |

Python uses two servers via ADR-019 method routing: pyright owns
hover, goto, types, references; ruff owns formatting, lint
diagnostics, and lint-quick-fix code actions. Both contribute to
`textDocument/codeAction` (their results merge). Either binary can be
overridden in `pharos.toml`.

Run `pharos --doctor` to verify each server resolves; output includes
the absolute path PATH lookup landed on (or a `MISSING` row plus
install hint when it didn't).

## Language registry

pharos ships a built-in registry mapping language ids to LSP commands,
file extensions, and workspace-root markers. Lookup flow per tool call:

1. Tool receives a `file:// URI`.
2. File extension is matched against the registry (`.rs` → `rust`,
   `.go` → `go`, `.ts/.tsx/.js/.jsx` → `typescript`, `.py/.pyi` →
   `python`).
3. The matched language's `command` is resolved on PATH:
   - **Bare name** (e.g. `rust-analyzer`) goes through `os:find_executable/1`,
     which searches every directory in `$PATH` in order.
   - **Absolute path** (e.g. `/opt/custom/rust-analyzer`) is used verbatim
     after a regular-file check.
4. Pharos spawns the resolved binary, drives the LSP handshake, dispatches
   the tool's underlying LSP method, returns the result.

### Bundled defaults

| id | extensions | command | workspace markers |
|----|------------|---------|-------------------|
| `rust` | `.rs` | `rust-analyzer` | `Cargo.toml`, `rust-project.json` |
| `go` | `.go` | `gopls` | `go.mod`, `go.work` |
| `typescript` | `.ts`, `.tsx`, `.js`, `.jsx` | `typescript-language-server --stdio` | `tsconfig.json`, `package.json`, `jsconfig.json` |
| `python` | `.py`, `.pyi` | `pyright-langserver --stdio` | `pyproject.toml`, `setup.py`, `setup.cfg`, `requirements.txt` |

The full default registry lives in [src/pharos/lsp/languages.gleam](src/pharos/lsp/languages.gleam) — every field
overlay-able from `pharos.toml` (see below).

### Custom paths (override a bundled language)

Common case: language server installed somewhere `os:find_executable`
won't see, or you want to pin a specific build (e.g. nightly
rust-analyzer). Drop into `~/.config/pharos/pharos.toml`:

```toml
[languages.rust]
command = "/opt/custom/rust-analyzer-nightly"

[languages.python]
command = "/Users/me/.venv/bin/pyright-langserver"
args = ["--stdio"]
```

Only fields you supply override the default — everything else
(`file_extensions`, `root_markers`, etc.) is inherited from the bundled
entry. Verify with `pharos --doctor`:

```
rust              ok     /opt/custom/rust-analyzer-nightly
python            ok     /Users/me/.venv/bin/pyright-langserver
```

### Custom paths per project

For monorepos that pin a project-specific server build, drop a
`.pharos.toml` at the project root. Pharos walks up from cwd at boot to
find it; project values beat global values:

```toml
# /workspace/myproject/.pharos.toml
[languages.python]
command = "/workspace/myproject/.venv/bin/pyright-langserver"
args = ["--stdio"]
```

### Adding a brand-new language

`command` and `file_extensions` are required; everything else has
sensible blank defaults. Example for Haskell:

```toml
[languages.haskell]
command = "haskell-language-server-wrapper"
args = ["--lsp"]
file_extensions = [".hs", ".lhs"]
root_markers = ["cabal.project", "stack.yaml", "package.yaml"]
diagnostics_mode = "push"      # or "pull" — see ADR-018
```

After the entry lands, hover/goto/etc. on a `.hs` file will spawn
`haskell-language-server-wrapper`. `pharos --doctor` will probe it
alongside the bundled languages.

### Diagnostics mode

`diagnostics_mode` controls how `get_diagnostics` retrieves data:

- `"push"` — pharos waits for the server's `textDocument/publishDiagnostics`
  notification after `didOpen`. Default. Matches rust-analyzer, gopls.
- `"pull"` — pharos sends `textDocument/diagnostic` request and reads
  the response. Required for typescript-language-server (does not push)
  and pyright when the file's diagnostic stream went idle.

When in doubt, leave the default and read the doctor output to see
what the configured server emits.

### Readiness token

`readiness_token` lets pharos drain a `$/progress` indexing notification
to the `end` state before serving the **first** request to a freshly
spawned server, eliminating the cold-start `null` failure mode. Bundled
values:

| Language | Token |
|----------|-------|
| `rust` | `rustAnalyzer/Indexing` |
| `go` | `setup` |
| `python` | `Indexing` |

Override per language if your server uses a different progress token,
or set `readiness_token = ""` to disable the wait entirely.

### Multi-server languages (ADR-019)

Each language has a list of `ServerConfig` entries declaring which LSP
methods they handle. Most languages bundle a single server with
`methods = "all"`. Python ships with two:

| Server | Scope | Owns |
|--------|-------|------|
| `pyright` | `methods = "all"` | hover, goto, references, types, signature_help, document_symbols, workspace_symbols, completion |
| `ruff` | `methods = ["textDocument/formatting", "textDocument/codeAction", "textDocument/diagnostic"]` | formatter, lint quick-fixes, import-sort, lint diagnostics |

Routing rule (per ADR-019): for each LSP method, the **first server
declaring it via `Only` wins**, otherwise the **first `All`-scope
server wins**. Methods that produce array-shaped results
(`textDocument/codeAction`, `textDocument/diagnostic`) merge results
across every claiming server — pyright's type-related quick-fixes and
ruff's lint autofixes both reach the LLM in one response.

The single-server flat-override form stays the simplest path for
swapping a primary binary path. To target a non-primary server (e.g.
ruff in python) or to layer additional servers (mypy alongside
pyright + ruff), use the array-of-tables form
`[[languages.<id>.servers]]`. Each entry merges into the default
by `id`, or appends as a new server if the id is absent:

```toml
[[languages.python.servers]]
id = "ruff"
command = "/custom/path/to/ruff"

[[languages.python.servers]]
id = "mypy"
command = "mypy"
args = ["--strict"]
methods = ["textDocument/diagnostic"]
```

Methods routing rule: a server with `methods = [...]` declares
`Only` scope (handles only the listed methods); a server without
`methods` keeps `All` scope (handles every method). For each LSP
method, Primary-strategy methods pick the first `Only` match (else
first `All`); Merge / FanOut methods consult every claiming server
and combine results.

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
