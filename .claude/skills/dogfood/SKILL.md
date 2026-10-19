---
name: dogfood
description: Drive a real pharos against real LSP servers to verify behaviour the gleeunit suite structurally cannot reach — no fake LSP, real rust-analyzer / gopls / pyright / jdtls answering real requests. Covers the four handles (Tier-1 regression, 23-language sweep, out-of-band stdio probes, live MCP host), the dev-wrapper-vs-binary trap that hides a whole bug class, and the shared daemon that keeps serving the previous build (and its warm LSPs) after a rebuild. Use after changes to the tool surface, the transports, or anything touching stdio framing.
---

# /dogfood — drive pharos against real LSPs

The gleeunit suite has no LSP in it. Everything about how pharos behaves when a
real rust-analyzer takes 40s to index, or jdtls spawns grandchildren, or an LSP
answers `-32601`, is only observable here. That is the whole point of this
layer ([ADR-009](../../../doc/adr/009-dogfood-via-claude-code.md)).

## Two traps to internalise before running anything

**1. `bin/pharos-dev` cannot see a whole bug class.** The dev wrapper runs
*interactive* Erlang; the release runs `-noshell -mode embedded
-noinput`, behind the native shim and the shared daemon (ADR-034). The stdio bug class fixed in commit `e857dce` is **invisible under
`pharos-dev`**. So:

> Any change touching `pharos_stdin_ffi`, the log writer, NDJSON framing, or port
> operations must be verified against the **binary**, not just `pharos-dev`.

**2. A running daemon keeps serving the previous build.** Since 0.2 nothing
extracts at run time ([ADR-035](../../../doc/adr/035-releases-without-burrito.md)),
and a rebuild gets a new `BUILD_ID` and so its own daemon socket. But sessions
already connected stay on the old build's daemon until they end, and an MCP host
pointed at the installed `~/.local/bin/pharos` runs whatever install.sh last put
there, not your `_build`. Full sequence:

```sh
mix release.dev                                   # clean rebuild + _build/package/
PHAROS_DOWNLOAD_URL=file://$PWD/_build/package sh install.sh --force --version <version>
pharos daemon stop --all                          # end the old build's daemons
# then /mcp reconnect pharos in the host; `pharos daemon status` shows the new build
```

`daemon stop --all` stops every pharos daemon on the machine, every build's:
pharos in your *other* MCP host sessions (other Claude Code windows) drops too
and needs its own `/mcp` reconnect. Say so before running it in someone's live
environment. `mix release.dev` prints the exact install.sh line, version
included. Or
skip the install and point the harness or host straight at
`_build/prod/rel/pharos/bin/pharos`.

The daemon also outlives a harness run (it idles out after
`PHAROS_DAEMON_IDLE_SECS`, 30 min by default), and so do its LSPs. A second run
right after the first finds rust-analyzer or jdtls already indexed — `pharos
daemon stop --all` before any run that is meant to measure cold starts. To take
the daemon out of the picture entirely, `PHAROS_MODE=direct` (or `pharos
--direct`) runs one independent BEAM per session, as 0.1.x did.

If results look inexplicably like the previous build, this is why — check it
first, not last.

⚠ **This is not a sandbox.** Dogfood runs drive your machine's real LSPs and
their real caches — jdtls workspaces, `~/.m2`, cargo target dirs. Fixture
cloning and cache clearing touch your actual development environment. Scope
deliberately; never wipe a shared cache to "get a clean run" without saying so.

## The four handles, cheapest first

### Handle 1 — Tier-1 regression across the four bundled languages

Boots `bin/pharos-dev` once per language, drives the canonical Tier 1 tools
against the matching workspace, asserts on stable response shapes. Real
rust-analyzer / gopls / typescript-language-server / pyright / ruff.

```sh
python3 bin/test-suite.py              # all four
python3 bin/test-suite.py rust go      # subset
python3 bin/test-suite-http.py         # the HTTP twin
python3 bin/test-both-transports.py    # both, one invocation
```

Exit codes: `0` all pass, `1` a cell failed, `2` setup failure. The test
workspaces are **machine-specific paths** (`/home/oof/rust_dev`, `…/go_dev`, …)
listed in [doc/dogfood.md](../../../doc/dogfood.md) — on a fresh machine these
must exist or the harness reports setup failure, which is not a pharos bug.

This is the default handle. Reach for it after any tool-surface change.

### Handle 2 — the 23-language × 39-tool sweep

523 cells (23 × 22 LSP-bound tools + 17 global). Needs fixtures cloned first.

```sh
bin/dogfood-fixtures.sh                                  # clone into tmp/fixtures/
python3 bin/dogfood-23lang.py                            # dev / stdio / all
python3 bin/dogfood-23lang.py --transport http
python3 bin/dogfood-23lang.py --profile default
PHAROS_TEST_BIN=_build/prod/rel/pharos/bin/pharos \
  python3 bin/dogfood-23lang.py --label "binary, post-rebuild"
```

**`PHAROS_TEST_BIN` is how you satisfy trap 1** — point the harness at the
release binary rather than the dev wrapper.

Reading the report (`doc/dogfood-23lang.md` by default):

- `PASS (-32601)` means *plumbing works, the LSP doesn't implement the method*.
  That is a pass, not a gap in pharos. Do not "fix" these.
- `FAIL: <reason>` is a real failure.
- On a per-call timeout the harness fires `runtime_set_tool_timeout` and retries
  once, mirroring the LLM-realistic recovery path from
  [ADR-021](../../../doc/adr/021-timeout-resolution-and-autotune.md). A cell that
  passes only after the bump is a latency finding, not a clean pass.

`--label` lands in the report header — always set it, so multiple passes can be
diff-walked instead of overwriting each other's meaning. The serial-mode
languages (heavy LSPs: perl, ruby, java, scala) are slow by design; a full pass
is 30+ minutes.

### Handle 3 — out-of-band stdio probes

Boot-time and config behaviour the live MCP host structurally cannot reach:

```sh
python3 bin/test-missing-binary.py            # ADR-018 BinaryNotFound surfacing
python3 bin/test-config-override.py           # PHAROS_CONFIG_FILE [languages.<id>]
python3 bin/test-subserver-override.py        # [[languages.<id>.servers]] override
python3 bin/test-tool-config.py               # tool timeout / config resolution
python3 bin/test-edges.py                     # edge-case request shapes
```

Cheap, fast, and the only coverage for the failure paths. Run these when touching
config resolution or binary discovery.

### Handle 4 — the live MCP host

The original dogfood loop from ADR-009: point Claude Code's MCP config at pharos
and use it for real work. This is the only handle that evaluates what an LLM
*actually does* with a tool description or a response shape — cost of the
description in context, whether the agent picks the right tool, whether a compact
response is still legible.

After rebuilding, install it and stop the old daemons (trap 2), then `/mcp`
reconnect so the host spawns the fresh shim.

Findings here are not version-controlled by default (ADR-009). A significant one
graduates into a commit message, an ADR, or a dated `doc/dogfood-*.md` report —
otherwise it evaporates.

## Choosing a handle

| Change touched | Minimum handle |
| --- | --- |
| One tool's response shape | 1 (subset), on `pharos-dev` |
| Tool surface / new tool | 1 full, then 4 |
| Config, binary resolution | 3 |
| `pharos_stdin_ffi`, writer, framing, ports | 1 **against the binary** — dev wrapper cannot see it |
| Daemon, shim, session context | `test/daemon/integration.py`, then 1 against the binary with ≥ 2 concurrent sessions |
| Transports (stdio/HTTP) | `test-both-transports.py` |
| Release-shaped change | 2 against the binary, plus 4 |

## Report

```
DOGFOOD — pharos <dev|binary vX.Y.Z+sha>
  handle      <which, and why that one>
  build       <dev wrapper | binary BUILD_ID, old daemons stopped ✓ | direct mode>
  results     <n> pass · <n> fail · <n> PASS(-32601) · <n> timeout-retried
  failures    <cell> — <reason> — <is it pharos or the LSP?>
  findings    <what a commit/ADR should capture; else "none">
```

Always separate *pharos defects* from *LSP capability gaps* in the report. The
`-32601` cells and the serial-mode slowness are properties of the servers, and
reporting them as pharos failures is the most common way this pass misleads.
