<p align="center">
  <img src="https://raw.githubusercontent.com/LoganBresnahan/pharos-mcp/main/assets/pharos.png" height="120px" alt="pharos" />
</p>

<h1 align="center">pharos-mcp</h1>
<h2 align="center">v0.1.4</h2>

<p align="center">
  Headless LSP-MCP bridge for AI agents. Hands rust-analyzer, gopls,
  tsserver, pyright, jdtls, and 19 more language servers to any
  MCP-aware agent (Claude Code, Cursor, ChatGPT Desktop) — so the
  model can navigate your codebase with type-aware queries instead of
  grepping.
</p>

---

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

## How it ships

Each platform's release lives in its own npm package
(`@pharos-mcp/linux-x64`, `@pharos-mcp/darwin-arm64`, etc.), declared
as an `optionalDependency` of this one. npm filters by host `os`, `cpu`
and, on Linux, `libc`, and installs exactly one. It holds the release
unpacked: the native `pharos` front end and the Erlang runtime it
starts. Nothing extracts at run time.

On Linux and macOS the postinstall points the `pharos` command straight
at the native binary, so an MCP session runs no node process. Several
sessions share one pharos daemon per version, and with it the language
servers they have in common. If the postinstall can't run
(`--ignore-scripts`, `PHAROS_SKIP_POSTINSTALL=1`), and always on
Windows, `pharos` is a small node launcher in front of the same binary.

Linux needs glibc 2.35 or newer: Ubuntu 22.04, Debian 12, RHEL 9 or
newer. pharos 0.2 doesn't run on Alpine/musl or older distros yet;
`pharos-mcp@0.1.4` still does.

## Full documentation

[github.com/LoganBresnahan/pharos-mcp](https://github.com/LoganBresnahan/pharos-mcp)
— benchmarks, tool reference, language support, ADRs.

## License

Apache-2.0. See [LICENSE](https://github.com/LoganBresnahan/pharos-mcp/blob/main/LICENSE).
