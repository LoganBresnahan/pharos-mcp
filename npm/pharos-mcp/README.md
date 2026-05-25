# pharos-mcp

Headless LSP-MCP bridge for AI agents. Hands rust-analyzer, gopls,
tsserver, pyright, jdtls, and 19 more language servers to any
MCP-aware agent (Claude Code, Cursor, ChatGPT Desktop) — so the
model can navigate your codebase with type-aware queries instead of
grepping.

## Install

```bash
npm install -g pharos-mcp
```

Or run on-demand without a global install:

```bash
npx -y pharos-mcp
```

Release candidates publish under the `next` dist-tag:

```bash
npm install -g pharos-mcp@next   # latest rc / preview
```

## Configure your MCP client

```jsonc
{
  "mcpServers": {
    "pharos": {
      "command": "pharos"
    }
  }
}
```

(Replace with `{ "command": "npx", "args": ["-y", "pharos-mcp"] }`
if you used the npx path.)

## How the binary ships

Per-platform binaries live in separate npm packages
(`@pharos-mcp/linux-x64`, `@pharos-mcp/darwin-arm64`, etc.) declared
as `optionalDependencies` of this package. npm filters by host
`os` + `cpu` and installs exactly one. The `pharos` shim on PATH
resolves it via `require.resolve` and exec's it.

## Postinstall warmup

The first install runs a one-time warmup (~30-60s) that extracts
the Burrito-wrapped Erlang VM payload to
`~/.local/share/.burrito/`, so the first MCP connection is fast
(otherwise MCP hosts time out before extract completes).

To skip warmup (e.g. in CI): set `PHAROS_SKIP_POSTINSTALL=1`.

## Full documentation

[github.com/LoganBresnahan/pharos-mcp](https://github.com/LoganBresnahan/pharos-mcp)
— benchmarks, tool reference, language support, ADRs.

## License

AGPL-3.0-only. Commercial licensing available — see [COMMERCIAL.md](https://github.com/LoganBresnahan/pharos-mcp/blob/main/COMMERCIAL.md).
