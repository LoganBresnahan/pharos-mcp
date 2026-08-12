---
name: release
description: Cut a versioned pharos release — bump the version in both files, build all five Burrito targets locally, verify the binaries actually run, then push the tag that drives the GitHub Actions build → smoke → npm-publish pipeline. Handles the Burrito extraction-cache foot-gun and the two-lockfile/two-version-file duality. Run when shipping a new version; requires the suite green twice first.
---

# /release — cut and ship a version

A pharos release moves **six npm packages and five cross-compiled binaries**, and
publishes to a public registry under the maintainer's identity. Publishing is
irreversible in practice (npm unpublish is heavily restricted), so this skill is
deliberate about the order and about what gets verified *before* the tag is
pushed.

**Preconditions — refuse to proceed if unmet:**

1. Working tree clean (the version bump commits, so dirty state would sweep
   unrelated work into a release commit).
2. Ship bar: suite green **twice** — run it, don't trust memory.
3. `mix release.dev` succeeds locally (Zig **0.15.2** and `xz` present).
4. `/shipshape` clean, or its findings explicitly accepted by the user.

**Never push the tag before the local build passes.** The tag *is* the trigger —
`.github/workflows/release.yml` fires on `push: tags`, and a bad tag means a
failed public pipeline you then have to clean up.

## 0. Known defect — `mix release.prod` is broken

`lib/mix/tasks/release/prod.ex` bumps `mix.exs` by matching `@version "..."`, but
commit `9b92aec` (2026-07-10) renamed that attribute to **`@version_base`** and
did not update the task. The regex matches nothing, so the task raises:

```
Could not locate `@version "..."` in mix.exs.
```

It **fails safe** — `bump_mix_exs!` raises before `gleam.toml` is touched and
before anything is committed or tagged, so there is no partial state to unwind.

Until it is fixed (one-line: match `@version_base "\S+"`), do the bump by hand —
step 2 below. If you fix the task in the same session, re-verify by running it on
a throwaway branch, because its failure mode is *after* `git commit` and
`git tag` for every step past the first.

## 1. Decide the version, confirm it

SemVer; `0.x.y` still signals breaking-changes-allowed. Confirm the number with
the user rather than inferring it — the tag is public and permanent.

Check what's already out so you don't collide:

```bash
git tag --list 'v*' | sort -V | tail -5
npm view pharos-mcp versions --json | tail -5
```

## 2. Bump the version — BOTH files, they must agree

```bash
# mix.exs      → @version_base "<vsn>"
# gleam.toml   → version = "<vsn>"
```

Both, or the build is inconsistent: `mix.exs` drives the OTP application `vsn`
that `pharos/version` reads for `--version`, MCP `serverInfo`, and outbound
`clientInfo`; `gleam.toml` drives the Gleam compiler's view. Shipping them out of
sync is exactly the class of bug commit `9b92aec` fixed (0.1.3 shipped
identifying itself as "0.1.2").

Then commit and tag:

```bash
git commit -am "chore: release v<vsn>"
git tag v<vsn>
```

## 3. Build all five targets locally

```bash
MIX_ENV=prod PHAROS_RELEASE=1 mix do compile + release --overwrite
```

`PHAROS_RELEASE=1` drops the `+<sha>` dev suffix so the artifact reports the
clean SemVer — this is what CI sets, and what the smoke job asserts against.

Two things about this command are load-bearing:

- **`mix do compile + release` in ONE invocation.** Splitting it into two `mix`
  calls breaks [ADR-011](../../../doc/adr/011-mix-app-name-symlink-workaround.md)'s
  `hpack` workaround — the second VM re-walks deps without re-firing the alias
  and fails with `Could not find application :hpack`.
- **A cold `_build` fails before it starts** for the same reason. Run
  `mix compile` first if `_build/prod` was wiped.

Because the version changed, Burrito's extraction cache keys on a *new*
directory, so no cache wipe is needed here — that is `mix release.dev`'s problem,
not this one.

## 4. Verify the binaries — locally, before the tag leaves your machine

```bash
ls -la burrito_out/          # all five, freshly dated
./burrito_out/pharos_linux_x64 --version    # must print exactly "pharos <vsn>"
./burrito_out/pharos_linux_x64 --doctor
```

Check by **exit status and artifact timestamps**, never by scrollback — Burrito
prints a lot and a stale binary from a previous build looks identical in a
listing until you read the date. If you backgrounded the build, do not trust a
wrapper's exit code; read the build's own status.

Then the MCP handshake, the same one CI runs:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"smoke"}}}' \
  | ./burrito_out/pharos_linux_x64
```

Only `linux_x64` is locally verifiable; the other four are cross-compiled and get
their first real execution in CI's smoke matrix. That asymmetry is why the tag
push is a checkpoint, not the finish line.

## 5. Dry-run the pipeline first (recommended)

`release.yml` has a `workflow_dispatch` with a `dry_run` input that builds and
smoke-tests all five platforms but skips npm publish and the GH Release:

```bash
gh workflow run release.yml -f dry_run=true
gh run watch
```

This is the only way to exercise the macOS and Windows binaries before
committing to a publish. Worth it for anything but a trivial patch.

## 6. Push the tag — this triggers the public pipeline

```bash
git push && git push --tags
```

Three jobs run in sequence, each gating the next:

1. **build** — all five targets on one Linux host, `PHAROS_RELEASE=1`, version
   extracted from the tag; stages the `npm/` tree and raw binaries as artifacts.
2. **smoke** — per-platform matrix: `--version` must equal `pharos <vsn>` exactly,
   `--doctor` must pass, and the MCP init + `tools/list` + `echo` handshake must
   answer. This is where a broken cross-compile surfaces.
3. **publish** — the five `@pharos-mcp/<platform>` packages, then the main
   `pharos-mcp` package, via **npm OIDC trusted publishing with provenance**
   (needs `id-token: write`), plus the GitHub Release.

Concurrency is set to `cancel-in-progress: false` — a release is never cancelled
mid-publish. Do not try to abort a running publish job; let it finish and correct
forward.

```bash
gh run watch          # follow it
```

## 7. Verify what actually shipped

```bash
npm view pharos-mcp version
npm view pharos-mcp optionalDependencies
```

Then install clean and run it — the postinstall path (platform detection, binary
resolution) is only exercised by a real install:

```bash
cd "$(mktemp -d)" && npm i pharos-mcp && npx pharos --version
```

## Report

```
RELEASE — pharos v<vsn>
  preconditions  suite ×2 ✓ · tree clean ✓ · shipshape <state>
  local build    5/5 targets · linux_x64 --version/--doctor/handshake ✓
  dry run        <ran|skipped>
  pipeline       build ✓ · smoke <n>/5 ✓ · publish ✓
  published      npm pharos-mcp@<vsn> (+5 platform pkgs) · GH Release ✓
  verified       clean install ✓
```
