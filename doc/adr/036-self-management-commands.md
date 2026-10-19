# 036. `pharos self`: update, rollback, prune and uninstall from the launcher

**Status:** Accepted
**Date:** 2026-10-19
**Amends:** [ADR-035](035-releases-without-burrito.md) §4 (install.sh) and §6 (`--purge-cache`)

## Context

ADR-035 shipped pharos 0.2.0 with install.sh as the only way to change an install: run the
`curl … | sh` one-liner again to update, keep its URL around to `--rollback` or `--uninstall`, and
`pharos --purge-cache` to clean up after 0.1.x. Users don't keep installer URLs. An
installed program that can update and remove itself is the expected shape (`rustup self
update`, `uv self update`), and geex and captAInHook, which share install.sh's convention, are
adding the same commands. They should have the same names and the same behaviour across all three.

Three facts constrain the design:

- **install.sh is the one implementation of the version rules** (keep the current and the
  previous version; never remove a version a running process names on its command line; switch
  the link in one rename). A second implementation in the launcher would drift from it. geex
  and pharos keep the script itself in step, word for word apart from names.
- **install.sh's in-use rule reads `ps` command lines.** A command line naming
  `<install dir>/versions/<v>/` keeps that version, and blocks `--uninstall`. So
  `sh ~/.local/share/pharos/versions/0.2.1/install.sh --uninstall` would find itself and refuse.
- **npm owns the files of an npm install.** Rewriting `node_modules` behind npm's back leaves
  npm's records lying.

## Decision

**install.sh gains `--prune`**: the prune an install already does, with no download (geex
286d128, taken verbatim). It prints a kept line for the current and the previous version and a
removed or kept line for every other, and exits 0. With no current version (no link, or one
this script didn't make) it prunes nothing: the current version is what decides what stays.

**Every version ships its installer.** The package step copies install.sh into the release
(`versions/<v>/install.sh`) and next to the tarball, so `_build/package` looks like the
GitHub release and a `file://` `PHAROS_DOWNLOAD_URL` works for `self update` too.

**`pharos self …` lives in the shim** (`shim/src/self_cmd.rs`), which answers it without
booting the runtime:

| Command | install.sh install | npm install |
|---|---|---|
| `self update [--version V]` | download the release's install.sh (latest, V's, or `$PHAROS_DOWNLOAD_URL/install.sh`) and run it | print `npm install -g pharos-mcp@latest` (or `@V`), exit 1 |
| `self rollback` | bundled install.sh `--rollback` | print the npm command, exit 1 |
| `self prune` | 0.1.x cleanup, then bundled install.sh `--prune` | 0.1.x cleanup, say npm keeps one version, exit 0 |
| `self uninstall` | bundled install.sh `--uninstall` | print `pharos daemon stop --all && npm uninstall -g pharos-mcp`, exit 1 |

- The install kind comes from the release's real path: `…/versions/<v>` is install.sh's
  layout (its parent's parent is `PHAROS_INSTALL_DIR`), and
  `…/node_modules/@pharos-mcp/<platform>/release` is npm's. Anything else, such as a build's
  `_build/prod/rel/pharos`, gets an error for update, rollback and uninstall, and only the 0.1.x
  cleanup for prune.
- install.sh runs as `sh -s -- <flags>` with the script on stdin, exec'd in place of the
  shim: the same path as `curl … | sh`. No command line names a version directory, so
  install.sh's in-use rule sees no false use, and nothing is left behind. A downloaded script
  is opened and unlinked before the exec.
- `PHAROS_INSTALL_DIR` is set from the real path. `PHAROS_BIN_DIR`, unless set already, comes
  from the link that launched pharos: argv[0] when it is a path to a link to this executable,
  else the first `pharos` on PATH that is one. Without it, a link outside `~/.local/bin` is
  invisible to install.sh, and `--prune` would see no current version.
- **npm installs print the npm command** and exit 1. `self update` exits 1 too, because
  nothing was updated, and `pharos self update && …` must not carry on. `self prune` is the
  exception: the 0.1.x unpacks it removes aren't npm's, and npm users are exactly the ones
  who have them.
- **`self prune` takes over `--purge-cache`'s job** (ADR-035 §6): remove each
  `<data>/.burrito/pharos_*` directory (Linux `$XDG_DATA_HOME` or `~/.local/share`, macOS
  `~/Library/Application Support`) that no running process's command line names. It never
  touches anything else in that shared directory. The cleanup is ported to Rust and the
  BEAM's copy removed, so there is one implementation. `pharos --purge-cache` stays one more
  release as a deprecated alias that says so and runs `self prune`. `--doctor` still reports
  leftover unpacks, and names `self prune`.
- **`self uninstall` does not stop daemons.** Stopping them would end every MCP session on
  the machine without asking. install.sh refuses while any pharos runs and names
  `pharos daemon stop --all`; the npm hint leads with it.

## Consequences

- An install.sh user never needs the installer URL again. 0.2.0 installs have no `self`, so
  their first update is the one-liner once more; the README says so.
- install.sh stays the only code that moves versions. Its rules change in one place, in step
  with geex's copy.
- The rollback, prune and uninstall a version runs are the ones it shipped with, not the latest
  release's. A fix to `--prune` reaches users at their next update, not immediately.
- `self update` needs curl, as install.sh does.
- rel/smoke.sh exercises all four commands from `file://`, against two repacks of the build
  under new version names (only the shim reads the version, and it answers `--version` and
  `self` without booting them). A running daemon's version survives an install's prune and
  `self prune`, and goes once the daemon stops. The npm smokes check that `self update` names
  the npm command.
- `--purge-cache` goes in the release after 0.2.1.

## Alternatives considered

- **Reimplement the version rules in Rust.** Two implementations of the keep rule, the
  in-use rule and the atomic link switch, which would drift. And geex's launcher is sh, so the
  three projects would stop sharing one.
- **Run the bundled script by path** (`sh <root>/install.sh --uninstall`). Its own command line
  names `versions/`, so uninstall refuses itself and prune keeps the version it runs from.
- **Copy the script to a temp file and run that.** Works, but leaves a file behind on any exit
  but a clean one. stdin needs no cleanup.
- **`self uninstall` stops the daemons first.** It would end other MCP clients' sessions with
  no warning. The user can run `pharos daemon stop --all` themselves; install.sh tells them to.
- **npm `self update` runs `npm install -g` itself.** npm may need a different prefix,
  sudo, or a project-local install. Printing the command is honest and works for all of them.
