# 033. Burrito from a fork: real embedded mode and an in-use lock on unpacks

**Status:** Proposed
**Date:** 2026-10-18

## Context

pharos ships as a Burrito binary. On first run the wrapper unpacks the
release into `<base>/.burrito/pharos_erts-<erts>_<vsn>/` and execs the VM
from there. Burrito 1.5.0 has two bugs that together crash **running**
pharos servers whenever a newer version starts:

1. **Cleanup has no in-use check.** `wrapper.zig` calls
   `maint.do_clean_old_versions` on every launch, which deletes every
   unpack of the app that is semver-older than the one launching. SemVer
   ignores `+build` metadata, so our per-build `+<sha>` suffixes compare
   equal and only a real version bump triggers it.
2. **The VM never ran embedded.** `erlang_launcher.zig` passed
   `"-mode embedded"` as one argv element. `init` does not split it, so
   `code:get_mode()` was `interactive` and every module was lazy-loaded
   from the unpack on first call. Delete the unpack and the running VM
   dies on its next not-yet-loaded module (`undef` / `nofile`). The
   launcher's `"-s elixir start_cli"` and `"-elixir ansi_enabled true"`
   were single elements too, and likewise never took effect.

pharos is the most exposed Burrito app on a developer machine:
[one instance per MCP client session](030-process-lifecycle-hardening.md),
several at once. After `npm update`, the first new session's pharos
deletes the older unpack, and every pharos already running in other
sessions crashes on its next lazy load. Those sessions silently lose
their LSP tools. Two projects pinned to different pharos versions fight:
the older one re-unpacks on every launch, and the newer one deletes it on
every launch. geex, another Burrito app of ours, hit exactly this.

Making the VM really embedded exposed a latent pharos bug. The release's
`start.script` put hpack at `$RELEASE_LIB/hpack_erl/ebin/hpack-0.3.0/ebin`,
a path that does not exist in the assembled release. Interactive mode
never exercises the script's `primLoad`, so nobody noticed. Embedded
boot aborts with `{load_failed,[hpack_index,huffman,…]}`. The cause is
[ADR-011](011-mix-app-name-symlink-workaround.md)'s mirror-path ordering,
recorded there as operational gotcha 3.

## Decision

Depend on a fork, `LoganBresnahan/burrito`, pinned by commit, instead of
hex `burrito ~> 1.5.0`. The fork is v1.5.0 plus a small patch set
documented in `FORK.md` on its branch:

- **(A) Real embedded mode.** `-mode` and `embedded` are separate argv
  elements. The two flags that never took effect (`-s elixir start_cli`,
  `-elixir ansi_enabled true`) are **dropped**, not split. Made live,
  `elixir:start_cli` hands the app's argv to Elixir's CLI after boot, and
  that CLI halts the VM once its commands are processed (observed: pharos
  exits right after answering `initialize`). It would also run a file
  argument as a script.
- **(B) Cleanup spares unpacks in use.** A runner holds a shared,
  non-blocking `flock` on `<unpack>/.burrito-in-use` for its whole life.
  The fd's close-on-exec flag is cleared, so `beam.smp` holds the lock
  across both execs; on Windows the waiting wrapper holds it via
  `LockFileEx`. A deleter takes an exclusive, non-blocking lock and skips
  the unpack if it can't get one. An unpack with no lock file predates
  the protocol: on Linux it is deleted only if no `/proc/*/exe` lies under
  it, and elsewhere it is kept.

The fork is fork-only: no issues or PRs go to upstream
`burrito-elixir/burrito`. It is shared with geex, which proves each
change first.

On the pharos side:

- ADR-011's mirror paths are prepended, and re-applied in a release step
  just before `:assemble` (`prepend_mirror_paths/1`), so the boot script
  gets `$RELEASE_LIB/hpack-0.3.0/ebin`.
- A release step, `check_boot_script/1`, runs before `Burrito.wrap`. It
  emulates embedded `primLoad` against `start.script` and fails the build
  on any missing path or unloadable module, in seconds rather than after
  five cross-compiled wraps.
- `pharos --purge-cache` follows the same lock protocol by running the
  fork's wrapper-level `maintenance purge` (`$__BURRITO_BIN_PATH
  maintenance purge`) and relaying its per-unpack report. The BEAM cannot
  `flock` without a NIF, which [ADR-030](030-process-lifecycle-hardening.md)
  rules out for v1.0, and `flock(1)` does not exist on macOS or Windows,
  so the wrapper's Zig code is the one implementation of the contract.
  A Linux-only `/proc` check was rejected as an interim. A running pharos's
  own unpack is always kept, because its wrapper took the shared lock
  before booting. `pharos maintenance purge`, which the wrapper handles
  before it locks or unpacks anything, can remove every unpack once no
  pharos runs.

## Consequences

- An older pharos left running survives a newer pharos's first run, and
  its unpack is removed by the first launch after it quits. Verified
  2026-10-18 in an isolated install dir, for both an unpatched old
  binary (no lock file, `/proc` fallback) and a fork-built one
  (`FLOCK ADVISORY READ` held by the beam pid). The old VM kept answering
  tool calls throughout.
- Every module is loaded at boot. Measured on a kernel/stdlib-only probe
  of our boot script: about +90 ms (0.07 s → 0.16 s). Negligible against
  MCP connect timeouts.
- Embedded mode is strict: a bad boot-script path is now a boot failure,
  not a silent no-op. `check_boot_script/1` is the guard; keep it.
- What still reads the unpack at runtime: port programs the VM starts
  lazily (`inet_gethost` on the first DNS lookup). (B), not (A), is what
  protects those. LSP children don't pin an unpack: pharos spawns every
  external process through `open_port` / `os:cmd`, so via `erl_child_setup`,
  which closes inherited fds before exec.
- Upgrades now accumulate unpacks while old sessions live. They are
  reclaimed lazily, by the next launch after the holders quit.
- The hex→git switch made `deps.get` re-resolve Burrito's build-time deps
  (finch, hpax, mint, req). Their old lock entries were restored, so the
  lock diff is the burrito line alone. Do the same on every ref bump.
- We now own a fork. Rebasing it onto Burrito 1.6.0 still means
  bumping Zig to 0.16.0, the same constraint the old `~> 1.5.0` pin
  recorded in `mix.exs`.
- The wrapper's `logger.info` used to write to **stdout**. With
  `PHAROS_INSTALL_DIR` set, it printed `[i] Install path is being
  overridden…` ahead of the JSON-RPC stream, corrupting stdio MCP. The fork
  (from 4407714) sends every launcher log level to stderr. `maintenance`
  subcommands still write their own output to stdout.
- This is a stopgap. The long-term direction (`.private/roadmap.md`) is
  shipping already-unpacked releases per platform package and exec'ing
  `erlexec` directly, with no self-extraction at all.

## Alternatives considered

- **Stay on upstream 1.5.0.** Rejected: it crashes live sessions on every
  version bump.
- **Upstream the fixes.** Ruled out by the project owner: the fork stays
  fork-only.
- **Pin `PHAROS_INSTALL_DIR` per version** to dodge cleanup. Rejected: it
  doesn't fix lazy loading, and it leaks unpacks forever.
- **Fix only (A).** Rejected: embedded mode protects `.beam` loads but not
  lazily started port programs, and it still lets two versions fight
  over the unpacks.
