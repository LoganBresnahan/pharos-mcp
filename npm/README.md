# pharos-mcp

npm wrapper for [pharos](https://github.com/LoganBresnahan/pharos) — an MCP
server bridging LLMs to Language Server Protocol servers.

```jsonc
{
  "mcpServers": {
    "pharos": {
      "command": "npx",
      "args": ["-y", "pharos-mcp"]
    }
  }
}
```

The package bundles per-platform burrito binaries (Erlang VM + BEAM
payload in a single self-contained executable). The first install
runs a one-time `postinstall` warmup (~30–60s) that extracts the
payload to `~/.local/share/.burrito/` so the first MCP connection
is fast. To skip warmup (e.g. in CI), set `PHAROS_SKIP_POSTINSTALL=1`.

See the [main repo](https://github.com/LoganBresnahan/pharos) for
configuration, tool surface, and dogfooding notes.
