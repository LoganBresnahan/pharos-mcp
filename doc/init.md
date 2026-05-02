# llm_lsp_mcp — Initial Plan

A Gleam-based MCP (Model Context Protocol) server that exposes LSP (Language Server Protocol) capabilities as MCP tools. Distributed as a single self-contained binary via Burrito, shipped through GitHub Releases and npm. Optionally augmented by a thin VSCode extension that provides unsaved-buffer state.

## Vision

LLMs talk MCP. Editors talk LSP. Both speak JSON-RPC 2.0 over stdio. Nothing bridges them generically. This project is that bridge.

A user configures `llm-lsp-mcp` as an MCP server in Claude Code / Claude Desktop / Cursor / any MCP-compatible client. The binary spawns one or more LSP servers (rust-analyzer, gopls, typescript-language-server, etc.) on demand and exposes a curated set of capabilities — diagnostics, hover, goto-definition, references, symbols, refactoring previews — as typed MCP tools. The LLM gains real semantic understanding of code without the editor needing custom integration.

The same binary works for any MCP-compatible client and any LSP-compatible server. Generic by design.

A separate, optional VSCode extension (`llm_lsp_mcp_ext`) augments the binary with unsaved-buffer state. When the extension is running, the binary calls into it over local HTTP to read current editor content, workspace folders, and active selection. Without the extension, the binary reads from disk. The extension is a booster, not a requirement.

## Two repos

This project ships as two independent repositories. The binary is the primary deliverable; the extension layers on optional value.

```
github.com/<user>/llm_lsp_mcp        ← Gleam binary  (this repo)
github.com/<user>/llm_lsp_mcp_ext    ← VSCode extension  (separate repo)
```

**Why two repos:**
- Independent release cycles — extension can ship marketplace updates without binary churn
- Different ecosystems — Gleam + Mix + Burrito vs TypeScript + esbuild + vsce; monorepo would mix tooling awkwardly
- Different distribution channels — npm/GitHub Releases for binary, VSCode Marketplace + Open VSX for extension
- Different audiences — agentic CLI users want only the binary; in-IDE users add the extension
- Independent contributorship — community can build the extension later without touching binary internals

The bridge protocol between them (HTTP endpoints exposed by the extension) is specified in this repo at `doc/bridge-protocol.md` and versioned. Extension implementations consume the spec by tag.

See [adr/007-two-repo-split.md](adr/007-two-repo-split.md).

## Goals

1. **Generic LSP bridge.** Configurable by user — any language, any LSP. Not Rust-specific.
2. **Single binary distribution.** Users download, place on PATH, point MCP config at it. No runtime install (Erlang, Node, etc.).
3. **Dual distribution channels.** GitHub Releases for direct download. npm for `npx`-style MCP config.
4. **Type-safe protocol code.** Gleam's type system catches malformed messages at compile time. No runtime schema validation as the only line of defense.
5. **Standard MCP semantics.** `initialize` handshake, `tools/list`, `tools/call`, capability negotiation, content blocks.
6. **Curated, opinionated tool surface.** Hand-written, typed tools — not auto-generated from the LSP JSON Schema. Six read tools at v0.1; expand by tier.
7. **Edit-as-data.** Refactoring tools (`rename_preview`, `format_document`, `code_actions`) return `WorkspaceEdit` data, never write to disk. The LLM (or its host's file-edit tools) decides whether and how to apply.
8. **Optional editor augmentation.** A thin VSCode extension exposes unsaved-buffer state via local HTTP. Binary detects and uses it when present; falls back to disk otherwise.
9. **Configurable tool surface.** Server-side `--tools` flag and client-side per-server filtering both work — users choose how minimal the LLM-visible tool set should be.

## Non-goals (for v0.1)

- Auto-applying `WorkspaceEdit` results — LLMs use their existing file-edit tools to apply
- Real-time editor state without the extension — disk-only is the standalone fallback
- LSP completion (`textDocument/completion`) — too noisy, LLMs don't need autocomplete
- Caching, batching, performance optimization beyond correctness
- Self-updating binary — defer to post-adoption decision

## Architecture

```
                    ┌──────────────────────────────────────────────┐
                    │  MCP Client (Claude Code / Cursor / agent)   │
                    └─────────────────┬────────────────────────────┘
                                      │ stdio: NDJSON-framed JSON-RPC 2.0
                                      │  (or HTTP/SSE — same MCP spec)
                                      │
                    ┌─────────────────▼────────────────────────────┐
                    │              llm_lsp_mcp binary               │
                    │  ┌─────────────────────────────────────────┐  │
                    │  │ MCP Server                              │  │
                    │  │ - stdio + http transports               │  │
                    │  │ - initialize / tools/list / tools/call  │  │
                    │  │ - content blocks                        │  │
                    │  └────────────────┬────────────────────────┘  │
                    │                   │ tool dispatch             │
                    │  ┌────────────────▼────────────────────────┐  │
                    │  │ Tool registry (curated, typed)          │  │
                    │  │ - 6 read tools at v0.1                  │  │
                    │  │ - + lsp_request_raw escape hatch        │  │
                    │  └────────────────┬────────────────────────┘  │
                    │                   │                           │
                    │     ┌─────────────┼─────────────┐             │
                    │     │             │             │             │
                    │  ┌──▼──┐    ┌─────▼────┐  ┌─────▼─────┐       │
                    │  │ LSP │    │ Bridge   │  │ Disk read │       │
                    │  │ pool│    │ HTTP     │  │ (fallback)│       │
                    │  │     │    │ client   │  │           │       │
                    │  └──┬──┘    └────┬─────┘  └───────────┘       │
                    └─────┼────────────┼────────────────────────────┘
                          │            │ HTTP localhost
            ┌─────────────┼─┐          │ (when extension running)
            │             │ │          │
       ┌────▼──┐    ┌─────▼─▼─┐  ┌─────▼─────────────────────┐
       │ rust- │    │ gopls   │  │ llm_lsp_mcp_ext (VSCode)  │
       │ analy │    │  ...    │  │ - GET /buffer?uri=...     │
       │ -zer  │    │         │  │ - GET /workspace-roots    │
       └───────┘    └─────────┘  │ - GET /selection          │
       Content-Length framing    │ - POST /diagnostics-snap  │
                                 └───────────────────────────┘
```

### Two MCP transports

| Transport | When | Framing |
|-----------|------|---------|
| stdio | MCP host spawns binary as subprocess (default for Claude Code, Cursor MCP config) | NDJSON |
| HTTP/SSE | Network-isolated agents, web-based MCP clients, easier curl-able testing | HTTP body per MCP spec |

Both ship in v0.1. Same dispatch logic; different read/write framing modules.

### Two JSON-RPC framings, one wire format

JSON-RPC 2.0 is the wire format on every protocol surface. Only framing differs:

| Surface | Framing | Why |
|---------|---------|-----|
| MCP stdio (client → us) | NDJSON (newline-delimited) | MCP spec |
| MCP HTTP (client → us) | HTTP body | MCP spec |
| LSP (us → server) | Content-Length header (HTTP-style) | LSP spec |

JSON-RPC envelope code and dispatch logic shared. Two framing modules.

### Bridge to extension (optional)

The binary exposes no special API to the extension. Communication is one-way: binary calls extension via HTTP. Endpoints (full spec in `doc/bridge-protocol.md`):

| Endpoint | Returns | Used for |
|----------|---------|----------|
| `GET /healthz` | 200 + `{"version": "1.0"}` | Probe at startup; protocol-version handshake |
| `GET /buffer?uri=<file-uri>` | `{"text": "...", "version": 17, "isDirty": true}` | Current unsaved file content |
| `GET /workspace-roots` | `[{"uri": "...", "name": "..."}]` | Open workspace folders for `initialize` rootUri |
| `GET /selection` | `{"uri": "...", "range": {...}}` or null | Active editor cursor / selection |
| `POST /diagnostics-snapshot` body `{"uris": [...]}` | `{"uri": "...", "diagnostics": [...]}[]` | VSCode's current Problems-panel state (faster than spinning up our own LSP if the data already exists) |

Detection: binary on startup tries `GET http://127.0.0.1:<configured-port>/healthz` (port discovered via `~/.config/llm-lsp-mcp/bridge-port` or env `LLM_LSP_MCP_BRIDGE_PORT`). On failure, falls back to disk-only mode silently.

Versioning: `X-Bridge-Protocol-Version: 1` header on every request. Mismatch = log warning, fall back to disk.

See [adr/003-standalone-with-extension-bridge.md](adr/003-standalone-with-extension-bridge.md).

## Tool surface

Hand-curated, typed Gleam modules. **No** auto-generation from the LSP JSON Schema — that approach exposes ~50 noisy tools and loses Gleam's type-safety value. See [adr/006-curated-tools-no-schema.md](adr/006-curated-tools-no-schema.md).

### Tier 1 (v0.1) — must-have read tools

| Tool | LSP method | What the LLM gets |
|------|-----------|--------------------|
| `get_diagnostics` | `textDocument/publishDiagnostics` (cached) | Errors and warnings for a file |
| `hover` | `textDocument/hover` | Type signature + docs at a position |
| `goto_definition` | `textDocument/definition` | Where a symbol is defined |
| `find_references` | `textDocument/references` | All usages of a symbol |
| `document_symbols` | `textDocument/documentSymbol` | Outline of a file |
| `workspace_symbols` | `workspace/symbol` | Project-wide symbol search |

Six tools. Covers ~80% of "AI understands the codebase" scenarios. Read-only, zero mutation risk.

### Tier 2 (v0.2) — deeper read + first non-mutating writes

| Tool | LSP method | Notes |
|------|-----------|-------|
| `goto_type_definition` | `textDocument/typeDefinition` | "What's the type?" → jump to it |
| `goto_implementation` | `textDocument/implementation` | Trait → impl, interface → class |
| `signature_help` | `textDocument/signatureHelp` | Param info for an active call |
| `call_hierarchy_incoming` | `callHierarchy/incomingCalls` | Who calls this? |
| `call_hierarchy_outgoing` | `callHierarchy/outgoingCalls` | What does this call? |
| `code_actions` | `textDocument/codeAction` | Available fixes / refactorings (descriptions only) |
| `rename_preview` | `textDocument/rename` | Returns `WorkspaceEdit` — does **not** apply |
| `format_document` | `textDocument/formatting` | Returns text edits — does **not** apply |
| `lsp_request_raw` | any | Escape hatch for power users; `Dynamic`-typed |

### Tier 3 (v0.3+) — specialized

`inlay_hints`, `semantic_tokens`, `prepare_rename`, `type_hierarchy_*`. Added as user demand surfaces.

### Skipped entirely

- **`textDocument/completion`** — autocomplete is position-sensitive and noisy; LLMs don't need it
- **`documentHighlight`, `foldingRange`, `selectionRange`, `codeLens`, `documentLink`, `onTypeFormatting`** — UI concerns, not semantic data
- **`willSave*`, `didSave`** — editor lifecycle, irrelevant

### Edit-as-data philosophy

LSP "writes" don't actually mutate files — they return `WorkspaceEdit` objects describing edits. We preserve that property. Tools like `rename_preview` and `format_document` return the edit as structured content blocks (both raw JSON and a unified-diff rendering) and never touch disk. This enables exploratory flows:

- "What would renaming `parse_input` to `decode_request` touch?" → see 17 file changes, decide.
- "What does the formatter change?" → see exact whitespace adjustments before opting in.
- LLM composes edits across multiple tool calls before applying via its own file-edit tools.

For agentic clients that want auto-apply, a future `apply_workspace_edit` tool can take a returned edit and write it. Two-step is the safe default.

### Tool configurability

Both server-side and client-side filtering are supported.

**Server-side** (smaller registered surface):
```bash
llm-lsp-mcp --tools hover,goto_definition,find_references
# or
LLM_LSP_MCP_TOOLS=hover,goto_definition,find_references llm-lsp-mcp
# or in config file: tools = ["hover", "goto_definition", ...]
# or by tier:        --tools tier1
```

**Client-side** (per-MCP-host filtering):
- Claude Code: `.mcp.json` / `~/.claude/settings.json` allows tool-level enable/disable per server
- Claude Desktop: per-tool toggles in UI
- Cursor: per-server config plus individual toggles
- Generic MCP clients: spec mandates client-side filtering capability

## Tech stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Language | Gleam | Type-safe protocol code, BEAM concurrency, OTP supervisors |
| Runtime | BEAM (Erlang VM) | Actor model fits stdio + multiple LSP children naturally |
| Build | Mix + `mix_gleam` | Required by Burrito; mix.exs is config-only, all source in `.gleam` |
| JSON-RPC | `pollux` (Hex, Gleam) | Native Gleam, MCP-aware, type-parametric Request/Notification sum |
| JSON | `gleam/json` (stdlib) | Standard, sufficient |
| HTTP server | `mist` (Gleam) | For MCP HTTP transport + extension's POV is irrelevant — only binary needs HTTP server for MCP |
| HTTP client | `gleam_httpc` or `hackney` (FFI) | For bridge calls into the extension |
| Supervision | `gleam_otp` | Static + dynamic supervisors, type-checked child specs |
| Stdio I/O | `gleam/erlang` + Erlang `:io` ports | Direct stdin/stdout binary access |
| Binary packaging | Burrito | Self-extracting Zig wrapper with embedded ERTS + BEAM |
| Distribution | GitHub Releases + npm (optional-deps pattern) | Direct download for general users; `npx` for MCP-config UX |

See `adr/` for individual decisions with full context.

## Repository layout (binary repo)

```
llm_lsp_mcp/
├── mix.exs                                  # Build config (Mix + mix_gleam + Burrito)
├── mix.lock
├── gleam.toml                               # Gleam-side config (deps, project meta)
├── manifest.toml                            # Gleam dep lockfile
├── .formatter.exs
├── .gitignore
├── .tool-versions                           # asdf: erlang, elixir, gleam pins
├── README.md                                # User-facing: install, configure, contribute
├── LICENSE
│
├── src/                                     # All Gleam source
│   ├── llm_lsp_mcp.gleam                    # Library entry / facade
│   ├── llm_lsp_mcp/
│   │   ├── application.gleam                # OTP application start/2
│   │   ├── supervisor.gleam                 # Top-level supervisor tree
│   │   ├── config.gleam                     # CLI args + env + file config parsing
│   │   │
│   │   ├── mcp/
│   │   │   ├── server.gleam                 # initialize, tools/list, tools/call dispatch
│   │   │   ├── stdio.gleam                  # NDJSON framing, stdin reader, stdout writer
│   │   │   ├── http.gleam                   # MCP HTTP/SSE transport
│   │   │   ├── content_block.gleam          # MCP content-block types (text, image, resource)
│   │   │   └── capabilities.gleam           # Server/client capability declarations
│   │   │
│   │   ├── lsp/
│   │   │   ├── client.gleam                 # GenServer-equivalent: bidirectional LSP I/O
│   │   │   ├── supervisor.gleam             # DynamicSupervisor for per-language clients
│   │   │   ├── framing.gleam                # Content-Length parser/encoder
│   │   │   ├── lifecycle.gleam              # initialize, initialized, shutdown, exit
│   │   │   ├── pending.gleam                # In-flight request id → caller mapping
│   │   │   └── languages.gleam              # User-provided language → command map + per-LSP quirks
│   │   │
│   │   ├── bridge/
│   │   │   ├── client.gleam                 # HTTP client to extension; probe, fallback
│   │   │   ├── buffer.gleam                 # Buffer fetch + caching
│   │   │   └── workspace.gleam              # Workspace roots + selection
│   │   │
│   │   ├── tools/
│   │   │   ├── registry.gleam               # MCP tool name → handler dispatch + filtering
│   │   │   ├── workspace_edit.gleam         # WorkspaceEdit → content block (JSON + diff)
│   │   │   ├── tier1/
│   │   │   │   ├── diagnostics.gleam
│   │   │   │   ├── hover.gleam
│   │   │   │   ├── goto_definition.gleam
│   │   │   │   ├── find_references.gleam
│   │   │   │   ├── document_symbols.gleam
│   │   │   │   └── workspace_symbols.gleam
│   │   │   ├── tier2/                       # Added in v0.2
│   │   │   │   └── ...
│   │   │   └── raw.gleam                    # lsp_request_raw escape hatch
│   │   │
│   │   └── log.gleam                        # Structured logging to stderr (stdout reserved!)
│
├── test/
│   ├── llm_lsp_mcp_test.gleam
│   ├── mcp/
│   │   ├── stdio_test.gleam
│   │   └── http_test.gleam
│   ├── lsp/
│   │   ├── framing_test.gleam               # Content-Length parser cases (partial reads, etc.)
│   │   └── client_test.gleam
│   ├── bridge/
│   │   └── client_test.gleam                # HTTP client stub against fake extension
│   └── tools/
│       └── tier1/
│           └── diagnostics_test.gleam
│
├── npm/                                     # npm publishing artifacts
│   ├── meta/                                # Top-level "llm-lsp-mcp" package
│   │   ├── package.json
│   │   ├── bin/
│   │   │   └── llm-lsp-mcp.js               # Node shim that resolves & spawns platform binary
│   │   └── README.md
│   └── platforms/                           # Per-platform sub-packages (template, filled by CI)
│       └── README.md                        # Documents the optional-deps pattern
│
├── .github/
│   └── workflows/
│       ├── ci.yml                           # On PR: build + test on Linux/macOS/Windows
│       ├── release.yml                      # On tag push: build matrix, upload binaries, publish npm
│       └── release-please.yml               # (optional) automated changelog + version bumps
│
└── doc/
    ├── init.md                              # This file
    ├── bridge-protocol.md                   # Extension HTTP API spec (versioned)
    ├── architecture/                        # Subsystem deep-dives (added as code stabilizes)
    │   ├── mcp-server.md
    │   ├── lsp-client.md
    │   ├── stdio-framing.md
    │   ├── tool-dispatch.md
    │   └── bridge-client.md
    └── adr/
        ├── README.md
        ├── template.md
        ├── 001-language-gleam.md
        ├── 002-pollux-for-jsonrpc.md
        ├── 003-standalone-with-extension-bridge.md
        ├── 004-distribution-npm-and-releases.md
        ├── 005-mix-gleam-build-chain.md
        ├── 006-curated-tools-no-schema.md
        └── 007-two-repo-split.md
```

## Extension repo layout (sketch — lives at `llm_lsp_mcp_ext/`)

```
llm_lsp_mcp_ext/
├── package.json
├── tsconfig.json
├── esbuild.config.js
├── README.md
├── src/
│   ├── extension.ts                          # activate/deactivate, registers the bridge server
│   ├── server.ts                             # HTTP server lifecycle, port allocation
│   ├── routes/
│   │   ├── healthz.ts
│   │   ├── buffer.ts
│   │   ├── workspaceRoots.ts
│   │   ├── selection.ts
│   │   └── diagnosticsSnapshot.ts
│   └── port.ts                               # Writes ~/.config/llm-lsp-mcp/bridge-port for binary discovery
├── test/
└── .vscode/
```

The extension's job is small: bind a localhost HTTP server, expose the five endpoints from `bridge-protocol.md`, deactivate cleanly. ~200 lines of TypeScript.

## Distribution pipeline

Two channels from the same CI matrix. Each tag push produces:

1. **GitHub Release** with five binaries attached (linux-x64, linux-arm64, darwin-x64, darwin-arm64, win-x64) plus checksums.
2. **Five npm sub-packages** `@llm-lsp-mcp/<platform>-<arch>`, each containing one binary.
3. **One npm meta package** `llm-lsp-mcp` with optional dependencies pointing at all five sub-packages, plus a tiny Node shim that finds and spawns the right binary.

### npm install flow (user perspective)

```jsonc
// .mcp.json or claude_desktop_config.json
{
  "mcpServers": {
    "llm-lsp-mcp": {
      "command": "npx",
      "args": ["-y", "llm-lsp-mcp"]
    }
  }
}
```

`npx` fetches `llm-lsp-mcp`, npm resolves only the matching `@llm-lsp-mcp/<platform>-<arch>` (others marked `optional` and skipped), Node shim finds the binary inside the sub-package, spawns it with passed args, pipes stdio. Same UX as every other MCP server published on npm.

### Direct download flow

```bash
curl -L https://github.com/<user>/llm-lsp-mcp/releases/latest/download/llm-lsp-mcp-linux-x64 \
  -o ~/.local/bin/llm-lsp-mcp
chmod +x ~/.local/bin/llm-lsp-mcp
```

Then point MCP config at the absolute path instead of `npx`.

### Extension install flow

VSCode Marketplace + Open VSX (for VSCodium / Cursor). Standard `code --install-extension` or marketplace UI. Activates on workspace open, binds local HTTP, writes port to discovery file. Binary auto-detects.

See [adr/004-distribution-npm-and-releases.md](adr/004-distribution-npm-and-releases.md).

## CI/CD

### `ci.yml` — every PR / push to main

- Matrix: Linux, macOS, Windows × Erlang/OTP 27 × latest Gleam
- Steps: `mix deps.get` → `mix compile` → `mix gleam.test` → `mix format --check-formatted`
- Cache: Mix deps, Gleam build dir, Erlang/OTP install
- Burrito build is **not** run here (slow, requires Zig)

### `release.yml` — on tag push (`v*.*.*`)

Triggered by `git tag v0.1.0 && git push --tags`.

Stages (parallel where independent, sequential where dependent):

1. **Build matrix** (parallel)
   - `linux_x64`, `linux_arm64` — built on `ubuntu-latest`
   - `darwin_x64`, `darwin_arm64` — built on `macos-latest`
   - `win_x64` — cross-built from Linux (Burrito supports this)
   - Each: install Erlang + Elixir + Gleam + Zig + xz, run `MIX_ENV=prod mix release`, upload binary as artifact

2. **Aggregate** (depends on build matrix)
   - Download all five binary artifacts
   - Compute SHA256 checksums, write `checksums.txt`

3. **GitHub Release** (depends on aggregate)
   - Create draft release with tag name
   - Attach binaries + `checksums.txt`
   - Generate changelog from commits (release-please or git-cliff)
   - Promote draft to published

4. **npm publish** (depends on aggregate)
   - For each platform:
     - Copy binary into `npm/platforms/<platform-arch>/`
     - Generate `package.json` with version, `os`, `cpu`, `bin`
     - `npm publish` with `--access=public`
   - Generate meta package `package.json` with all five as `optionalDependencies` at exact version
   - `npm publish` meta package
   - All version numbers identical (= the git tag, minus `v`)

### Secrets required

| Secret | Purpose |
|--------|---------|
| `GITHUB_TOKEN` | Auto-provided; used by `softprops/action-gh-release` |
| `NPM_TOKEN` | npm publish; scoped to `@llm-lsp-mcp/*` and `llm-lsp-mcp` |

### Versioning

- Semantic versioning (semver).
- Single source of truth: git tag `v<major>.<minor>.<patch>`.
- `mix.exs`, `gleam.toml`, all `package.json` files updated by release script (or release-please).
- npm meta package's `optionalDependencies` pinned to exact version (not `^`) to ensure binary/shim version match.
- Bridge protocol versioned independently in `doc/bridge-protocol.md` (semver). Extension declares supported bridge versions in its README.

## Roadmap

### Milestone 0 — Skeleton
- Repo structure, build config, doc/adr scaffolding
- Empty Gleam modules with module-level docs
- CI green on empty project

### Milestone 1 — Stdio echo MCP server
- `initialize` handshake works against Claude Code
- `tools/list` returns one stub tool (`echo`)
- `tools/call` echoes input back
- NDJSON framing tested with partial reads

### Milestone 2 — LSP client
- Spawn rust-analyzer, send `initialize`, receive response
- Content-Length framing parses streamed responses
- Pending-request id tracking
- Receive `textDocument/publishDiagnostics` notifications, log to stderr

### Milestone 3 — First real tool: `get_diagnostics`
- User configures language → command in config file
- MCP `get_diagnostics` tool: takes URI, opens file in LSP, returns published diagnostics
- File watching for diagnostic refresh (or one-shot per call)
- Tested with rust-analyzer + gopls + tsserver

### Milestone 4 — Tier 1 tool surface complete
- `hover`, `goto_definition`, `find_references`, `document_symbols`, `workspace_symbols`
- Each maps to corresponding `textDocument/*` LSP request
- Result formatted as MCP content blocks
- `--tools` flag for server-side filtering

### Milestone 5 — MCP HTTP transport
- Add `mist`-based HTTP/SSE transport alongside stdio
- Both transports usable in same binary via flags

### Milestone 6 — Distribution
- Burrito builds locally
- GitHub Actions release workflow green
- First npm publish with optional-deps pattern
- README install instructions verified end-to-end

### Milestone 7 — Bridge protocol + extension stub
- Lock bridge protocol v1 in `doc/bridge-protocol.md`
- Binary's `bridge/client.gleam` probes localhost and uses extension when available
- Bootstrap `llm_lsp_mcp_ext` repo with healthz + buffer endpoints
- End-to-end test: edit unsaved file in VSCode, MCP `hover` returns info on unsaved content

### Milestone 8 — Tier 2 tools
- Read deep cuts: `goto_type_definition`, `goto_implementation`, `signature_help`, `call_hierarchy_*`
- Edit-as-data: `rename_preview`, `format_document`, `code_actions`
- `lsp_request_raw` escape hatch
- Unified-diff rendering for `WorkspaceEdit` content blocks

### Milestone 9 — Polish
- Config file format (TOML) for language registry
- Sensible defaults bundled (rust-analyzer, gopls, etc. auto-detected if on PATH)
- Structured logging with verbosity levels
- Telemetry events (opt-in)

### Future / maybe
- `apply_workspace_edit` tool for auto-apply use cases
- Tier 3 tools (inlay hints, semantic tokens, type hierarchy)
- Self-update inside the binary
- JetBrains plugin variant of the bridge extension
- Streaming completions (if a use case emerges)

## Open questions

1. **Config file location and format.** XDG (`~/.config/llm-lsp-mcp/config.toml`)? Per-project (`.llm-lsp-mcp.toml`)? Both? TOML vs JSON?

2. **Per-language defaults.** Bundle a default config for popular languages (rust-analyzer, gopls, tsserver, pyright, etc.)? Detection logic (check PATH on first use)?

3. **LSP lifecycle policy.** One LSP per language, kept warm for session? Spawn-per-call (slow but simple)? Idle timeout? rust-analyzer's 30s cold start makes lifecycle a real concern.

4. **Content block representation.** MCP content blocks support text/image/resource. Diagnostics → text. Hover → text or markdown? Match LSP `MarkupContent` kind?

5. **Workspace roots.** LSPs need workspace root URIs at `initialize`. From MCP client (some pass it)? CWD? Config file? Bridge endpoint when extension running?

6. **Error surfacing.** When LSP returns error or doesn't respond, do we return MCP error response, or success with embedded error message in content block? (Latter probably better for LLM consumption.)

7. **Concurrency model.** Multiple in-flight tool calls in parallel? One LSP can have many pending requests; pending tracker must support that.

8. **Bridge port discovery.** File at `~/.config/llm-lsp-mcp/bridge-port` vs env var vs both? Race conditions if two VSCode windows are open?

9. **WorkspaceEdit `documentChanges` vs `changes`.** Modern LSPs return either. Our content block format has to handle both. Renderer choice.

10. **Self-update.** Defer. But where would update metadata live (GitHub Releases API vs separate manifest)?

These get resolved into ADRs as we hit them.

## Conventions

- **Branch model:** trunk-based. Feature branches → PR → squash merge to `main`.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, etc.) — feeds release-please if we use it.
- **PRs:** small, focused. CI must be green before merge.
- **ADRs:** numbered sequentially, immutable once merged. Supersession via new ADR pointing back.
- **Tests:** every new module gets at least one `gleeunit` test. Property tests via `gleam_qcheck` for protocol parsers.
- **Logs to stderr only.** Stdout is reserved for MCP protocol traffic. A single misplaced `io.println` breaks the binary for users.
- **Bridge protocol changes:** any change requires updating `doc/bridge-protocol.md` AND bumping the protocol version in the bridge handshake. Extension repo coordinates by tagging the spec version it implements.
