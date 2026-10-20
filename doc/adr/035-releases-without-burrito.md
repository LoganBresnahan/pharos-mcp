# 035. Releases without Burrito: a release per target, the shim as launcher, npm and install.sh

**Status:** Accepted; amended 2026-10-19: Windows unsupported, use WSL; §4 and §6 amended by [ADR-036](036-self-management-commands.md) (`pharos self`, `install.sh --prune`; `--purge-cache` becomes `self prune`)
**Date:** 2026-10-19
**Supersedes:** [ADR-033](033-burrito-fork-embedded-mode-in-use-lock.md) (the Burrito fork),
and the Burrito half of [ADR-004](004-distribution-npm-and-releases.md)

## Context

pharos ships today as a Burrito binary per target. ADR-033 forked Burrito to stop version bumps
from crashing running servers (real embedded mode, an in-use lock on unpacks), and called that a
stopgap. ADR-034 then gave pharos a native front end, the Rust shim. It is already the launcher
that execs the bundled ERTS, so Burrito's wrapper does nothing pharos still needs. What remains
of Burrito is a self-extracting cache to clean, a Zig toolchain pinned at 0.15.2, and a fork.

geex removed Burrito the same day ([geex ADR-0041](https://github.com/LoganBresnahan/geex/blob/main/doc/adr/0041-release-without-burrito.md)).
Its §8 states the recipe for another BEAM app, and pharos follows it except where a section below
says otherwise.

Constraints:

- **The npm package names stay**: `pharos-mcp` plus `@pharos-mcp/{linux-x64,linux-arm64,
  darwin-x64,darwin-arm64}`. Trusted publishing is configured for them, and a rename
  would need the owner on npmjs.com. (`@pharos-mcp/win-x64` stops at 0.1.x; see below.)
- **No resident node per session.** Today every session is a 44 MB `node` running `bin/pharos.js`
  around the binary.
- **Windows is unsupported** (amended 2026-10-19, the owner's decision for all three apps):
  Windows users run pharos inside WSL. There is no Windows build, package or CI job;
  `pharos-mcp` on win32 and a Windows build of the shim both stop with a pointer to WSL.
  `pharos-mcp@0.1.4` was the last native Windows build, and its published win-x64 package
  stays on npm (nothing is unpublished).
- **The install convention** shared by all three apps: `<app>-<version>-<os>-<arch>.tar.gz`,
  `SHA256SUMS` and `install.sh` on the release; `~/.local/share/<app>/versions/<version>/` plus a
  file symlink in `~/.local/bin`, switched by rename; fail closed on the hash; keep the current
  and previous versions and prune by command line; no rc edits, no sudo. The overrides are
  `PHAROS_INSTALL_DIR` and `PHAROS_BIN_DIR`.
- pharos is pure BEAM apart from OTP's own `crypto` NIF (checked: no `priv/*.so` and no
  `load_nif` in pharos or any dependency). The shim is the only other native file.

## Decision

### 1. The runtime: geex's `rel/build-runtime.sh`, byte for byte

`rel/build-runtime.sh` is copied unchanged from geex at commit `c7e4f76`: OTP 28.1.1 from source,
static OpenSSL 3.5.9, static ncurses 6.5 on Linux, and Elixir 1.19.5's precompiled zip. Every
download is sha256-pinned. Keeping it identical keeps the two repos' updates diffable. pharos
never uses `:prim_tty`, so ncurses is dead weight for it (about 30 s of build, under 1 MB).
geex-e1's warning stands: dropping the ncurses block without adding `--without-termcap` silently
links the system's libtinfo.

So pharos moves to **OTP 28.1.1**: `.tool-versions`, both CI workflows and the release all
change together, as CLAUDE.md requires.

### 2. Targets and runners

Each target builds natively on its own runner, with the runtime from §1 cached by the script's
hash. There is no cross-compilation, so the `.beam` files and the VM they ship with come from one
OTP:

| npm package | tarball | runner |
|---|---|---|
| `@pharos-mcp/linux-x64` | `pharos-<v>-linux-x64.tar.gz` | ubuntu-22.04 (glibc 2.35 floor) |
| `@pharos-mcp/linux-arm64` | `pharos-<v>-linux-arm64.tar.gz` | ubuntu-22.04-arm |
| `@pharos-mcp/darwin-arm64` | `pharos-<v>-darwin-arm64.tar.gz` | macos-14 |
| `@pharos-mcp/darwin-x64` | `pharos-<v>-darwin-x64.tar.gz` | macos-15-intel (new: geex has not tried it yet, and the result goes back to geex-e1) |

### 3. The release build

`MIX_ENV=prod mix release` runs:

    prepend_mirror_paths → :assemble → check_boot_script → trim_release
      → build_shim → check_native → package

- **`trim_release`**, ported from geex: `erts-*/bin` keeps `beam.smp`, `erlexec`,
  `erl_child_setup` (every LSP spawn goes through it) and `inet_gethost`. Those are stripped with
  `strip -S` and re-signed ad hoc on macOS. crypto's `otp_test_engine.so` is dropped. Mix's own
  scripts (`bin/pharos`, `releases/V/{elixir,iex,env.sh,…,start_clean.*}`) and `releases/COOKIE`
  are removed. The cookie matters because a published cookie would be everyone's. Every
  `lib/*/priv/**/*.so` is signed ad hoc on macOS too: the Intel linker leaves dylibs unsigned
  (found on macos-15-intel).
- **`build_shim`**: `cargo build --release` in `shim/`, copied to `bin/pharos`,
  and re-signed ad hoc on macOS.
- **`check_native`**, ported from geex's `native_problems/2`, covers every ERTS program, every
  `priv/**/*.so` and the shim:
  - **Linux:** only the glibc family plus `libgcc_s.so.1` may be linked. The shim's Rust std
    needs `libgcc_s`. No glibc symbol newer than 2.35 is allowed.
  - **macOS:** only `/usr/lib` and `/System/Library` may be linked, with a dylib's own id
    subtracted (geex's `otool_id` trap), and every Mach-O must pass
    `codesign --verify --strict`.
  - A release build (`PHAROS_RELEASE=1`) stops on any problem. A local build only notes them.
- **`package`** writes `BUILD_ID` (ADR-034; `build_id/1`). It packs
  `_build/package/pharos-<v>-<os>-<arch>.tar.gz`, with a top directory of the same name, plus
  `SHA256SUMS`, and fills `npm/@pharos-mcp/<platform>/release/`.

The version is `0.2.0` for a release build and `0.2.0+<sha8>` locally, as today. Each local
build gets its own install directory and its own daemon.

### 4. install.sh

pharos's `install.sh` is geex's (§4 there), with `APP=pharos` and the overrides
`PHAROS_INSTALL_DIR` (default `${XDG_DATA_HOME:-~/.local/share}/pharos`), `PHAROS_BIN_DIR`
(default `~/.local/bin`) and `PHAROS_DOWNLOAD_URL`. The behaviour is the same:
- `--version`, `--force`, `--rollback`, `--uninstall`;
- unpack into `versions/.tmp-<pid>`, then one rename;
- `pharos --version` must answer before the link moves;
- the glibc 2.35 check, and Rosetta → arm64.

**Pruning and live daemons.** A version is kept while any process's command line names its
directory (`ps -A -ww -o args=`, read once). Two kinds of process can name it:
- a running daemon, whose `beam.smp` argv carries `-root <versions>/<v>` and its `--socket`, so
  it pins its version until it idles out (ADR-034);
- a session shim, whose path resolves into `versions/<v>/bin/pharos`, but its argv shows the
  `~/.local/bin/pharos` link, so it does not pin anything. That is harmless: the shim needs none
  of the version's files once it is running.

So an upgrade leaves the old version on disk until its daemon exits, and the next install prunes
it.

**`PHAROS_INSTALL_DIR` changes meaning.** It used to be Burrito's extraction root (ADR-033). It
is now the install root, matching geex's `GEEX_INSTALL_DIR`. Nothing reads the old meaning after
this change.

### 5. npm without a resident node

- Each platform package ships the unpacked release under `release/`: `bin/pharos` (the shim),
  `erts-*`, `lib`, `releases`, `BUILD_ID`. It declares `os` and `cpu` as today, and the Linux
  packages also declare `"libc": ["glibc"]`.
- **Unsupported Linux is loud.** When no usable platform package is installed, or glibc is older
  than 2.35, `bin/pharos.js` and the postinstall both print "pharos 0.2 needs glibc 2.35+
  (Alpine/musl and older distros aren't supported yet); pharos-mcp@0.1.4 still runs there" and
  exit non-zero. The release notes carry the same line.
- `pharos-mcp`'s `bin` stays `bin/pharos.js`. Its **postinstall** (esbuild's pattern) replaces
  that file with a symlink to the installed platform package's
  `release/bin/pharos`. npm's own bin link then resolves to the native shim, with no node in the
  process tree. The shim canonicalizes its path, so it still finds its release.
- With `--ignore-scripts`, or if the swap fails, `bin/pharos.js` stays: a fallback that spawns the
  native shim with inherited stdio and passes signals and the exit status through. That costs a
  node per session again, but only in that case.
- **`npm update` replaces the platform package in place**, so a daemon running from it loses its
  files. Embedded mode makes this survivable: every module is loaded at boot, and
  `erl_child_setup`, which every LSP spawn goes through, is already running. What is left is
  `inet_gethost` on a first DNS lookup, which pharos's MCP path does not make. The curl install
  has no such gap, because its old versions stay until their daemons exit.

### 6. Burrito leaves

- The `burrito` dependency goes, and with it Zig, `Burrito.wrap`, `refresh_npm_platform_packages`
  and the Burrito pieces of `pharos_runtime_ffi` and `cli` (`burrito_cache_root`,
  `list_pharos_extracts`, the `--doctor` cache lines). The fork stays on GitHub for geex's
  history and pharos's.
- **`pharos --purge-cache`** keeps its name for one release, with a new job: it removes the
  Burrito unpacks that pharos 0.1.x left (`<data>/.burrito/pharos_*`) that no running process's
  command line names. It touches only `pharos_*`, never `geex_*` or anything else in that
  directory: geex 0.2.0's unpacks live there too. It is the same `ps` rule as install.sh. pharos can no longer take the
  fork's `.burrito-in-use` lock, but a 0.1.x process names its unpack in its argv either way.
  It says so and points at `install.sh` for versions.
- `bin/test-burrito.sh`, the Burrito fossil-guard entries and the Burrito wording in the README
  and `/release` skill go, or are rewritten.

### 7. CI and the release

- **`release.yml`** follows geex's layout:
  - a `build` matrix over §2: cached runtime, `PHAROS_RELEASE=1` build, the native check, the
    ADR-034 integration suite run against the packaged tarball (Linux and macOS), and an
    install.sh smoke from `file://`;
  - `publish`, only on `refs/tags/v*`: a normal GitHub release (marked latest) with the
    tarballs, `SHA256SUMS` and `install.sh`. Then npm publish of the four
    platform packages, then `pharos-mcp`, all on `latest` and through the existing trusted
    publishing.
  - Branch runs (`ci/**`) build and test everything and publish nothing.
  - *Added 2026-10-20, after 0.2.2:* npm accepts a publish and then validates it (a malware
    scan) before serving it. For 0.2.2 that took 2–3 min for the x64 packages and about 55 min
    for the two arm64 ones. A re-publish meanwhile answers E409 "previously staged version".
    Two things made it recoverable without a new version:
    - the publish job waits until npm can install every platform package before it publishes
      `pharos-mcp`, so no user could install a main package whose platform package was missing;
    - every publish skips a version npm already serves, and a manual `release.yml` run with
      `republish: <version>` refills the npm packages from that version's GitHub release
      (SHA256SUMS checked) and publishes what is missing.

    The Trusted Publisher configs (`npm trust list`) allow publish and stage publish on every
    package, so nothing needed approving.
- **`smoke.yml`** (post-release, fresh runners, from public URLs) runs on ubuntu-22.04/24.04,
  their -arm variants, macos-14/15 and macos-15-intel:
  - install twice: `npm i -g pharos-mcp@<v>` in one job, and the `curl … install.sh | sh` one-liner
    in another;
  - MCP `initialize` and `tools/list`;
  - a real LSP answer: pyright from npm, a hover on a fixture Python file;
  - a second shim joins the same daemon (`pharos daemon status` shows 2 sessions);
  - the daemon exits when idle (`PHAROS_DAEMON_IDLE_SECS=5`);
  - after `npm i -g`, no `node` process sits in the MCP server's process tree, which proves the
    postinstall swap worked;
  - an `npm i -g --ignore-scripts` job proves the JS fallback still answers `initialize`.

  `PHAROS_MODE=daemon` is set throughout, so a fallback would fail the run.

## Consequences

- One directory per version, and nothing unpacks at run time. There is no second cache, no Zig,
  and no fork to keep.
- Building OTP is our job now: an OTP or OpenSSL update is a change to `rel/build-runtime.sh`,
  made in geex and copied here (or the other way), and CI rebuilds it once per target.
- Linux needs glibc 2.35+: Ubuntu 22.04, Debian 12, RHEL 9 or newer. Alpine and older distros
  lose pharos, where Burrito's musl ERTS ran there. With about 61 npm downloads a month, a
  manylinux or musl build isn't worth it yet, so the loss is made loud instead (§5, and the
  release notes), and pharos-mcp@0.1.4 stays installable there. A lower floor (a
  manylinux_2_28 container build) and a musl target are on the roadmap, for when someone asks.
- `PHAROS_INSTALL_DIR`'s change of meaning (§4) goes in the release notes.
- darwin-x64 depends on the macos-15-intel image, which GitHub will retire too. When it goes,
  `@pharos-mcp/darwin-x64` stops getting releases unless we cross-build.
- npm installs and curl installs differ in one way, the in-place update (§5). Both are documented.

## Alternatives considered

- **Build the `.beam` files once and pair them with each target's ERTS.** This was the original
  plan. Rejected: geex showed that building natively per runner is no harder, and it keeps the VM
  and the bytecode from one OTP.
- **Keep the Burrito fork.** Rejected: it carries a self-extracting cache, Zig 0.15.2 pinned
  against Burrito 1.6's 0.16, and a fork, all for a wrapper the shim already replaces.
- **A third-party ERTS build** (e.g. beam-machine, Burrito's precompiled ERTS). Rejected for the
  same reason as geex: pinned sources built ourselves, with static OpenSSL, are auditable, and a
  build matrix we control is no extra work once it exists.
- **npm postinstall copying the release into the versioned layout**, so npm and curl installs
  share pruning. Rejected for now: it writes outside `node_modules` (read-only `HOME`s, CI
  containers), and `npm uninstall` would leave copies behind. The in-place gap it would close is
  small (§5).
- **A JS wrapper that stays resident.** Rejected: that is the 44 MB per session ADR-034 set out
  to remove. It remains only as the `--ignore-scripts` fallback.
