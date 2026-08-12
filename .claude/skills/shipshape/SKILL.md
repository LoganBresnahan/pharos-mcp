---
name: shipshape
description: Verify pharos is shipshape — the build compiles warnings-clean, the suite is green twice, the release path still wraps, docs (architecture.md / ADR index / roadmap) match the code, and the conventions hold (fossil guard, logging shape, stdout purity, lockfile agreement, toolchain pins). Use after substantive changes, before commits, or when asked whether the project is in order.
---

# /shipshape — repo verification pass

Four gates: **Tests**, **Docs**, **Conventions**, **Deps**. Check all four even
if one fails early — the deliverable is the full report, not the first failure.
Propose fixes; do **not** apply them unless the user asks.

## 0. Scope the audit

```bash
git status --short && git diff HEAD --stat && git branch --show-current
```

Uncommitted work is the primary audit surface; spot-check the rest. If the user
asks for a full audit, the scope is the whole repo.

## 1. Tests gate

Compile the way CI does — warnings are errors there and merely noisy locally, so
a local `mix compile` can pass while CI fails:

```bash
mix compile --warnings-as-errors
```

Then the suite, green **twice in a row** (the flaky bar):

```bash
mix gleam.test
mix gleam.test
```

**The release gate is conditional and load-bearing.** If anything under
`mix.exs`, `mix.lock`, `manifest.toml`, `gleam.toml`, `rel/`, or `.tool-versions`
moved, a green suite proves nothing about releases: Burrito failures land at the
*wrap* step, after compile and assemble both succeed. Run it:

```bash
mix release.dev
```

Verify by **exit status and artifact timestamps**, not by scrollback — and not by
a wrapper's exit code if you backgrounded it. All five files in `burrito_out/`
must be freshly dated, and the binary must run:

```bash
ls -la burrito_out/ && ./burrito_out/pharos_linux_x64 --version
```

Needs Zig 0.15.2 and `xz`. A cold `_build/dev` makes `mix release.dev` fail on
`hpack_erl` before it starts — that is the [ADR-011](../../../doc/adr/011-mix-app-name-symlink-workaround.md)
alias not having fired yet, not a regression. Run `mix compile` first.

Finally, the end-to-end smoke path CI runs — it is the only check that catches
**stdout contamination**, which no unit test can:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | mix start | grep -c '^{"jsonrpc"'
```

The notification line must produce no response. Any count other than the number
of *requests* means something is writing to stdout that shouldn't be.

## 2. Docs gate

- **`doc/architecture.md` vs the code.** This doc exists to answer "which process
  is hung and which timeout was supposed to bound it," so drift makes it actively
  harmful rather than merely stale. If the diff touched supervision, spawning,
  transports, or timeouts, diff it against the process tree and the timeout map.
- **ADR index sync.** Every `doc/adr/NNN-*.md` must appear in
  `doc/adr/README.md`'s table with a status:
  ```bash
  ls doc/adr/*.md | grep -oE '[0-9]{3}[a-z]?' | sort -u > /tmp/adr_files
  grep -oE '^\| [0-9]{3}[a-z]?' doc/adr/README.md | grep -oE '[0-9]{3}[a-z]?' | sort -u > /tmp/adr_index
  diff /tmp/adr_files /tmp/adr_index
  ```
  Note `017a` exists — the numbering is not strictly integral. And the
  "Anticipated future ADRs" table at the bottom **reuses numbers 023–027 that
  accepted ADRs already hold**; that collision is pre-existing, so don't report
  it as new breakage, but don't resolve a number against it either.
- **A decision without an ADR is a finding.** New dependency, transport,
  tool-surface change, or an approach adopted-and-rejected all need one.
- **`.private/roadmap.md`** — if the diff lands a roadmap item, is it reflected?
  Remember `.private/` is gitignored, so this is a local-only check and a fresh
  clone can't perform it.
- **README claims.** It carries an install matrix and a language table that go
  stale silently. Spot-check against `src/pharos/lsp/languages.gleam` when
  language support moved.

## 3. Conventions gate

**Run the fossil guard locally.** It lives only in CI
(`.github/workflows/ci.yml`), so it fails *after* you push unless you run it:

```bash
grep -rEn --include='*.gleam' --include='*.erl' --include='*.ex' \
  --exclude-dir=deps --exclude-dir=_build --exclude-dir=build \
  -e '"rust-analyzer failed' -e 'v0\.1 only' -e '"v0\.1 ' -e '\.rs files;' \
  -e 'file:///home/user/project/src/main\.rs' \
  -e 'filename:basedir\(user_cache' -e 'burrito_runtime' \
  src/ lib/
```

Any hit fails CI. Also check `npm/pharos-mcp/scripts/postinstall.js` for a bare
`process.env.APPDATA` (must be `LOCALAPPDATA`). If the diff fixed a bug whose
root cause was a hardcoded assumption, the guard should have gained its
signature in the same commit — a fix without a guard entry is a finding.

**Logging shape** ([ADR-022](../../../doc/adr/022-logging-conventions.md)): new
call sites use `at_with_fields` / `fields_at`, with extractable values in
`fields` and prose in `message`. String-jammed `log.info_at` in *new* code is a
finding; pre-existing ones are not — they migrate opportunistically.

**Language neutrality:** no user-visible string may assume a language. rust was
first, not special.

**Erlang FFI justification:** a new `src/pharos_*_ffi.erl` needs a module comment
saying what Gleam couldn't express. "Easier in Erlang" is not a reason.

**No new NIFs** without an ADR — see ADR-030's v1.0 constraint.

## 4. Deps gate

**The two lockfiles must agree.** `mix.lock` and `manifest.toml` are independent
and nothing keeps them honest; they have silently diverged before.

```bash
for p in $(grep -oP 'name = "\K[^"]+' manifest.toml); do
  m=$(grep -oP "\"$p\": \{:hex, :$p, \"\K[^\"]+" mix.lock)
  g=$(grep -oP "name = \"$p\", version = \"\K[^\"]+" manifest.toml)
  [ -n "$m" ] && [ "$m" != "$g" ] && echo "DRIFT $p mix.lock=$m manifest=$g"
done; echo "lockfile check done"
```

**Toolchain pins must match CI.** `.tool-versions` versus the `gleam-version` /
`otp-version` / `elixir-version` in *both* `.github/workflows/ci.yml` and
`release.yml`, plus the Zig pin in `release.yml` against burrito's requirement.
These have drifted before.

**ADR-011 retirement check** — cheap, and the trigger is easy to miss:

```bash
python3 -c "
import re
t=open('manifest.toml').read()
bad=[(m[0],m[1],m[2]) for m in re.findall(r'\{ name = \"([^\"]+)\", version = \"([^\"]+)\".*?otp_app = \"([^\"]+)\"',t) if m[0]!=m[2]]
print('ADR-011 retireable' if not bad else 'ADR-011 stays: '+', '.join(f'{b[0]} {b[1]}->{b[2]}' for b in bad))
"
```

If that prints *retireable*, the `fix_app_names` machinery in `mix.exs` can go —
read the ADR's removal criteria first.

**Outdated deps** are informational, not a failure:

```bash
mix hex.outdated
```

Two known-good pins will show as outdated; both are deliberate and documented at
the pin in `mix.exs` — read the comment before "fixing" either:
`gleam_javascript` (1.0.1 breaks the erlang-target build) and `burrito`
(1.6.0 requires Zig 0.16.0).

## 5. Report

```
SHIPSHAPE — pharos @ <branch> <sha>
  tests       compile ✓/✗ · suite <n> ×2 ✓/✗ · release <ran|skipped: no build files moved> · smoke ✓/✗
  docs        <architecture drift | ADR index gaps | missing ADR | "clean">
  conventions <fossil hits | logging shape | FFI justification | "clean">
  deps        <lockfile drift | pin drift | ADR-011 status | "clean">
  findings    <numbered, most severe first — each with the fix you'd apply>
```

Propose the fixes; apply only on request.
