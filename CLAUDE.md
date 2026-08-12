# pharos 🗼

An MCP server that bridges LLM agents to real LSP servers — symbol resolution,
references, definitions, and refactors answered by rust-analyzer / gopls / jdtls
/ pyright / gleam-lsp rather than by grep. See [README.md](README.md) for the
pitch and the install matrix, [doc/architecture.md](doc/architecture.md) for the
process tree.

**This file is the always-loaded static layer — invariants + where to look. It is
NOT project state.** What shipped and what's next lives in git log and
`.private/roadmap.md`; rationale in [doc/adr/](doc/adr/); the operational map in
[doc/architecture.md](doc/architecture.md). Those are authoritative and current;
this file and memory are as-of-write-time and can drift. When in doubt, read the
code.

## Start here

- **`/orient`** — read-only session-start bearing: reconstructs "you are here"
  from commits + roadmap + ADRs. Run it first in a fresh window.
- **`/shipshape`** — verifies the repo is in order (tests / docs / conventions /
  deps). Run before commits. It *proposes* fixes; it does not apply them unless
  asked.
- **`/release`** — cuts a versioned Burrito + npm release. The only sanctioned
  path through the two-file version bump and the Burrito cache foot-gun.
- **`/dogfood`** — drives a real pharos against real LSPs to verify behaviour the
  unit suite structurally cannot reach.

## Architecture in one breath

Gleam on the BEAM, compiled and released through **Mix** (not the Gleam CLI).
`src/` is Gleam plus a thin layer of Erlang FFI shims for what Gleam can't
express:

- `src/pharos/mcp/` — JSON-RPC + MCP protocol, stdio and HTTP transports,
  session tracking.
- `src/pharos/lsp/` — the pool, `lsp_proc` (one GenServer per
  `(language, workspace, server)` wrapping one OS Port), readiness gating,
  method routing.
- `src/pharos/tools/` — the curated MCP tool surface, one module per tool family.
- `src/pharos/log/` — the logging facade: writer, ring buffer, filter.
- `src/pharos_*_ffi.erl` — Erlang shims. These exist because Gleam has no way to
  express the thing (`pharos_lsp_dyn_sup.erl` is `simple_one_for_one`, which
  `gleam_otp` doesn't expose; `pharos_stdin_ffi.erl` writes fd 1 unbuffered).
  Reach for a shim only when Gleam genuinely cannot express it, and say why in a
  module comment.

Supervision, request lifecycle, the timeout map, and the sync/async boundaries
are all drawn in [doc/architecture.md](doc/architecture.md). Read it before
changing anything that spawns, blocks, or times out — it is written to answer
"which process is hung and which timeout was supposed to bound it."

## Sacred invariants — breaking one breaks the project

1. **stdout is the JSON-RPC channel.** Under the stdio transport, *only*
   JSON-RPC frames may reach stdout — nothing else, ever. Diagnostics go to
   stderr, the ring buffer, or the log file. `pharos_stdin_ffi.erl` writes fd 1
   directly and unbuffered precisely so nothing else can interleave; a stray
   `io.println` in a request path corrupts the protocol stream for every client.
   CI's smoke test asserts an exact response-line count, which is what catches
   this.

2. **Mix drives the build; the Gleam CLI does not.** Use `mix gleam.test`, never
   `gleam test`. `gleam.toml` is duplicated from `mix.exs` only so the Gleam
   compiler classifies dev deps correctly — **`mix.exs` is authoritative for
   version resolution**, and the file says so at the top. Two lockfiles exist
   (`mix.lock` and `manifest.toml`) with nothing keeping them honest; they have
   drifted before. Change one, reconcile the other, verify entry by entry.

3. **The ADR-011 app-name workaround must survive.** `fix_app_names/1` and the
   `deps.compile` / `compile` alias chain in `mix.exs` look like dead weight and
   are not: `hpack_erl` publishes an OTP app named `hpack`, and Mix refuses to
   build without the wrapper `.app` plus the symlinked mirror dir. Retirement has
   two conditions — read
   [ADR-011](doc/adr/011-mix-app-name-symlink-workaround.md) before touching it.
   Symptom of removing it too early: `Could not find application :hpack`.

4. **Multi-instance is the norm.** One pharos per MCP client session, several
   concurrently. Never add a global single-instance lock, and partition every
   piece of on-disk state by the owning pharos PID
   ([ADR-030](doc/adr/030-process-lifecycle-hardening.md)).

5. **Burrito keys its extracted runtime by version string.** Same version =
   the launcher silently reuses the previously extracted BEAM files, so a fresh
   binary runs *old* code. Either wipe the cache or bump the version; never
   assume a rebuild took effect. `mix release.dev` wipes for you — prefer it over
   a bare `mix release`. This has bitten the project before, which is why
   `mix.exs` appends a per-build `+<sha>` suffix.

## Build / test / run

```sh
mix compile --warnings-as-errors   # what CI compiles with
mix gleam.test                     # the suite (194 at last count)
mix start                          # run the stdio server on this shell
bin/pharos-dev                     # dev wrapper for MCP-client use
mix release.dev                    # wipe Burrito cache + rebuild all 5 targets
mix release.prod <vsn>             # bump both version files, commit, tag, build
```

Toolchain is pinned in [.tool-versions](.tool-versions) and must match the
versions in both CI workflows — those pins have drifted apart before. The
release path additionally needs **Zig 0.15.2** (`burrito` pins it; see the
constraint comment in `mix.exs`) and `xz`.

**Ship bar: the suite green twice in a row**, plus a release build when anything
under `mix.exs`, `mix.lock`, `manifest.toml`, or `rel/` moved. That last clause
is load-bearing: Burrito failures land at the *wrap* step, after compile and
assemble both pass, so `mix gleam.test` stays green while releases break.

## Conventions when you touch code

**Logging** ([ADR-022](doc/adr/022-logging-conventions.md)): `at_with_fields` /
`fields_at` is the canonical shape for new code. Anything a programmatic consumer
might extract goes in `fields`; free-form prose goes in `message`. Bad:
`"request id=42 finished in 120ms"`. Good: `message = "request finished"`,
`fields = [#("id", "42"), #("duration_ms", "120")]`. The older string-jammed
`log.info_at` call sites stay — migrate them opportunistically when next touched,
don't sweep them.

**Tools** (`src/pharos/tools/`): the surface is *curated*, not schema-generated
([ADR-006](doc/adr/006-curated-tools-no-schema.md)) — adding a tool is a
deliberate act with a hand-written description, because every description is
permanent context cost in the agent's window. LSP responses pass through as JSON
by default; `format: "compact"` is opt-in per tool
([ADR-023](doc/adr/023-compact-response-format.md)).

**No user-visible language assumptions.** pharos wraps ~23 languages; rust was
merely first. Error strings, tool descriptions, and examples must be
language-neutral. CI enforces this with a **fossil guard** that greps `src/` and
`lib/` for a list of known-bad phrases (e.g. `"rust-analyzer failed`,
`.rs files;`) and fails the build on a hit. When you fix a bug whose root cause
was a hardcoded assumption, add its signature to the guard in the same commit —
that is what the list is for.

**No NIFs — a v1.0 constraint, not a permanent law.**
[ADR-030](doc/adr/030-process-lifecycle-hardening.md) rules out NIFs for v1.0 and
explicitly defers the one wanted case (`PR_SET_PDEATHSIG` against orphaned LSP
children) to v1.1, on the grounds that a NIF plus a Zig shim is too much surface
for the release. Treat adding native code as an ADR-level decision, and prefer a
separately distributed, checksum-pinned *executable* over anything linked into
the BEAM.

## Docs discipline

- **Decisions → ADR** (`doc/adr/NNN-slug.md`, Nygard-style, indexed in
  `doc/adr/README.md`). A new dependency, transport, tool-surface change, or an
  approach adopted-and-rejected needs an ADR. Implementation detail is not a
  decision. Keep the index table in sync in the same commit.
- **Operational mechanics → [doc/architecture.md](doc/architecture.md)**: the
  process tree, lifecycles, timeout map. If you change what spawns or what
  blocks, this doc changes with it — it is explicitly the "when something hangs,
  look here" doc, so drift makes it actively harmful.
- **Field reports → `doc/dogfood-*.md`, `doc/m*-test-plan.md`**: dated records of
  driving real LSPs. Append-only; a finding graduates into a commit or ADR and
  the report cites it.
- **`.private/` is gitignored** — `roadmap.md`, `release.md`, `business-strategy.md`
  and the benchmark plans live there and are *local-only*. Read them for
  direction, never assume a collaborator or CI can see them, and never move
  their content into tracked files without asking.

## Commits

Conventional-commit prefixes (`fix(scope):`, `chore(deps):`, `ci:`, `doc:`) —
match what `git log` already does. The body carries the *why*, especially the
non-obvious ones: what you rejected and the reason, so the next person doesn't
retry it. End every commit with a `Co-Authored-By: Claude <model>` trailer (the
model string is per-session). Commit only when asked; branch first if on `main`.

## Names & paths

- repo dir: `pharos-mcp` — but the app, binary, and OTP application are all
  `pharos`. Old paths referencing `/home/oof/pharos` are stale.
- npm: `pharos-mcp` (main) with five `@pharos-mcp/<platform>` sub-packages, each
  carrying one Burrito binary; the main package lists them as
  `optionalDependencies`.
- env vars: all `PHAROS_*` — transport (`PHAROS_TRANSPORT`, `PHAROS_HTTP_PORT`,
  `PHAROS_HTTP_BIND`, `PHAROS_HTTP_PORT_FILE`, `PHAROS_BRIDGE_PORT`), logging
  (`PHAROS_LOG`, `PHAROS_LOG_FILE`, `PHAROS_LOG_STDERR`, `PHAROS_LOG_RING`,
  `PHAROS_SASL`, `PHAROS_TRACE_LSP`), build/release (`PHAROS_RELEASE`,
  `PHAROS_BUILD_ID`, `PHAROS_INSTALL_DIR`, `PHAROS_SKIP_POSTINSTALL`), and
  behaviour (`PHAROS_CONFIG_FILE`, `PHAROS_TOOLS`, `PHAROS_WARM_LANGS`,
  `PHAROS_MEMORY_ROOT`, `PHAROS_USER_MEMORY_ROOT`).
- runtime state: `~/.local/share/pharos/instances/<pharos-pid>/` for per-instance
  LSP child tracking; Burrito's extracted runtimes in `~/.local/share/.burrito/`
  (XDG **data**, not cache — the wrong-XDG-var bug is in the fossil guard).

⚠ Dogfooding runs pharos against **your own machine's LSPs and caches** (jdtls
workspaces, `~/.m2`, cargo target dirs). A dogfood run that wipes or rebuilds
those touches your real development environment, not a sandbox — scope the
fixtures deliberately.
