# pharos — Initial Plan

A Gleam-based MCP (Model Context Protocol) server that exposes LSP (Language Server Protocol) capabilities as MCP tools. Distributed as a single self-contained binary via Burrito, shipped through GitHub Releases and npm. Optionally augmented by a thin VSCode extension that provides unsaved-buffer state.

## Vision

LLMs talk MCP. Editors talk LSP. Both speak JSON-RPC 2.0 over stdio. Nothing bridges them generically. This project is that bridge.

A user configures `pharos` as an MCP server in Claude Code / Claude Desktop / Cursor / any MCP-compatible client. The binary spawns one or more LSP servers (rust-analyzer, gopls, typescript-language-server, etc.) on demand and exposes a curated set of capabilities — diagnostics, hover, goto-definition, references, symbols, refactoring previews — as typed MCP tools. The LLM gains real semantic understanding of code without the editor needing custom integration.

The same binary works for any MCP-compatible client and any LSP-compatible server. Generic by design.

A separate, optional VSCode extension (`pharos_ext`) augments the binary with unsaved-buffer state. When the extension is running, the binary calls into it over local HTTP to read current editor content, workspace folders, and active selection. Without the extension, the binary reads from disk. The extension is a booster, not a requirement.

## Two repos

This project ships as two independent repositories. The binary is the primary deliverable; the extension layers on optional value.

```
github.com/<user>/pharos        ← Gleam binary  (this repo)
github.com/<user>/pharos_ext    ← VSCode extension  (separate repo)
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
                    │              pharos binary               │
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
       │ rust- │    │ gopls   │  │ pharos_ext (VSCode)  │
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

Detection: binary on startup tries `GET http://127.0.0.1:<configured-port>/healthz` (port discovered via `~/.config/pharos/bridge-port` or env `PHAROS_BRIDGE_PORT`). On failure, falls back to disk-only mode silently.

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
pharos --tools hover,goto_definition,find_references
# or
PHAROS_TOOLS=hover,goto_definition,find_references pharos
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
pharos/
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
│   ├── pharos.gleam                    # Library entry / facade
│   ├── pharos/
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
│   ├── pharos_test.gleam
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
├── npm/                                     # npm publishing artifacts (M11 scaffold;
│   │                                          M13 splits into meta + per-platform sub-pkgs)
│   ├── package.json                         # `pharos-mcp` — single-pkg scaffold today
│   ├── bin/
│   │   └── pharos.js                        # Node shim that resolves & spawns platform binary
│   ├── scripts/
│   │   └── postinstall.js                   # Burrito-cache warmup (avoids 50s cold-start
│   │                                          blowing past MCP host's 30s connect timeout)
│   ├── vendor/                              # Burrito binaries; gitignored, filled by CI
│   └── README.md
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

## Extension repo layout (sketch — lives at `pharos_ext/`)

```
pharos_ext/
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
│   └── port.ts                               # Writes ~/.config/pharos/bridge-port for binary discovery
├── test/
└── .vscode/
```

The extension's job is small: bind a localhost HTTP server, expose the five endpoints from `bridge-protocol.md`, deactivate cleanly. ~200 lines of TypeScript.

## Distribution pipeline

Two channels from the same CI matrix. Each tag push produces:

1. **GitHub Release** with five binaries attached (linux-x64, linux-arm64, darwin-x64, darwin-arm64, win-x64) plus checksums.
2. **Five npm sub-packages** `@pharos/<platform>-<arch>`, each containing one binary.
3. **One npm meta package** `pharos` with optional dependencies pointing at all five sub-packages, plus a tiny Node shim that finds and spawns the right binary.

### npm install flow (user perspective)

```jsonc
// .mcp.json or claude_desktop_config.json
{
  "mcpServers": {
    "pharos": {
      "command": "npx",
      "args": ["-y", "pharos"]
    }
  }
}
```

`npx` fetches `pharos`, npm resolves only the matching `@pharos/<platform>-<arch>` (others marked `optional` and skipped), Node shim finds the binary inside the sub-package, spawns it with passed args, pipes stdio. Same UX as every other MCP server published on npm.

### Direct download flow

```bash
curl -L https://github.com/<user>/pharos/releases/latest/download/pharos-linux-x64 \
  -o ~/.local/bin/pharos
chmod +x ~/.local/bin/pharos
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
| `NPM_TOKEN` | npm publish; scoped to `@pharos/*` and `pharos` |

### Versioning

- Semantic versioning (semver).
- Single source of truth: git tag `v<major>.<minor>.<patch>`.
- `mix.exs`, `gleam.toml`, all `package.json` files updated by release script (or release-please).
- npm meta package's `optionalDependencies` pinned to exact version (not `^`) to ensure binary/shim version match.
- Bridge protocol versioned independently in `doc/bridge-protocol.md` (semver). Extension declares supported bridge versions in its README.

## Roadmap

**Working order (post-M9.5 dogfood):** M10 → M11 → (M12 or M7) → M13. M7 (bridge protocol + reference editor) is parked until owner picks it up; M12 (more languages) and M7 are interchangeable in priority. M13 (public distribution) gates on M10 polish and at least the Tier-1 of M12 coverage. Milestone numbering stays sequential (no renumbering even though M7 may execute after M12) so existing ADR references and commit history remain stable.

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

### Milestone 6 — Dogfood binary (local-only, not published)
- Patch `mix_gleam` fork to env-gate `test/` compilation so `MIX_ENV=prod mix release` succeeds (gleeunit `should` module is dev-only)
- Burrito wraps a single host-target binary locally (e.g. `linux_x64`)
- MCP host config (`~/.claude.json`) points at the Burrito-built binary instead of `bin/pharos-dev`
- Smoke-tested end-to-end: `initialize` → `tools/list` → `tools/call` against a real workspace
- Multi-target matrix, GH Actions, and npm publishing are explicitly out of scope here — they live in M10. M6 is about validating the wrapped binary works as a daily-driver MCP server, not shipping it to anyone else.

### Milestone 7 — Bridge protocol + reference editor implementation
- Lock bridge protocol v1 in `doc/bridge-protocol.md` as an **editor-neutral** spec (HTTP localhost, version handshake, port discovery, endpoints `/healthz`, `/buffer`, `/workspace-roots`, `/selection`, `/diagnostics-snapshot`). Any editor with HTTP server support can implement it. VSCode is the first concrete consumer, not the only intended one.
- Binary's `bridge/client.gleam` probes localhost and uses whichever editor implementation is bound, agnostic to which editor it is
- Bootstrap `pharos_ext` repo as the **VSCode reference implementation** of the spec
- End-to-end test: edit unsaved file in VSCode, MCP `hover` returns info on unsaved content
- Open design questions captured in the spec doc itself: port discovery mechanism (extends open question 8), multi-editor conflict resolution when two editor windows bind the same workspace, auth model (token vs localhost-only trust), push-vs-pull (does the editor get to *push* file-saved / buffer-changed events, or stay pure-pull from the binary?)

### Milestone 8 — Tier 2 tools

**Stage 0 (gating prerequisite) — bidirectional LSP server-request handling.** Must land before any Tier 2 tool code. See [adr/010-defer-server-request-handling.md](adr/010-defer-server-request-handling.md).
- Convert `lsp/lifecycle.gleam`'s inbound loop into a classifier (response by id / notification / server-request)
- Server-request handler registry keyed by method, with default handlers for `workspace/configuration`, `client/registerCapability`, `client/unregisterCapability`, `window/showMessageRequest`, `window/workDoneProgress/create`, `workspace/applyEdit`
- Per-language post-`initialized` push hook for `workspace/didChangeConfiguration` (and any server-specific config). Add `workspace_configuration: Option(Json)` to `LanguageConfig`; populate for typescript-language-server.
- Per-tool handler override surface (e.g. `rename_preview`'s `workspace/applyEdit` policy)
- HTTP transport stateful sessions: `Mcp-Session-Id` header issued at `initialize`, validated on every subsequent request, used to route server-initiated requests to the originating client. Deferred from M5 because Tier 1 is pure request/response with no server-push; Stage 0 makes the first server-initiated request real (`workspace/applyEdit`) and HTTP needs an addressable client to deliver it to. Includes idle session eviction policy.
- Fixes deferred tsserver `get_diagnostics` as a side effect — verify in dogfood before moving on

**Stage 1 — Tier 2 tools.**
- Read deep cuts: `goto_type_definition`, `goto_implementation`, `signature_help`, `call_hierarchy_*`
- Edit-as-data: `rename_preview`, `format_document`, `code_actions`
- `lsp_request_raw` escape hatch
- Unified-diff rendering for `WorkspaceEdit` content blocks

**Stage 2 — Reliability sweep for known issues.** First pass shipped 7 fixes (commits 741de45 through 9a5c280); per-language dogfood across rust/go/ts/py rust_dev/go_dev/typescript_dev/python_dev surfaced the next round below. Each is logged to stderr (via `pharos/log`) when it fires so post-mortem is possible without LLM-side reproduction.

Closed by Stage 2 first pass:
- ClientCapabilities advertisement (#1) — fixed `signature_help`, `code_actions`; verified across rust/go/ts/py
- `goto_implementation` clipping (#2) — `limit` arg with 50 default
- tsserver `workspace_configuration` (#3) — caught type-error on first invocation
- `find_references` 60s default + caller override (#4)
- `call_hierarchy` incoming + outgoing typed wrappers (#5) — verified across rust/go/ts/py
- `wait_for_ready` two-phase begin-state-seen (#6)
- SSE heartbeat re-arm (#7) — verified two heartbeats over 35s

Open items for Stage 2 second pass (post-M9-Phase-A):

- **`format_document` against rust-analyzer still errors.** **CLOSED** in commit `dd0da71` (fix(2-2.A): format_document timeout 30s + pyright doc). Default bumped to 30s, `timeout_ms` arg exposed.
- **`format_document` against pyright returns `-32601 Unhandled method`.** **CLOSED** in commit `dd0da71`. Tool description now states pyright does not implement formatting + recommends ruff/black/yapf externally.
- **`workspace_symbols` against gopls floods with stdlib hits.** **CLOSED** in M11 dogfood Run 5 (line 360 `doc/dogfood.md`): `limit` cap clip working as designed; gopls fuzzy-matches across stdlib but truncation marker engages cleanly.
- **`get_diagnostics` is fragile across all four languages.** **CLOSED** in M11 (D-M11-3 fix): publishDiagnostics cache + Pull-mode via `textDocument/diagnostic` where supported, byte-based merge across multi-LSP servers (ADR-019).
- **Cold-cache LSP transport errors on first call.** **CLOSED** in M9 Phase C transparent retry wrapper.
- **Pool does not auto-evict crashed LSPs.** **CLOSED** in M9 Phase B — pool now monitors each `lsp_proc` and auto-evicts on DOWN.
- **gopls regression after M9 Phase B.** **CLOSED** by M9.5/M10 work — Run 5 (M11 dogfood) has gopls passing all 12/12 Tier 1 + cold-spawn via PATH lookup verified.

Tool errors continue to log to stderr globally via `mcp/server.tool_text_result/2`. Any new failure mode added during M9 lands in this log automatically.

### Milestone 9 — Polish + BEAM fault tolerance
- Real supervisor tree (`pharos@supervisor` + `pharos/lsp/supervisor`); root one_for_one over pool subtree, sessions actor, transport subtree. See ADR-013 (forthcoming).
- `lsp_proc` per-LSP worker module: owns the Erlang Port, hosts request id correlation, server-request handler dispatch, `$/progress` tracking, restart under `lsp_dyn_sup`.
- Pool monitors each `lsp_proc` via `process.monitor`; auto-evicts cache on DOWN. Belt-and-suspenders with the supervisor's own restart policy.
- Transparent retry-on-transport-error wrapper at the tool layer. Transient LSP crashes become invisible after one restart.
- `$/cancelRequest` propagation: when the MCP client cancels (`notifications/cancelled`), forward to the LSP.
- `PHAROS_HTTP_PORT=0` auto-assign — let the OS pick a free TCP port. Pharos logs the bound port to stderr via mist's `after_start` hook so headless callers can discover it without coordination.
- Multi-root rust-analyzer workspace support (open question 5) — supply multiple `rootUri` to one server when files from sibling crates participate.
- Config file format (TOML) for language registry
- Sensible defaults bundled (rust-analyzer, gopls, etc. auto-detected if on PATH)
- Structured logging with verbosity levels
- Telemetry events (opt-in)

### Milestone 9.5 — BEAM runtime introspection + structured logging/tracing

Two related layers landing together because the runtime introspection tools depend on the logging layer's ring buffer for `runtime_log_tail`.

#### Part A — Structured logging + sinks

Replace `pharos/log.gleam`'s `io.println_error` wrappers with a real logger:

- `Level = Debug | Info | Warn | Error`
- `log(level, msg, fields: List(#(String, String)))` — `fields` are key=value pairs for filtering and human reading
- Per-tool-call **correlation id** (the MCP request id) threaded through every log line emitted during that call's flow, so `runtime_log_tail` filtered by id reconstructs one tool's conversation
- `RUST_LOG`-style env-var filter: `PHAROS_LOG=info,pharos/lsp/proc=debug,pharos/lsp/trace=off`. Default `info`.

Sinks (configurable, fan-out via one ETS-backed broadcaster):

- `:stderr` (default; what we have today)
- `:ring_buffer` — bounded in-memory deque (default 1000 lines, ~256kb cap) feeding `runtime_log_tail`
- `:file` — rotating file at `~/.cache/pharos/log/pharos-<date>.log`, size-rotated at 10MB, kept for 7 days
- `:both` — fan out to multiple sinks

Implementation: one Gleam log-writer actor receives `LogEntry` messages and forwards to each registered sink. Existing `log.info / log.warn / log.error` calls keep their shapes (back-compat); new `log.with_fields(level, msg, fields)` for richer entries.

#### Part B — LSP traffic tracer

`pharos/lsp/trace.gleam` wraps `port.send` and `port.receive_data` with a debug-level log line per direction:

- `direction=out|in`, `bytes=N`, `body=<full|truncated>`
- Off by default (filter excludes `pharos/lsp/trace`)
- Toggle on via `PHAROS_TRACE_LSP=1` env var globally, OR per-language via a `trace: Bool` field in `LanguageConfig`, OR runtime via `runtime_trace_lsp` MCP tool (Part C below)
- Sensitive-data caveat: traces capture file content of in-buffer documents; redaction is hard, document expectation that traces are dev-only

This is the layer landing first to diagnose the M9 Phase B gopls regression — see exactly what bytes flow each direction during the failing handshake/request.

#### Part C — MCP tools exposing all of the above (Tier 4)

BEAM observer-equivalent state as MCP tools so the LLM can debug pharos itself without leaving the chat surface. Pattern matches existing tools: typed Gleam wrappers over `:erlang.*` / `:ets.*` BIFs, registered-name-first to avoid raw-pid leak across restarts, output clipped via the existing `pharos/tools/clip` helper.

Read-only first batch:
- `runtime_processes` — `[{pid, registered_name, current_function, message_queue_len, memory}]` clipped to N
- `runtime_supervision_tree` — walk root supervisor, render as nested object
- `runtime_ets_tables` — list public ETS tables + sizes (pharos_diagnostics_cache visible)
- `runtime_memory` — `:erlang.memory()` breakdown (total, processes, atom, binary, ets)
- `runtime_applications` — `application:which_applications()`
- `runtime_scheduler_util` — `scheduler:utilization(1)` snapshot
- `runtime_pid_info(pid_text)` — full `process_info/1` for a single pid

Logging + tracing tools (depend on Part A's ring buffer + Part B's tracer):
- `runtime_log_tail(n, filter?)` — read last N lines from the ring buffer, optional substring filter
- `runtime_log_clear` — reset ring buffer
- `runtime_log_level(target, level)` — runtime-adjust verbosity (e.g. crank `pharos/lsp/proc` to debug for the duration of a debugging session)
- `runtime_trace_lsp(language, duration_ms)` — turn the tracer on for one LSP for a fixed window, return the captured trace lines

Scoped destructive (always available, safe by design):
- `runtime_kill_lsp(language, workspace)` — terminate one LSP via `pool.kill_lsp` → `supervisor.terminate_child(lsp_dyn_sup, pid)`. The pool evicts the cache entry; next tool call to the same key spawns a fresh worker via the standard cache-miss path. Cannot kill anything other than supervised LSP workers.

Powerful tracing (gated behind `PHAROS_RUNTIME_TRACE_ENABLED=1`):
- `runtime_trace_calls(module, function?, duration_ms, max_events)` — thin Gleam wrapper over `recon_trace.calls/2`. recon enforces max-events trip, time-limit trip, and automatic `:dbg` cleanup. Handler hard-caps `duration_ms` at 30000 and `max_events` at 5000, refuses to trace specific hot modules (`erlang`, `ets`, `gleam@otp@actor`, `gleam@erlang@process`), and wraps the body in `try ... after :recon_trace.clear() end` so any crash path still removes BEAM trace flags.

Cut from scope (see ADR-014):
- `runtime_kill_pid` — no use case `runtime_kill_lsp` does not cover; raw kill of arbitrary BEAM pids has too many ways to break the system in ways the LLM cannot recover from.
- Raw `:dbg`-based `runtime_trace_module` — superseded by `runtime_trace_calls` via recon.

Risks captured in ADR-014:
- Pid serialization stability across restarts (use names where possible; pids text-only)
- Output volume on busy nodes (clip at 100 processes default, raise via `limit`)
- Distributed-Erlang multi-node observer is out of scope (pharos is single-node)
- Trace hooks have side effects on scheduler; document timeouts + auto-stop
- Correlation id propagation across actors requires threading through `proc.request`'s call chain — small refactor lands alongside Part A
- Ring buffer is volatile (lost on BEAM exit); the file sink is the persistent one for post-mortem

### Milestone 10 — Pre-distribution polish

The dogfood-driven cleanup that has to happen before strangers ever see pharos. M9.5 dogfood (Run 2 in `doc/dogfood.md`) surfaced the items below. Distribution itself moves to M13 — a stranger hitting any of the items below would form an immediate negative impression and the ones we already know about must close before tag-push.

**Release-blocker dogfood follow-ups (from `doc/dogfood.md` Run 2):**

- **README — language/binary install table.** rust-analyzer / gopls / typescript-language-server / pyright-langserver / ruff with per-platform install commands. Extends ADR-018. Pharos does not bundle servers; users install per the table.
- **Missing-binary negative path.** Strip PATH, hover a `.rs` file, expect `language server binary 'rust-analyzer' not found on PATH ... (ADR-018)` reaching the LLM cleanly. Never tested live in M9.5; ADR-018 wired the typed error but the dogfood didn't exercise the failure mode.
- **`PHAROS_CONFIG_FILE` / `[languages.<id>]` override dogfood.** TOML override path is wired (`config.gleam` → `lsp/registry.gleam`'s `merge_overrides/2`) but never exercised. Test: pin a custom rust-analyzer build via `[languages.rust] command = "/opt/.../rust-analyzer-nightly"`, confirm pharos uses it instead of the PATH-resolved default.
- **Cold-start `null` tool description hint.** Append to `hover` / `goto_definition` / `goto_type_definition` descriptions: "rust-analyzer cold-start may return `null` while indexing; retry after 1–2s if you expected an answer." Cheap LLM-side workaround until `wait_for_ready` lands.

**Architectural polish (the M9.5 dogfood promised these would land before public ship):**

- **`runtime_trace_lsp` parallel race fix.** **CLOSED** in commit `e2c9a0f` (M11 polish, B2): always-on dedicated `pharos_trace_ring` (cap 100) that producers write to unconditionally; `runtime_trace_lsp` reads the delta. No filter toggle, no race. Builds on M10's emit-side persistent_term filter (commit `03650cb`).
- **`wait_for_ready` improvement.** **CLOSED** in commit `ddf3a9c` (M11 polish, B1): post-didOpen drain of the indexing burst, tracked per `(server.id, workspace)` in `pharos_post_didopen_drained` so the second drain runs once per workspace per server. Side fix: `prepare_for_method` had the same M11 ordering bug as the merge path (c001c4d) — get_lsp_for_server now runs before ensure_doc_opened_for_server_id.
- **In-flight cancel via per-request worker.** **CLOSED** in commit `10078bf` (M10): async stdio dispatch + per-request worker (`pharos/stdio_worker` + `pharos/mcp/request_workers`); MCP `notifications/cancelled` triggers `process.send_exit` against the dispatcher pid. ADR-016's deferred follow-up done.
- **Multi-LSP method routing (ADR-019).** **CLOSED** in commit `40aab59` (M10): python = pyright + ruff via per-method routing, ADR-019 stages 1-3 shipped.

**Inherited M10 charter items:**

- **Env var organization** — **DONE.** `pharos/config.gleam` is the umbrella; every `PHAROS_*` env var now resolves through one typed `Config` record stored in `persistent_term`. Source-precedence chain: compiled-in defaults → `~/.config/pharos/pharos.toml` (XDG global) → `.pharos.toml` walked up from cwd → `PHAROS_*` env overrides. Runtime knobs are env-or-TOML only; CLI flags reduced to `--version`, `--help`, `--print-default-config`. Tools surface categorised into `read` / `write` / `debug` / `raw` per-category aliases plus literal-name overrides via `pharos.toml`'s `tools = [...]`. See `doc/example-pharos.toml` for the full schema.
- **HTTP port discovery** — **DONE.** `[server.http] port_file = "..."` (or `PHAROS_HTTP_PORT_FILE`) writes the bound port atomically (write+rename via `pharos_fs_ffi:atomic_write_text/2`) in the `mist.after_start` callback. Manual override stays on `port = <int>` / `PHAROS_HTTP_PORT`. `port = 0` auto-assigns and the file always reflects the actually-bound port.
- **Config file format (TOML)** — **DONE.** `~/.config/pharos/pharos.toml` is the canonical global file, `.pharos.toml` the per-project override. Hard-flipped from JSON (`PHAROS_LSP_REGISTRY`) to TOML (`PHAROS_CONFIG_FILE`); the JSON env var and `PHAROS_LANGUAGES_FILE` are removed (no users existed). Parsed via `tomerl` (BSD, Erlang TOML 1.0). Resolves init.md open question 1.

### Milestone 11 — Future / maybe (formerly "Future / maybe")

Items that are real but unscheduled. Promote into a milestone when picked up.

- `apply_workspace_edit` tool for auto-apply use cases
- Tier 3 tools (inlay hints, semantic tokens, type hierarchy)
- Self-update inside the binary
- JetBrains plugin variant of the bridge extension
- Streaming completions (if a use case emerges)
- **`runtime_trace_lsp` parallel-dispatch race — dedicated always-on trace ring.** M10 Group B closed the writer-mailbox-cast race via emit-side persistent_term cache. Sequential issue order works (`runtime_log_level pharos/lsp/trace=debug` then activity then `runtime_log_tail` captures clean). Parallel-issued `runtime_trace_lsp` + producer race remains because the cache update still has to beat the producer's first byte — when the MCP server's concurrent tool dispatch hands hover and trace_lsp to different worker processes at the same instant, hover's first emit can fire before trace_lsp's `process.call` reaches the writer. Fix shape: bypass the global filter entirely for the trace target by maintaining a small bounded ETS ring (last ~100 wire events) that producers write to unconditionally. `runtime_trace_lsp` reads from that ring; no filter toggle, no race. Cost is per-emit ETS write even when nobody's listening — bounded ring keeps memory in check. ~50 lines. Workaround in the meantime: use the runtime_log_level recipe instead of the trace_lsp helper for parallel-issued workflows. Documented in the M10-Run-3 section of `doc/dogfood.md`.

### Milestone 12 — More languages

Owner wants to expand the bundled-language coverage. Each entry below is "add the LSP to `default_registry`, dogfood end-to-end against a tiny test workspace mirroring the existing rust_dev/go_dev/typescript_dev/python_dev pattern, document required binaries in the README install table." Per-language quirks (server-request handlers, configuration sections, readiness tokens) get caught and fixed during dogfood.

Likely candidates (owner picks the cut):

- **Elixir** — `elixir-ls` (most coverage), `lexical` (Lexical Labs server, faster cold start). Owner has Elixir history; high-value for dogfood.
- **Gleam** — `gleam lsp` (built into the gleam compiler). Trivial config; 100% type-aware.
- **Ruby** — `ruby-lsp` (Shopify, modern, supersedes solargraph for most users). May want `standardrb-lsp` layered for lint + format under ADR-019 routing.
- **Zig** — `zls`. Niche but interesting to test with non-mainstream package managers.
- **C / C++** — `clangd`. Complicated by `compile_commands.json` discovery.
- **Java / Kotlin / Scala** — JVM ecosystem, separate language servers (`jdtls`, `kotlin-lsp`, `metals`). Each is heavy on init and config; defer.
- **Lua** — `lua-language-server`. Easy.
- **Bash** — `bash-language-server`.

Out of scope until M11 promotes them: Tier 3 tools (semantic tokens, inlay hints) — coverage matters more than depth at this stage.

### Milestone 13 — Public distribution (formerly M10)

Now that M10 + M11 + M12 give pharos a polished surface and broad coverage, ship it.

- Multi-target Burrito matrix (linux_x64, linux_arm64, darwin_x64, darwin_arm64, win_x64)
- GitHub Actions release workflow green on tag push
- First npm publish with optional-deps pattern (single-pkg scaffold lives at `npm/`; M13 splits it into `pharos-mcp` meta + `@pharos/<platform>-<arch>` sub-packages so users only download their target's ~15MB binary)
- README install instructions verified end-to-end against a clean machine
- Versioning policy locked (semver, pre-1.0 minor-bump-on-breaking)
- Gated on the upstream Gleam publish fix landing and `mist` republishing — otherwise the ADR-011 workaround leaks into the public install story

#### Foundations already in place (M11)

The two distribution-blocking bugs that surfaced during M11 stdio dogfood are already fixed; M13 only needs to wire them into the release pipeline.

- **Burrito stdio under MCP-host stdin (commit e857dce).** Burrito's release runtime (`-noshell -mode embedded`) routes stdio through Erlang's `:user` group leader, which buffers reads + writes and only flushes on stdin EOF. MCP hosts hold stdin open and wait for the response on stdout — the response sat in the buffer and every fresh install timed out at the host's 30s connect deadline. Fix: pharos opens its own raw `{fd, 0, 0}` and `{fd, 1, 1}` ports, bypassing `:user` for synchronous per-line I/O. `rel/vm.args.eex` adds `-noinput` so Erlang's `prim_tty` does not fight us for fd 0. Without this fix, no amount of distribution polish makes pharos usable from npm.
- **npm postinstall warmup (commit c381659).** First-run Burrito cache extraction is ~30–60s on cold disks (xz-decompressing the embedded ERTS + BEAM payload). MCP hosts have a 30s connect timeout; first launch always failed even with the stdio fix. Pre-warming the cache during `npm install` moves the wait to install time. Implementation lives at `npm/scripts/postinstall.js` — spawn the binary, poll `~/.local/share/.burrito/pharos_*` until populated, SIGKILL once the cache directory exists. Soft-fail (always `exit 0`) so a warmup hiccup never blocks install. Skip via `PHAROS_SKIP_POSTINSTALL=1`. Verified locally: 2.5s cold-extract via the script.

#### Release pipeline tasks

- **`release.yml`**: matrix-build burrito binaries, upload to GitHub Release, copy each `burrito_out/pharos_<target>(.exe)` into the matching npm sub-package's `vendor/` (or `bin/`) directory, then `npm publish` the sub-packages and the meta package.
- **`npm/vendor/` is gitignored** — only the package scaffolding (`package.json`, `bin/pharos.js`, `scripts/postinstall.js`, `README.md`) is committed. CI populates `vendor/` at publish time.
- **Sub-package split** vs the current single-pkg scaffold: the postinstall warmup runs from the meta package after npm resolves the right sub-package, so the meta package's `bin/pharos.js` does the platform pick-up but the binaries live in the matching sub-package's `vendor/`. Adjust `bin/pharos.js`'s `binary_path()` to look up the resolved sub-package path via `require.resolve`.

#### README overhaul

Current README has good bones (install table, language registry table) but missing pieces / sections to redo before public ship:

- **No CLI-flag section.** `--version`, `--help`, `--print-default-config`, `--print-language-config <lang>`, `--doctor`, `--purge-cache` all exist; users see them only via `--help` output. Add a top-level "CLI" section.
- **Per-server timeouts not surfaced.** The 90s default `initialize_timeout_ms` and 30s `readiness_timeout_ms` (M12 polish) plus their override knobs do not appear anywhere in user-visible docs except inline in example-pharos.toml. Promote to Configuration section.
- **`runtime_language_config` MCP tool not mentioned.** Same gap — it's the LLM-callable companion to `--print-language-config` but the README never names it.
- **JSON-string override examples** (initialization_options_json / workspace_configuration_json) live in example-pharos.toml only. README's Configuration section should at least link to them.
- **Tool surface: 4 surface categories (read/write/debug/raw)** are documented; the FILTER syntax for `tools = [...]` in pharos.toml could use a worked example beyond category aliases.
- **"Updating" section** outdated — refers to npm flow that won't exist until M13 publishes.
- **Status banner** says "Milestone 10 (pre-distribution polish)" — out of date as of M11+M12.
- **Quickstart** missing — the path from "I just heard about pharos" to "I see a hover response" should be a single block, not scattered through Install + Language servers + Configuration.
- **Trouble­shooting** section missing — common failure modes (binary not on PATH, cold-start LSP timeout, jdtls JDK version, etc.) deserve a digest.

Treat the overhaul as one M13 PR, not piecemeal edits. New section ordering proposal: Quickstart → Install → Language servers → CLI → Configuration → Tool surface → Troubleshooting → Known limitations → Why → Documentation → Development → License.

#### HTTP transport test parity

Every dogfood test pharos has today drives stdio (`bin/_pharos_drive.py` spawns pharos-dev with default `PHAROS_TRANSPORT=stdio`). The HTTP code path (`pharos/mcp/http.gleam`, `mist`, `Mcp-Session-Id` routing for server-initiated requests) has shipped since M5 + M8 Stage 0 but is **not exercised by any automated test or live dogfood**. Could ship broken; we would not know.

M13 must close this gap by mirroring every stdio test surface against HTTP. Concrete deliverables:

- **`bin/_pharos_drive_http.py`** — analogue of `_pharos_drive.py`. Boots pharos with `PHAROS_TRANSPORT=http`, reads the bound port from `PHAROS_HTTP_PORT_FILE` (or autodiscovers via stderr log line), drives requests via curl/python-requests against `http://127.0.0.1:<port>/mcp`, includes `Mcp-Session-Id` header from the `initialize` response on subsequent calls.
- **`bin/test-suite-http.py`** — same SPECS, same Tier-1 tool set, same 52 cells across 13 langs. Runs against HTTP transport instead of stdio. Aim for 52/52 PASS parity.
- **HTTP-only test surfaces** that have no stdio analogue — promote these from the "Testing that needs to be done" section:
  - Session-id issuance + validation on every subsequent request.
  - Server-initiated request routing back to the originating client (`workspace/applyEdit` on a session-tagged HTTP connection).
  - Idle session eviction (configured via `session_idle_timeout_ms`).
  - SSE heartbeat re-arm under sustained streaming (M8 Stage 2 second pass tests this manually; promote to scripted).
- **`bin/test-suite-both.py`** — runs against `PHAROS_TRANSPORT=both`. Drives stdio AND HTTP at the same time with overlapping tool calls. Confirms the in-flight tracker (M9 ADR-016) keys per-session and that cancellation on one transport does not disturb the other.
- **All `bin/test-*.py` override-verification scripts** (test-missing-binary, test-config-override, test-subserver-override, test-init-options-override, test-workspace-config-override) get HTTP twins. Pure mechanical — same TOML overrides, just different transport.

Acceptance criterion before any release tag: `python3 bin/test-suite.py && python3 bin/test-suite-http.py && python3 bin/test-suite-both.py` returns 0 across all 13 languages.

#### Full test matrix — every tool × every language × both transports

The current `bin/test-suite.py` exercises 4 of pharos's ~21 tools (hover, document_symbols, workspace_symbols, get_diagnostics). The other 17 are covered only by the manual `doc/dogfood.md` plan run through Claude Code. Pharos cannot tag a release until every tool surface is automatable. Treat this as the M13 release blocker after the HTTP test parity above.

Tool inventory and current state:

**Read tools (12) — 4 covered, 8 uncovered:**
- ✓ hover, document_symbols, workspace_symbols, get_diagnostics
- ✗ goto_definition, goto_type_definition, goto_implementation, find_references, signature_help, call_hierarchy_prepare/incoming/outgoing, type_hierarchy_prepare/supertypes/subtypes, inlay_hints, semantic_tokens

**Write tools (4) — 0 covered:**
- ✗ rename_preview, format_document, code_actions, apply_workspace_edit (apply_workspace_edit needs round-trip: edit → verify file content → revert)

**Raw (1) — 0 covered:**
- ✗ lsp_request_raw

**Debug / runtime (15) — 0 covered:**
- ✗ echo, runtime_processes, runtime_pid_info, runtime_supervision_tree, runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util, runtime_log_tail, runtime_log_clear, runtime_log_level, runtime_trace_lsp, runtime_kill_lsp, runtime_trace_calls, runtime_language_config

**Out-of-band (current; keep + extend):**
- ✓ test-missing-binary, test-config-override, test-subserver-override, test-init-options-override, test-workspace-config-override

**Test-harness deliverables for M13:**

- `bin/test-tier1-full.py` — every read tool × every applicable language. ~30 LOC per tool stanza. Drives via stdio.
- `bin/test-write.py` — rename_preview / format_document / code_actions / apply_workspace_edit per language. apply_workspace_edit needs round-trip semantics (mutate → verify → revert).
- `bin/test-raw.py` — single language, raw `textDocument/hover` via lsp_request_raw, assert response shape mirrors the wrapped `hover` tool.
- `bin/test-debug.py` — language-agnostic, single pharos boot, every runtime_* + echo. ~30 min work; no LSP needed.
- `bin/test-edges.py` — cold-start tolerance (post-didOpen drain race, transport-error retry, mid-call cancel, content-modified retry). Needs deterministic LSP-side behavior, may use a stub LSP rather than real ones.

Each of the above ALSO needs an HTTP twin per the section above. Final acceptance: every test (stdio + http + both) green on every applicable language.

Net: ~21 tools × ~13 langs × 2 transports ≈ ~500 cell asserts, plus out-of-band + edges. Real work. Plan it as a dedicated M13 milestone (call it M13.5 if it slips).

#### Open M13 question — burrito vs tarball for the npm channel

M11 dogfood (Run 4) surfaced repeated friction with Burrito's self-extracting model: 50s cold-extract races against MCP host timeouts (fixed via npm postinstall warmup), opaque xz payload that's hard to inspect when debugging, and an extract-cache layer that fights the dev iteration loop. Burrito's only real win over a plain tarball is the single-file UX for direct GitHub Release downloads.

Decide before M13 ships:

- **Option A — keep Burrito for both channels.** Same binary on Releases and inside npm sub-packages. M11's npm postinstall warmup hides the cold-extract from MCP users. Continues the M11 architecture as-is. Cost: every npm install pays the warmup at install time; every binary upgrade re-extracts.
- **Option B — tarball-per-target for npm, Burrito for Releases.** Two channels, two packagings. npm sub-pkgs ship `pharos_<target>.tar.xz` containing pre-built ERTS + beams; postinstall does `tar -xJf` into a stable path; Node shim `exec`s the raw `erl` invocation. GitHub Release still ships single Burrito binary for direct-download users. Cost: two release artifacts to build, two test paths.
- **Option C — tarball for both.** Drop Burrito entirely. Direct download becomes a tarball the user extracts themselves. Cost: GitHub Release loses single-file UX; readme has to teach users to `tar -xJf` and add to PATH.

Each option's effect on the M11 stdio fix layer is identical — that lives in pharos's own code (`-noinput`, `{fd,0,0}` port, etc.) and survives all three packagings.

Decision criterion for the owner: how much do you weight the GitHub-Release direct-download UX vs the npm-install runtime cost? The owner will pick when M13 prep starts.

## Testing that needs to be done

Test surfaces uncovered as work progressed. None blocking on the path the owner is on right now; promote to a milestone task when the corresponding code lands or when release prep starts. Each entry is a pointer to the gap, not a test plan — when picked up the implementer writes the actual harness/script.

### Out-of-band CLI tests (not /mcp-runnable)

These need a fresh pharos boot with mocked environment and cannot run against an already-connected MCP server. Group them into one release-prep dogfood pass.

- **Missing-binary negative path (ADR-018).** Run pharos with `PATH=` (empty PATH), invoke `hover` on a `.rs` file via stdio MCP. Expect the typed `BinaryNotFound(command)` error to surface as the LLM-visible message `language server binary 'rust-analyzer' not found on PATH — install it and ensure it is on PATH, or override 'command' via [languages.<id>] in pharos.toml (ADR-018)`. Confirms ADR-018's user-facing error path actually reaches the consumer; nothing in M9.5/M10 dogfood exercised it.
- **Override-file dogfood (ADR-018 + M10 config).** Two scenarios: (a) `~/.config/pharos/pharos.toml` with `[languages.rust] command = "/opt/custom/rust-analyzer-nightly"`, expect pharos to spawn that binary instead of the PATH-resolved one; (b) override using a bare command name, expect `os:find_executable/1` to resolve it. Confirms the override merge path (`config.gleam` → `lsp/registry.merge_overrides/2`) plus the absolute-vs-bare branch in `resolve_command/1`.
- **Boot env var matrix.** `PHAROS_TRANSPORT={stdio|http|both}`, `PHAROS_HTTP_PORT={0|3535|fixed}`, `PHAROS_HTTP_BIND={127.0.0.1|0.0.0.0}`, `PHAROS_LOG=info,pharos/lsp/trace=debug`, `PHAROS_TRACE_LSP=1`, `PHAROS_LOG_RING=0`, `PHAROS_LOG_FILE=/tmp/pharos.log`, `PHAROS_HTTP_PORT_FILE=/tmp/pharos.port`, `PHAROS_CONFIG_FILE=/tmp/pharos.toml`. Confirm each env var is honoured at boot, and confirms precedence ordering when both TOML and env are set (env wins). The env-var umbrella landed in M10; this dogfood verifies the round-trip end to end.
- **TOML overlay precedence dogfood.** Three scenarios. (a) Global `~/.config/pharos/pharos.toml` only — confirm key applies. (b) Add a project `.pharos.toml` with a different value for the same key, run pharos from a directory under that project — confirm project wins. (c) Set the matching `PHAROS_*` env var to a third value while both files exist — confirm env wins. Walk-up resolution is exercised in scenario (b).
- **`PHAROS_HTTP_PORT_FILE` atomic write+rename.** With `port = 0` and `port_file = "/tmp/pharos.port"`, kill -9 pharos mid-write, expect to find either nothing or a complete file at the configured path — never a half-written file. Confirms the atomic rename invariant in `pharos_fs_ffi:atomic_write_text/2`.
- **Application boot idempotency.** `mix start` runs `pharos:boot/0` via app_ffi AND via `pharos:main/0`'s post-boot path. Verify boot/0's idempotency check (`find_root_supervisor/0`) actually short-circuits on the second call rather than starting two trees. Currently inferred-correct from manual /mcp dogfood; never explicitly tested.
- **`auto_boot: false` test mode.** `mix.exs` passes `auto_boot: false` for `Mix.env() == :test` so gleeunit suites stand up their own scoped components. Confirm a unit test that exercises `pool.start` directly does NOT race the (non-running) global pool spawned by app_ffi. M9.5 test suite passed, but the test was implicit; make it explicit.

### Tracer + observability tests

- **Trace ring memory bound.** With `PHAROS_TRACE_LSP=1` against a workspace generating heavy diagnostics traffic, confirm `pharos_log_ring` ETS size stabilises at the configured cap (1000 entries default per Part A of M9.5) instead of growing unbounded. Sample for ~5 minutes; check `runtime_ets_tables` for ring size.
- **Log file rotation.** With `PHAROS_LOG_FILE=/tmp/pharos.log` set, write more than 10MB worth of logs (force via debug-level for a busy tool); confirm rotation creates `/tmp/pharos.log.1` etc. and old segments are pruned at the 7-day cutoff. Implementation lives in `log/writer.gleam`'s file_sink path.
- **Sentinel crash dump on writer crash.** Force the writer actor to crash mid-session (kill its pid via `runtime_pid_info` resolved → `:erlang.exit(pid, kill)`). Confirm the next writer's init detects the prior incarnation's sentinel and writes `~/.cache/pharos/log/crash-<timestamp>.log` containing the ring tail. ADR-017 documents the sentinel pattern; nothing exercises it.

### Multi-root + workspace tests

- **Cargo workspace promotion (ADR-015).** Open a file inside a member crate of a multi-crate Cargo workspace; confirm pharos uses the workspace root (containing `[workspace]`-marked Cargo.toml) for `initialize.rootUri` rather than the member crate. Today's dogfood only tests the single-crate `rust_dev` workspace.
- **Multi-root non-Cargo monorepos.** Open a TS file in a yarn workspace, a Python file in a uv workspace. Confirm root discovery picks the right marker; document any quirks. init.md open question 5 partially addressed by ADR-015; the non-Cargo case isn't covered.

### Transport tests

- **HTTP transport end-to-end.** With `PHAROS_TRANSPORT=http`, run a curl-driven `initialize` → `tools/list` → `tools/call` flow. Confirm session ids work, that `Mcp-Session-Id` headers are issued and validated, that server-initiated requests route back to the originating client. Validates ADR-012's bidirectional design.
- **Both transport simultaneously.** With `PHAROS_TRANSPORT=both`, drive stdio AND HTTP at the same time against the same pharos instance with overlapping tool calls. Confirm the in-flight tracker (M9 ADR-016) keys per-session and that cancellation on one transport doesn't disturb the other.

### Tier 1 + Tier 2 regression suite

The current `doc/dogfood.md` plan is the de facto regression. Promote it from a one-off doc to a runnable harness:

- Either a Gleam-side gleeunit suite that drives a fake LSP for hermetic testing, OR a shell script that boots pharos with real LSPs against `rust_dev/go_dev/typescript_dev/python_dev` and asserts on stable response shapes. The latter catches LSP-version-specific regressions; the former is faster and CI-friendly.
- Either way: must run on a clean checkout with rust-analyzer / gopls / typescript-language-server / pyright-langserver / ruff installed, and exit non-zero on regression.

### Per-language milestone tests (M12)

Each language added to `default_registry` in M12 needs:

- Tiny test workspace in the same shape as the existing four (`<lang>_dev/` with one source file containing a struct/class, a function, an unused local, and one deliberate type/lint error).
- Tier 1 + Tier 2 dogfood pass against that workspace.
- README install table entry.
- Per-language quirks (server-request handlers, configuration sections, readiness tokens) captured in `LanguageConfig` defaults.

## Open questions

1. **Config file location and format.** XDG (`~/.config/pharos/config.toml`)? Per-project (`.pharos.toml`)? Both? TOML vs JSON?

2. **Per-language defaults.** Bundle a default config for popular languages (rust-analyzer, gopls, tsserver, pyright, etc.)? Detection logic (check PATH on first use)?

3. **LSP lifecycle policy.** One LSP per language, kept warm for session? Spawn-per-call (slow but simple)? Idle timeout? rust-analyzer's 30s cold start makes lifecycle a real concern.

4. **Content block representation.** MCP content blocks support text/image/resource. Diagnostics → text. Hover → text or markdown? Match LSP `MarkupContent` kind?

5. **Workspace roots.** LSPs need workspace root URIs at `initialize`. From MCP client (some pass it)? CWD? Config file? Bridge endpoint when extension running?

6. **Error surfacing.** When LSP returns error or doesn't respond, do we return MCP error response, or success with embedded error message in content block? (Latter probably better for LLM consumption.)

7. **Concurrency model.** Multiple in-flight tool calls in parallel? One LSP can have many pending requests; pending tracker must support that.

8. **Bridge port discovery.** File at `~/.config/pharos/bridge-port` vs env var vs both? Race conditions if two VSCode windows are open?

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
