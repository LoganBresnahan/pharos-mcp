# llm_lsp_mcp

MCP (Model Context Protocol) server that exposes LSP (Language Server Protocol) capabilities as MCP tools, so an LLM can ask "what's the type of this expression?", "where is this defined?", "find all references", etc., backed by real language server analysis.

Distributed as a single self-contained binary via [Burrito](https://github.com/burrito-elixir/burrito), shipped through GitHub Releases and npm. Optionally augmented by a thin VSCode extension (separate repo) that exposes unsaved-buffer state.

> **Status:** Pre-alpha, Milestone 1.
> Stdio transport works against any MCP client: `initialize` handshake,
> `tools/list`, `tools/call` for a stub `echo` tool. Real LSP-backed tools
> arrive in Milestones 3–4. See [doc/init.md](doc/init.md) for the milestone
> plan.

## Quick install (planned, post-Milestone 6)

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

Or download a binary directly from [Releases](https://github.com/LoganBresnahan/llm_lsp_mcp/releases).

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

For binary builds (requires Zig 0.15.2 + xz, see [Burrito's setup notes](https://github.com/burrito-elixir/burrito#preparation-and-requirements)):

```bash
MIX_ENV=prod mix release                 # produces Burrito binaries in burrito_out/
```

## Companion repos

- [llm_lsp_mcp_ext](https://github.com/LoganBresnahan/llm_lsp_mcp_ext) — optional VSCode extension (bootstrapped separately)

## License

MIT — see [LICENSE](LICENSE).
