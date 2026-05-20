# pharos

MCP (Model Context Protocol) server that exposes LSP (Language Server Protocol) capabilities as MCP tools, so an LLM can ask "what's the type of this expression?", "where is this defined?", "find all references", etc., backed by real language server analysis.

Distributed as a single self-contained binary via [Burrito](https://github.com/burrito-elixir/burrito), shipped through GitHub Releases and npm. Optionally augmented by a thin VSCode extension (separate repo) that exposes unsaved-buffer state.

> **Status:** Pre-alpha, Milestone 13 (release-prep).
> Full read + write + debug + raw tool surface shipped. The M13 test
> matrix exercises every MCP tool against 22 languages on stdio + HTTP,
> dev-runtime + burrito-runtime — currently 309/312 stdio cells PASS
> (3 known LSP-side transients: gleam/scala workspace_symbols, perl
> find_references). Distribution wiring (npm publish + GH release
> matrix) is the last release blocker. See
> [doc/m13-test-plan.md](doc/m13-test-plan.md) for the matrix and
> [doc/init.md](doc/init.md) for the broader milestone plan.

## What pharos exposes

Hand-curated MCP tools backed by real LSP analysis. Pharos drives one
or more language servers per workspace and presents typed tools to the
LLM. Bundled languages and the tools they back:

| Category | Tools | LSP method backing |
|----------|-------|---------------------|
| **read** (17) | `hover`, `goto_definition`, `goto_type_definition`, `goto_implementation`, `find_references`, `document_symbols`, `workspace_symbols`, `signature_help`, `call_hierarchy_prepare`, `call_hierarchy_incoming_calls`, `call_hierarchy_outgoing_calls`, `get_diagnostics`, `inlay_hints`, `semantic_tokens`, `type_hierarchy_prepare`, `type_hierarchy_supertypes`, `type_hierarchy_subtypes` | `textDocument/*` queries |
| **write** (4) | `rename_preview`, `format_document`, `code_actions`, `apply_workspace_edit` | First three wrap `textDocument/rename` / `formatting` / `codeAction` and return `WorkspaceEdit` data only. `apply_workspace_edit` writes a `WorkspaceEdit` to disk on demand (`dry_run=true` by default; per-file atomic writes) |
| **debug** (15) | `echo` + every `runtime_*` tool: `runtime_processes`, `runtime_supervision_tree`, `runtime_ets_tables`, `runtime_memory`, `runtime_applications`, `runtime_scheduler_util`, `runtime_pid_info`, `runtime_log_tail`, `runtime_log_clear`, `runtime_log_level`, `runtime_trace_lsp`, `runtime_trace_calls`, `runtime_kill_lsp`, `runtime_language_config` | pharos's own BEAM introspection |
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
platform from the [latest release](https://github.com/LoganBresnahan/pharos-mcp/releases/latest)
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
curl -L https://github.com/LoganBresnahan/pharos-mcp/releases/latest/download/pharos-linux-x64 \
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
  -Uri https://github.com/LoganBresnahan/pharos-mcp/releases/latest/download/pharos-win-x64.exe `
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
git clone https://github.com/LoganBresnahan/pharos-mcp.git
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
| Elixir | `next-ls` (default) — alternatives: `elixir-ls` (heavier, includes dialyzer), `start_expert` (alpha; will become the official LSP) | `gh release download v0.23.4 --pattern next_ls_linux_amd64 --output ~/.local/bin/next-ls --repo elixir-tools/next-ls && chmod +x ~/.local/bin/next-ls` (Linux). macOS: `brew install elixir-tools/tap/next-ls`. To switch: pin `[languages.elixir] command = "elixir-ls"` in pharos.toml. |
| Gleam | `gleam lsp` (built into the gleam compiler) | **Currently broken upstream at gleam 1.16.** `gleam lsp` panics on stdin EOF (`Receiving LSP message: RecvError` in language-server/src/messages.rs:188). Affects every LSP host that closes stdin gracefully, not just pharos. Track at [gleam-lang/gleam](https://github.com/gleam-lang/gleam). pharos config wired and ready when upstream lands a fix. |
| Lua | `lua-language-server` (sumneko/luals) | `brew install lua-language-server` or asdf. Tarball releases at [LuaLS/lua-language-server](https://github.com/LuaLS/lua-language-server/releases). |
| Bash | `bash-language-server` | `npm install -g bash-language-server`. Diagnostics come via `shellcheck` (`apt install shellcheck` / `brew install shellcheck`); without it bash-language-server still serves hover/goto/document-symbols. |
| Ruby | `ruby-lsp` (Shopify) | `gem install ruby-lsp`. Project must have `Gemfile.lock` — run `bundle install` once before pharos can talk to the workspace. |
| Zig | `zls` | Per-zig-version. asdf: `asdf plugin add zls && asdf install zls 0.16.0 && asdf set -u zls 0.16.0`. Direct: download release matching your zig version from [zigtools/zls](https://github.com/zigtools/zls/releases). |
| C / C++ | `clangd` | `apt install clangd-18 && sudo update-alternatives --install /usr/bin/clangd clangd /usr/bin/clangd-18 100` (Linux). macOS: `brew install llvm`. clangd needs `compile_commands.json` for non-trivial projects; generate via `bear -- make` or CMake's `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`. |
| Java | `jdtls` (Eclipse JDT Language Server) | `mkdir -p ~/.local/lib/jdtls && cd ~/.local/lib/jdtls && curl -L https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz \| tar xz && ln -sf $(pwd)/bin/jdtls ~/.local/bin/jdtls && chmod +x ~/.local/bin/jdtls`. JDK 17+ required. Cold start 30-60s — pharos's initialize timeout is bumped to 90s globally to accommodate. |
| Erlang | `elp` (WhatsApp/erlang-language-platform — default) | Pre-built binaries per OTP version at [WhatsApp/erlang-language-platform](https://github.com/WhatsApp/erlang-language-platform/releases). Pick the asset matching your OTP version (`-otp-26.2`, `-otp-27.3`, `-otp-28`). Alternative: `erlang_ls` (mature, BEAM-native) — override via `[languages.erlang] command = "erlang_ls"` in pharos.toml. |
| Scala | `metals` | Coursier (NOT asdf — coursier IS the Scala polyglot manager): `curl -fL "https://github.com/coursier/coursier/releases/latest/download/cs-x86_64-pc-linux.gz" \| gunzip > ~/.local/bin/cs && chmod +x ~/.local/bin/cs && cs install metals scala-cli`. metals first-run bootstraps Bloop (~2-3 min); pharos's `[languages.scala.servers] initialize_timeout_ms = 180000` covers it. |
| Clojure | `clojure-lsp` | Native binary, no JVM cold-start. Download from [clojure-lsp releases](https://github.com/clojure-lsp/clojure-lsp/releases): `gh release download --repo clojure-lsp/clojure-lsp --pattern 'clojure-lsp-native-static-linux-amd64.zip'` then unzip to `~/.local/bin/`. Clojure runtime via asdf: `asdf plugin add clojure && asdf install clojure latest`. |
| Haskell | `haskell-language-server-wrapper` (HLS) | ghcup (NOT asdf — ghcup manages GHC/cabal/HLS version compatibility): `curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org \| sh && ghcup install ghc recommended && ghcup install hls recommended`. Heavy — full GHC install is ~1GB. |
| Perl | `pls` (FractalBoy/perl-language-server) | `cpanm PLS` (asdf-perl + cpanm). Run `asdf reshim perl` after install so the `pls` shim resolves on PATH. |
| HTML / CSS / JSON | `vscode-html-language-server`, `vscode-css-language-server`, `vscode-json-language-server` | One npm package: `npm install -g vscode-langservers-extracted`. Three LSPs in one install. |
| YAML | `yaml-language-server` | Separate npm package from the vscode bundle: `npm install -g yaml-language-server`. |
| Markdown | `marksman` | Single Rust binary. `gh release download --repo artempyanykh/marksman --pattern 'marksman-linux-x64' --output ~/.local/bin/marksman --clobber && chmod +x ~/.local/bin/marksman`. |
| Terraform / HCL | `terraform-ls` | HashiCorp hosts on `releases.hashicorp.com`, NOT GitHub Releases: `TFLS_VERSION=0.38.6 && curl -fLO "https://releases.hashicorp.com/terraform-ls/${TFLS_VERSION}/terraform-ls_${TFLS_VERSION}_linux_amd64.zip" && unzip -o terraform-ls_*_linux_amd64.zip -d ~/.local/bin/ && chmod +x ~/.local/bin/terraform-ls`. |

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
| `read` | non-mutating LSP queries (hover, goto, references, symbols, diagnostics, signature help, call/type hierarchy, inlay hints, semantic tokens) — 17 tools |
| `write` | edit-producing LSP tools (rename_preview, format_document, code_actions return `WorkspaceEdit` data; apply_workspace_edit writes one to disk) — 4 tools |
| `debug` | pharos runtime introspection (processes, supervision tree, ETS, log tail, kill_lsp, language_config, …) — 15 tools incl. `echo` |
| `raw` | power-user escape hatch (`lsp_request_raw`) — 1 tool |

Mix categories with literal tool names freely:

```toml
tools = ["read"]                       # query-only agent
tools = ["read", "write"]              # full LSP surface
tools = ["read", "runtime_log_tail"]   # category + one extra
tools = ["hover", "goto_definition"]   # fully explicit
```

Default: all categories on.

### Per-tool timeout overrides (`[tool_config.<name>]`)

Every LSP-bound tool accepts an optional `timeout_ms` argument and
has a compile-time default (`30s` for most, `60s` for
`find_references`). Override the default per-tool in TOML so heavy
workspaces don't need the LLM to pass `timeout_ms` on every call:

```toml
[tool_config.format_document]
default_timeout_ms = 90000

[tool_config.find_references]
default_timeout_ms = 120000
```

For finer control, narrow an override to one language (handy when a
single heavy LSP is the slow one):

```toml
[tool_config.find_references.java]
default_timeout_ms = 120000   # jdtls workspace-wide refs

[tool_config.workspace_symbols.go]
default_timeout_ms = 90000    # gopls fuzzy-match across stdlib
```

Resolution order (later wins):
1. Compile-time tool default
2. `[tool_config.<name>] default_timeout_ms` (global per-tool)
3. `[tool_config.<name>.<lang>] default_timeout_ms` (per-tool × per-lang)
4. Per-call `timeout_ms` argument

The `<lang>` key matches the language registry (`rust`, `python`,
`java`, etc.). Pharos classifies the call's URI by file extension to
pick which per-lang override to consult; if no override applies, the
global per-tool default takes over.

Recommended starting bumps for heavy LSPs that the M13 test matrix
regularly times out on (raise only if your workspace actually needs
the headroom):

| LSP | Tools that benefit | Suggested |
|---|---|---|
| `jdtls` (java) | `type_hierarchy_*`, `find_references`, `format_document` | 90-120s |
| `metals` (scala) | `workspace_symbols`, `inlay_hints`, `semantic_tokens`, `rename_preview` | 60-90s |
| `ruby-lsp` | `goto_*`, `call_hierarchy_prepare` | 60s |
| `perl/PLS` | `find_references`, `rename_preview` | 120-240s |
| `gopls` (big-mod) | `workspace_symbols` | 90s |
| `rust-analyzer` (monorepo) | `format_document` | 60s |

When a tool times out today the LLM sees a clear `tool timeout: LSP
did not respond in time...` message that names the
`runtime_set_tool_timeout` and per-call `timeout_ms` escape hatches —
so most tuning ends up happening in-conversation rather than in
TOML. Use TOML for durable bumps you want every session to see.

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
curl -L https://github.com/LoganBresnahan/pharos-mcp/releases/latest/download/pharos-linux-x64 \
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

## Known limitations

- **Gleam LSP (`gleam lsp`) is stability-buggy at gleam 1.16.** Two
  panic shapes surface, both `Receiving LSP message: RecvError`
  inside `language-server/src/messages.rs:188`:
  1. Stdin-close mid-drain when many requests are in flight on the
     shared connection. Mitigated by serial-mode dispatch (`gleam`
     is marked `serial_mode=True` in the test-suite); real MCP hosts
     dispatch one request at a time so this rarely surfaces in normal
     use.
  2. `workspace/symbol` requests crash gleam-lsp regardless of
     warm-up state. `workspace_symbols` is the only Tier-1 tool that
     reliably fails on gleam; every other read/write tool works.
  Both are tracked upstream; pharos requires no change once gleam
  fixes its mpsc receive handler.
- **Java cold start is 30-60s.** jdtls boots a full Eclipse JDT engine in
  Java. Pharos bumps `initialize_timeout_ms` to 90s globally to
  accommodate; faster servers (rust-analyzer, gopls, pyright, tsserver,
  next-ls) all initialize in <10s so the longer ceiling does not slow
  them down.
- **Bash diagnostics need `shellcheck`** to surface anything beyond
  syntax errors. Hover/goto/document-symbols work without it.
- **Windows is untested.** Pharos's Erlang `os:find_executable/1` should
  resolve `command = "rust-analyzer"` against `%PATH%` + `%PATHEXT%`
  on Windows the same way `which` does on Linux/macOS, and absolute
  paths in pharos.toml are accepted by Erlang on Windows. No CI
  coverage for Windows yet, so confirmed-working only on Linux/macOS
  as of M11. M13 distribution adds Windows binaries + smoke tests.
- **Windows path overrides:** prefer forward slashes
  (`C:/Users/me/.local/bin/rust-analyzer.exe`) in pharos.toml — Erlang
  accepts `/` on Windows and TOML doesn't need backslash escaping.

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

Pharos is dual-licensed.

**Open-source license**: [AGPL-3.0-only](LICENSE). Use, modify,
and self-host pharos freely under the AGPL. Network use counts
as distribution — if you operate pharos as part of a service
offered to others, you must offer the corresponding source under
the same license.

**Commercial license**: if the AGPL's terms don't work for your
deployment (e.g. you ship pharos inside a closed-source product
or operate it inside a managed-service offering where you can't
release source), a commercial license is available. See
[COMMERCIAL.md](COMMERCIAL.md).

Contributors sign a [CLA](CONTRIBUTING.md#contributor-license-agreement)
so the project can offer both license tracks. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full flow.
