# 003. Standalone binary, optional VSCode extension as buffer-state booster

**Status:** Accepted
**Date:** 2026-05-02

## Context

The project bridges MCP clients to LSPs. A core question: where does workspace context come from?

**Context types LSPs need to operate well:**
- File contents (the LSP must be told what's in each open document)
- Workspace root URI (the directory containing `Cargo.toml` / `go.mod` / `package.json`)
- Active selection / cursor (for some tools)
- Unsaved buffer state (the version the user is currently editing, not what's on disk)

**Three architectural shapes were considered:**

**Path X — Standalone, MCP-spawns-LSP.**
Binary spawns LSPs itself, manages their lifecycle, reads files from disk. Works with any MCP client (Claude Code, Cursor, Claude Desktop, web clients). Doesn't see unsaved buffer state — if the user is mid-edit and asks an LLM about diagnostics, the LSP analyzes the saved version, which may differ from what's on screen. For agentic flows where the LLM is the editor (Claude Code), this is fine because the agent saves before querying. For human-in-editor flows, this is a real correctness gap.

**Path Y — VSCode extension hosts MCP server.**
Extension uses VSCode's `vscode.languages.*` APIs (which already see unsaved buffers via VSCode's own LSP integration). Solves unsaved buffers natively. Locks the project to VSCode (and forks: Cursor, Windsurf). Loses reach to Claude Desktop, headless agents, CI use cases. Drops Gleam (extensions are TypeScript), invalidating ADR-001's typed-language goals.

**Path Z — Hybrid: standalone binary + optional extension as buffer oracle.**
Binary is the primary deliverable, runs everywhere as in Path X. A separate, thin VSCode extension (`pharos_ext`) binds a localhost HTTP server when active and exposes endpoints (`/buffer`, `/workspace-roots`, `/selection`, `/diagnostics-snapshot`). The binary probes for the extension at startup; if found, it asks the extension for current buffer state before forwarding `didChange` to LSPs. If not found, it falls back to disk-only. Best of both: full reach when used standalone, full fidelity when extension is installed.

## Decision

Implement **Path Z**.

The binary always works standalone. The VSCode extension is an optional booster that ships from a separate repo (see ADR-007).

The binary's bridge module probes for the extension on startup:
1. Look up bridge port from `~/.config/pharos/bridge-port` file or `PHAROS_BRIDGE_PORT` env var.
2. `GET http://127.0.0.1:<port>/healthz`. If 200 with matching protocol version, mark extension available.
3. If probe fails or version mismatches, fall back silently to disk reads.

When making a tool call that needs file content:
- Extension available → fetch via `GET /buffer?uri=...` (returns text + version + isDirty)
- Extension unavailable → read from disk

The binary's MCP server, LSP client supervisor, and tool registry are unchanged across the two modes — only the `bridge/buffer.gleam` module's read path differs.

The extension is intentionally tiny (~200 lines TypeScript). It does not implement MCP, LSP, or any business logic. It binds an HTTP server and exposes VSCode's APIs over five endpoints.

The bridge protocol is documented in `doc/bridge-protocol.md` and versioned independently. Extension declares which protocol versions it supports.

## Consequences

**Easier:**
- Maximum reach — binary works in any MCP client without an editor extension
- Maximum fidelity — when extension is installed, unsaved buffers are honored
- Extension is minimal — ~200 lines, easy to maintain, minimal attack surface
- Real differentiation from `jonrad/lsp-mcp` (which has no editor integration)
- Failure mode is graceful: extension crash or absence falls back to disk transparently

**Harder:**
- Two artifacts to maintain (binary repo + extension repo)
- Bridge protocol is now an API surface — versioning, compatibility, deprecation matter
- Coordinated changes across repos when bridge protocol evolves
- Detecting that extension is "stale" (running an older protocol version against a newer binary) needs explicit handshake logic

**Living with:**
- For non-VSCode editors (Helix, Neovim, JetBrains), users get only the standalone disk-based mode unless someone implements a bridge extension for that editor. The bridge protocol is small enough that ports are tractable.
- Race condition: if two VSCode windows are open in the same workspace, two extension instances may try to bind the same port. Resolution policy is open (see init.md open question 8).
- Discovery via file or env var is brittle compared to true service discovery, but adequate for v0.1.

## Alternatives considered

- **Path X (standalone only)** — simpler but cedes the unsaved-buffer use case entirely. Acceptable for v0.1 if scope-cut, but Path Z's extension is small enough that we can ship both.
- **Path Y (extension only)** — limits reach to VSCode-family editors and drops Gleam. Conflicts with ADR-001.
- **VSCode extension that proxies to a running binary via stdio** — possible, but binary's stdio is occupied with MCP traffic. Would need a second IPC channel. HTTP localhost is simpler and lets the extension be probed from outside.
- **Binary registers itself as a VSCode language client middleware** — interesting but invasive; binary becomes part of VSCode's LSP plumbing, complex to develop and debug.
