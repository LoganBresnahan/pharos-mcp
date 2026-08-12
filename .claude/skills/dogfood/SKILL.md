---
name: dogfood
description: Drive a real pharos against real LSP servers to verify behaviour the gleeunit suite structurally cannot reach — no fake LSP, real rust-analyzer / gopls / pyright / jdtls answering real requests. Covers the four handles (Tier-1 regression, 23-language sweep, out-of-band stdio probes, live MCP host), the dev-wrapper-vs-binary trap that hides a whole bug class, and the Burrito cache staleness that silently runs old code. Use after changes to the tool surface, the transports, or anything touching stdio framing.
---

# /dogfood — drive pharos against real LSPs

The gleeunit suite has no LSP in it. Everything about how pharos behaves when a
real rust-analyzer takes 40s to index, or jdtls spawns grandchildren, or an LSP
answers `-32601`, is only observable here. That is the whole point of this
layer ([ADR-009](../../../doc/adr/009-dogfood-via-claude-code.md)).

## Two traps to internalise before running anything

**1. `bin/pharos-dev` cannot see a whole bug class.** The dev wrapper runs
*interactive* Erlang; the Burrito release runs `-noshell -mode embedded
-noinput`. The stdio bug class fixed in commit `e857dce` is **invisible under
`pharos-dev`**. So:

> Any change touching `pharos_stdin_ffi`, the log writer, NDJSON framing, or port
> operations must be verified against the **binary**, not just `pharos-dev`.

**2. The Burrito cache will silently run old code.** The cache key is
`pharos_erts-<erts>_<app_vsn>` and does **not** include payload bytes, so
rebuilding at the same version re-runs the previous extract. Full sequence:

```sh
rm -rf ~/.local/share/.burrito/pharos_erts-*
MIX_ENV=prod mix release --overwrite
node npm/pharos-mcp/scripts/postinstall.js    # warm re-extract
# then /mcp reconnect pharos in the host
```

Prefer `mix release.dev`, which does the cache wipe for you and is the reason
that task exists.

> **[doc/dogfood.md](../../../doc/dogfood.md) is stale on this point** — it warns
> about copying `burrito_out/` into `npm/vendor/` before running postinstall.
> That layout is gone: `npm/vendor/` no longer exists, `mix release`'s
> `refresh_npm_platform_packages` step now copies each binary into
> `npm/@pharos-mcp/<platform>/bin/` automatically, and postinstall resolves it
> via `require.resolve` on the platform sub-package. The staleness trap it
> describes no longer applies; the *cache* trap above still does.

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
PHAROS_TEST_BIN=burrito_out/pharos_linux_x64 \
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

After rebuilding, `/mcp` reconnect so the host spawns the fresh binary.

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
| Transports (stdio/HTTP) | `test-both-transports.py` |
| Release-shaped change | 2 against the binary, plus 4 |

## Report

```
DOGFOOD — pharos <dev|binary vX.Y.Z+sha>
  handle      <which, and why that one>
  cache       <wiped + vendor refreshed | n/a for dev wrapper>
  results     <n> pass · <n> fail · <n> PASS(-32601) · <n> timeout-retried
  failures    <cell> — <reason> — <is it pharos or the LSP?>
  findings    <what a commit/ADR should capture; else "none">
```

Always separate *pharos defects* from *LSP capability gaps* in the report. The
`-32601` cells and the serial-mode slowness are properties of the servers, and
reporting them as pharos failures is the most common way this pass misleads.
