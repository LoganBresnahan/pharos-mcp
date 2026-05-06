# 018. LSP binary path resolution

**Status:** Proposed
**Date:** 2026-05-06

## Context

Pharos must spawn an LSP server subprocess for each `(language, workspace)`
the user touches. The current implementation in
`src/pharos/lsp/languages.gleam:147-275` ships absolute paths hardcoded to
the maintainer's dev box:

```
rust       → /home/oof/.cargo/bin/rust-analyzer
go         → /home/oof/.asdf/shims/gopls
typescript → /home/oof/.nvm/versions/node/v25.4.0/bin/typescript-language-server
python     → /home/oof/.nvm/versions/node/v25.4.0/bin/pyright-langserver
```

The Erlang spawn path uses
`erlang:open_port({spawn_executable, Command}, ...)` (see
`src/pharos_lsp_port_ffi.erl:35`). `spawn_executable` requires an absolute
path; it does NOT consult `$PATH`. So the current bundle works on exactly
one machine, and any other user attempting to run pharos hits a port
spawn error before any tool call lands.

The dogfood pass on 2026-05-06 surfaced this as a release-blocker for
M10 distribution. The forthcoming Burrito-wrapped binary is meant to be
runnable by anyone who installs the matching language toolchain — but
the current registry guarantees it works for nobody else.

Three forces are in play:

1. **Portability.** Pharos is a developer tool meant to be installed by
   strangers. It cannot embed maintainer-specific filesystem layout.
2. **Discoverability.** When a user runs pharos against a Rust workspace
   and rust-analyzer is not installed, the failure must be a clear
   "rust-analyzer not on PATH" message, not "port spawn EACCES" or worse,
   silent timeout.
3. **Override-ability.** Power users do install language servers in
   non-standard locations (custom rust-analyzer build, project-pinned
   pyright via `npx`, isolated direnv envs, etc.). The default must be
   easy AND overridable.

We considered making the user always supply a config file before pharos
will start any LSP — rejected because zero-config "it just works if
rust-analyzer is on PATH" is the M10 release story we want.

We also considered shipping LSPs bundled inside the Burrito archive —
rejected because (a) license proliferation across rust-analyzer / gopls
/ ts-language-server / pyright is a doc and update nightmare, (b) the
binaries together would more than double archive size, and (c) every
language toolchain churn would force a pharos rebuild even when nothing
about pharos changed.

## Decision

Default registry ships **bare command names**, not absolute paths.
At spawn time, pharos resolves each name to an absolute path via
`os:find_executable/1` (Erlang stdlib). Resolution failure surfaces
to the caller as a typed error
(`LanguageBinaryNotFound { language, command, hint }`) with a
remediation hint that names the package and the most common install
flow ("install rust-analyzer with `rustup component add rust-analyzer`
and ensure it is on PATH").

Bare default_registry:

```
rust       → "rust-analyzer"
go         → "gopls"
typescript → "typescript-language-server"
python     → "pyright-langserver"
```

The existing override merge path (`registry.gleam:57-58`,
`PHAROS_LSP_REGISTRY` env var) continues to work and now serves three
distinct use cases:

1. **Pin a specific binary path.** Override `command` with an absolute
   path; pharos skips the `find_executable` step when the override
   already looks absolute (`String.starts_with("/")`).
2. **Add a language not in the default bundle.**
3. **Patch initialization parameters per workspace.**

Resolution order at LSP spawn:

1. Look up `LanguageConfig` for the file's extension (existing).
2. If `config.command` is absolute (`startsWith "/"`) — use it directly.
3. Else `os:find_executable(config.command)` → absolute path or `false`.
4. If `false` — return `LanguageBinaryNotFound` with the hint.
5. Pass resolved path into `open_port({spawn_executable, ...}, ...)`
   exactly as today.

The README documents the language → required-binary table and links to
each project's install instructions, but pharos never installs or
manages those binaries itself.

## Consequences

**Easier:**
- Pharos becomes installable by anyone who already has the language
  toolchain on PATH — the realistic baseline for a developer tool.
- Failure mode flips from "silent / cryptic port error" to "clear
  message naming the missing binary and how to get it."
- Override mechanism no longer hides a portability bug — the bare
  defaults are now the supported configuration, the override file is a
  power-user knob, not a secret prerequisite.

**Harder:**
- One extra syscall per LSP spawn. `os:find_executable/1` is cheap and
  only runs on cold spawn (cached LSP procs reuse the resolved path),
  so the cost is negligible.
- Test coverage now needs a path that runs without binaries on PATH and
  asserts the typed error surfaces cleanly. Existing dogfood tests
  always run on a machine where the binaries are present.

**Live with:**
- Pharos is no longer a self-contained "single-binary distribution."
  Users must install language servers themselves. This is consistent
  with VS Code, Helix, Neovim, and every other editor — but it must be
  loud in the README and in the error message.
- Multi-version situations (e.g. user has both system pyright and
  project-pinned pyright via direnv) resolve to whichever the shell PATH
  resolves at pharos start time. If the user wants project-pinned
  servers, they need direnv-aware shell or the override file.
- Burrito-packaged pharos still needs to inherit PATH from the invoking
  shell. The Burrito wrapper's launcher already does this; documenting
  it is enough.

## Alternatives considered

- **PATH-lookup-only, no overrides.** Rejected because some users have
  legitimate non-PATH installs and we already have the registry-merge
  machinery built. Removing the override path would be a regression.
- **Bundle servers in the Burrito archive.** Rejected for size, license,
  and update-pacing reasons (see Context).
- **Shell out to `which`/`command -v` instead of `os:find_executable/1`.**
  Rejected because Erlang stdlib already does this portably (Linux,
  macOS, Windows) without spawning a subshell. `os:find_executable/1`
  is the right tool.
- **Require an explicit config file before any LSP runs.** Rejected for
  zero-config story. The 80% case is "rust-analyzer is on PATH" — that
  case must work without ceremony.
