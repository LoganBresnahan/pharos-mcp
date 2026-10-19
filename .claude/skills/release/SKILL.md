---
name: release
description: Cut a versioned pharos release — bump the version in both files, build and run this machine's release locally, dry-run the per-target pipeline on a ci/** branch, then push the tag that drives the GitHub Actions build → publish (GitHub release with install.sh, npm) → post-release smoke. Handles the two-version-file duality and npm's install-document lag. Run when shipping a new version; requires the suite green twice first.
---

# /release — cut and ship a version

A pharos release (ADR-035) publishes **a GitHub release** (four tarballs,
`SHA256SUMS`, `install.sh`) and **five npm packages** (four
`@pharos-mcp/<platform>` packages plus `pharos-mcp`), under the maintainer's
identity. Publishing is irreversible in practice (npm unpublish is heavily
restricted, and `install.sh` users fetch `releases/latest`), so this skill is
deliberate about the order and about what gets verified *before* the tag is
pushed.

Targets: `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`. There is no
Windows build; Windows users run pharos inside WSL.

**Preconditions — refuse to proceed if unmet:**

1. Working tree clean (the version bump commits, so dirty state would sweep
   unrelated work into a release commit).
2. Ship bar: suite green **twice** — run it, don't trust memory.
3. `mix release.dev` succeeds locally (needs `cargo` for `shim/`).
4. `/shipshape` clean, or its findings explicitly accepted by the user.

**Never push the tag before the dry run passes.** The tag *is* the trigger —
`.github/workflows/release.yml` publishes only for `refs/tags/v*`, and a bad tag
means a failed public pipeline you then have to clean up.

## 0. History

`mix release.prod` had never worked until 6b24d79: `d4e9058` renamed
`@version` to `@version_base` without updating the task, so `v0.1.0` through
`v0.1.4` were bumped and tagged **by hand**, on ordinary `fix(...)` commits.
`v0.2.0-rc.1` (ada6289) and `v0.2.0` (fc29e0c) are the first tags with the
task's `chore: release v<vsn>` signature.

Still treat the task as lightly exercised. Verify each step's effect rather than
trusting it — after it returns, confirm both version files, the commit, and the
tag. If you change it, re-verify on a **throwaway branch**: its failure modes
past the first step come *after* `git commit` and `git tag`. Delete the branch,
the tag, and the test build afterwards.

## 1. Decide the version, confirm it

SemVer; `0.x.y` still signals breaking-changes-allowed. Confirm the number with
the user rather than inferring it — the tag is public and permanent. A
prerelease (`0.3.0-rc.1`) publishes to npm's `next` tag instead of `latest`,
which makes it the safe way to try a risky release first.

Check what's already out so you don't collide:

```bash
git tag --list 'v*' | sort -V | tail -5
npm view pharos-mcp dist-tags
```

## 2. Dry-run the pipeline on a `ci/**` branch

`release.yml` runs on any `ci/**` branch push and does everything except
publish: each target builds natively on its own runner (linux on
ubuntu-22.04 for the glibc 2.35 floor, macOS on macos-14 and macos-15-intel)
with `PHAROS_RELEASE=1` and the runtime `rel/build-runtime.sh` builds, so the
native check is enforced; then the ADR-034 integration suite runs against the
release, and `rel/smoke.sh` installs the tarball through `install.sh` and
drives it as an MCP client, a pyright hover included.

```bash
git push origin HEAD:ci/release-<vsn>
gh run watch          # all four builds must pass
```

This is the only place the macOS and arm64 builds run before a publish, so do
it for anything but a trivial patch. Delete the branch afterwards.

## 3. Bump the version, build locally

```bash
mix release.prod <vsn>
```

It bumps **both** version files, commits `chore: release v<vsn>`, tags
`v<vsn>`, and builds this machine's target. Both files, or the build is
inconsistent: `mix.exs` (`@version_base`) drives the OTP application `vsn`
that `pharos/version` reads for `--version`, MCP `serverInfo`, and outbound
`clientInfo`; `gleam.toml` drives the Gleam compiler's view. Shipping them out
of sync is exactly the class of bug `9b92aec` fixed (0.1.3 shipped identifying
itself as "0.1.2"). CI also refuses a tag that doesn't match `mix.exs`.

Two things about the build are load-bearing:

- **`mix do compile + release` in ONE invocation** (the task does this).
  Splitting it into two `mix` calls breaks
  [ADR-011](../../../doc/adr/011-mix-app-name-symlink-workaround.md)'s `hpack`
  workaround — the second VM re-walks deps without re-firing the alias and fails
  with `Could not find application :hpack`.
- **A local build is not a release build.** Without `PHAROS_RELEASE=1` the
  version carries a `+<sha>` suffix and the native check only prints notes;
  with the system OTP instead of `rel/build-runtime.sh`'s, it would fail. That
  is fine: the local build checks that the tree builds and runs, and step 2's
  dry run checks the real thing.

## 4. Verify the local build

```bash
ls -l _build/package/                                   # pharos-<vsn>+<sha>-<target>.tar.gz, SHA256SUMS
_build/prod/rel/pharos/bin/pharos --version             # pharos <vsn>+<sha>
_build/prod/rel/pharos/bin/pharos --doctor
python3 -I test/daemon/integration.py --release _build/prod/rel/pharos --shim _build/prod/rel/pharos/bin/pharos
```

Check by **exit status and artifact timestamps**, never by scrollback. If you
backgrounded the build, do not trust a wrapper's exit code; read the build's
own status.

## 5. Push the tag — this triggers the public pipeline

```bash
git push && git push --tags
```

Three stages, each gating the next:

1. **build** — the four native builds, exactly as in the dry run.
2. **publish** — the GitHub release (marked latest) with the tarballs,
   `SHA256SUMS` and `install.sh`; then the four platform packages; then a wait
   until npm can install every one of them, plus npm's install-document
   max-age (300 s); then `pharos-mcp`, via **npm OIDC trusted publishing with
   provenance** (no token). The wait exists because publishing `pharos-mcp`
   while the CDN still serves an install document without the new platform
   version makes installs skip the optional dependency (4ed8d23, eb5ec52).
3. **smoke** — `smoke.yml` on fresh runners: `curl … install.sh | sh` on
   seven runners, `npm i -g pharos-mcp` on the same seven, and an
   `--ignore-scripts` install that exercises the JS fallback launcher.

A tag's run is never cancelled. Do not try to abort a running publish job; let it
finish and correct forward.

If an npm smoke fails with `ETARGET` or a missing platform package right after
publish, suspect registry/CDN lag before suspecting the release: rerun the
failed jobs a few minutes later (`gh run rerun <id> --failed`).

## 6. Verify what actually shipped

```bash
gh release view v<vsn>
npm view pharos-mcp dist-tags
npm view pharos-mcp optionalDependencies
```

The smoke stage installs both ways on clean runners; to check by hand, install
into a throwaway HOME so your own install is untouched:

```bash
sh rel/smoke.sh --version <vsn> --lsp pyright
```

## Report

```
RELEASE — pharos v<vsn>
  preconditions  suite ×2 ✓ · tree clean ✓ · shipshape <state>
  dry run        ci/release-<vsn> · 4/4 builds ✓
  local build    --version/--doctor ✓ · integration ✓
  pipeline       build 4/4 ✓ · publish ✓ · smoke <n>/15 ✓
  published      GH release v<vsn> · npm pharos-mcp@<vsn> (<dist-tag>) + 4 platform pkgs
```
