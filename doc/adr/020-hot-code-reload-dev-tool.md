# 020. Hot code reload tool for dev iteration

**Status:** Proposed
**Date:** 2026-05-08

## Context

M11 dogfood (Run 4) made the dev iteration loop expensive enough to call out. Every code change to pharos forces a five-step manual sequence:

1. `MIX_ENV=prod mix release --overwrite` (~10s for an incremental release; longer cold)
2. `pkill -9 -f 'pharos_erts.*beam.smp'` to kill the running BEAM
3. `rm -rf ~/.local/share/.burrito/pharos_erts-*` because Burrito's cache key is `<app>_erts-<ver>_<app_version>` and the cache survives binary updates within the same version
4. `node /home/oof/pharos/npm/scripts/postinstall.js` to re-extract the new payload
5. `/mcp reconnect pharos` in Claude Code so the host re-establishes its stdio handshake against the fresh binary

Steps 1, 5 are unavoidable for *any* dev model. Steps 2-4 are pure friction caused by Burrito's extract-on-launch model — by the time pharos has finished extracting on the first launch after a rebuild, the MCP host's 30s connect timeout has fired (M11 fixed this for cold-start production users via the npm postinstall warmup, but the loop above is the dev-time consequence of that same architecture). And step 5 is itself a UX cost — Claude Code's slash-command surface is interactive; there is no CLI reconnect, nor an in-tool path I can drive from a Bash shell.

We ruled out three alternatives during the M11 cycle:

- **Switch dev to `bin/pharos-dev`.** It bypasses Burrito and runs `mix compile` + raw `erl` against `_build/dev/lib/*/ebin/`. Fast, but the runtime is *not* the same: `pharos-dev` runs in interactive mode without `-noshell -mode embedded -noinput`. The entire stdio bug class fixed in commit e857dce (`io:get_line` buffering, fd 0/fd 1 port bypass, `prim_tty` claim of fd 0) would be invisible under `pharos-dev`. We would have shipped pharos with broken stdio for end users. Distribution-blocking bugs hiding behind a different runtime is the wrong trade.
- **Slash-command shortcut.** Custom Claude Code commands run shell, but cannot programmatically reconnect a running MCP server (no `claude mcp reconnect` subcommand exists; in-session reconnect is `/mcp` UI only). At best a custom command saves typing a bash chain — does not eliminate step 5.
- **Tmux/screen send-keys.** `tmux send-keys -t "$TMUX_PANE" "/mcp reconnect pharos" Enter` would automate step 5 *if* the user runs Claude Code inside a multiplexer. Real, but conditional on host setup; not a portable answer.

The remaining option is BEAM-native hot code reload — `code:purge/1` + `code:load_file/1` on each updated beam, with stateful-actor restart for code that changed protocol-level behaviour. Hot reload is exactly the mechanism Erlang releases ship for upgrades-in-place; pharos can use it for dev iteration without taking a position on full upgrade semantics yet (that's a separate discussion if pharos ever ships hot upgrades for end users).

The pivotal question is what stays-the-same when reloading: existing BEAM, existing root supervisor, existing ETS tables (registry, diagnostics cache, lsp_proc_subjects, log ring), existing pool actor with cached LSP procs, existing MCP host connection (no `/mcp` reconnect). Everything keeps running; only module byte-code is swapped. That's precisely the dev-loop win.

What hot reload does not catch:

- Cold-extract-path bugs (Burrito's xz decompression, first-extract permissions, etc.). Those need a full rebuild + reconnect, which we do at the start of each milestone for end-to-end smoke. Hot reload is a daily-driver tool, not a release gate.
- App-callback / supervision-tree changes. `pharos_app_ffi:start/2` runs once at BEAM boot. Editing it means the running tree was started by the *old* code — reload alone doesn't rerun the callback. Same for root_supervisor's child spec changes.
- Stateful-actor protocol changes. If `pool` adds a new `Msg` variant, in-flight messages that pre-date reload still carry the old shape. Restarting the actor is the safe way; in-flight transient state (per-call inflight counters, kept-warm LSP procs) is lost.

Those caveats are why the tool is dev-only and why its description says so.

## Decision

Add an MCP tool `runtime_reload_modules` (category `debug`, sibling of `runtime_kill_lsp`) that:

1. Walks pharos's code-path entry (whatever `:code.lib_dir(:pharos)` returns) for `pharos@*.beam` files. Optionally filters by an explicit module list passed as `modules: ["pharos@tools@tier1@diagnostics", ...]`.
2. For each: calls `:code.purge/1` then `:code.load_file/1`. Both have well-defined "no-op when already current" semantics. Records a per-module result tuple `(module, :loaded | :unchanged | :error reason)`.
3. Optionally kills a caller-named list of supervised actors (`restart_actors: ["stdio_worker", "pool", "writer"]`). Their supervisors restart them on new code per their existing restart strategy. Default: empty list — caller decides which actors to bounce.
4. Returns the structured result so the LLM can see exactly which modules changed and which actors restarted.

Companion: `bin/hot-reload.sh` automating the prerequisite shell side:

```sh
#!/usr/bin/env bash
# Compile + copy beams over Burrito's extract cache, then prompt
# the running pharos to reload via runtime_reload_modules.
mix compile
EXTRACT="$HOME/.local/share/.burrito/pharos_erts-16.1_0.0.1/lib/pharos-0.0.1/ebin"
cp _build/prod/lib/pharos/ebin/*.beam "$EXTRACT/"
cp _build/prod/lib/pharos/ebin/pharos.app "$EXTRACT/"
echo "ready — call runtime_reload_modules via MCP"
```

The script is bash, not part of the npm wrapper. Lives next to `bin/pharos-dev` and `bin/lsp-smoke`. Zero impact on production releases.

The MCP tool ships gated behind `[runtime] reload_enabled = true` in `pharos.toml` (default `false` on production releases) so end users don't accidentally reload pharos out from under themselves on a misclick. Mirrors the existing `trace_calls_enabled` gate from M9.5.

## Consequences

**Wins.**

- Dev iteration drops from a 5-step ~30s loop to a 3-step ~5s loop (`mix compile` + `bin/hot-reload.sh` + `runtime_reload_modules` MCP call). MCP host stays connected throughout.
- The full burrito runtime (`-noshell -mode embedded -noinput`, port-bypassed stdio, real cold-launch beam IDs) stays in scope for every reload — we do not drift away from production semantics the way `pharos-dev` would.
- The "kill the LSP for hover bug" loop becomes the same shape — we already have `runtime_kill_lsp`; adding `runtime_reload_modules` is the matching tool for "kill the pharos code so the next call uses new logic."

**Losses / risks.**

- Caller has to know which actors to restart for protocol-level changes. The reload itself is safe; the reload-without-restart can be silently wrong if a caller forgets. Mitigate with description text + a recommended-restart list per common scenario in the tool docstring.
- Code-path edge cases. If `:code.lib_dir(:pharos)` returns the Burrito extract dir but the dev script forgot to copy a beam, reload silently uses old code. The shell script must be exhaustive (`cp ... *.beam`) and ideally verify post-copy by mtime check.
- Hot reload skips the OTP application start callback. Code that runs only at boot (e.g., `pharos:boot/0`'s `diagnostics_cache.init`) won't re-run. Adding a new ETS table requires either a full reconnect or a manual init call. Document.
- Production users get an unused tool surface. Gating behind config keeps the surface invisible by default; `tools = [...]` filter still applies.

**Follow-ups.**

- A future ADR can extend this into real upgrade semantics if pharos ever ships hot upgrades to end users (`code_change` callbacks on the actors, version-aware mailbox handling). Out of scope for this ADR — dev-only tool first.
- Add a make target / mix alias so `mix hot-reload` runs `bin/hot-reload.sh` for owners who prefer the Mix surface.
- Once stable, consider auto-firing `runtime_reload_modules` from the shell script via `claude -p` headless mode — but that's the same "spawn new session" trap from the alternatives list and doesn't pilot the live session, so probably not worth it.

## Alternatives considered

- `pharos-dev` as the default dev runtime — rejected: hides distribution-blocking bugs (commit e857dce class).
- Custom Claude Code slash command — rejected: cannot programmatically reconnect MCP server; CLI surface lacks `mcp reconnect` subcommand.
- Tmux/screen `send-keys` automation — viable for users in a multiplexer; not portable. May still be worth a small `bin/reconnect-via-tmux.sh` helper as a separate fallback.
- Full Erlang release upgrade with `relup` files — overkill for dev, and pharos has no upgrade story for end users yet (M13 ships fresh installs only). Revisit if/when pharos publishes a v1 with semver upgrade promises.
