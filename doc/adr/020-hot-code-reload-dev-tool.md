# 020. Hot code reload tool for dev iteration

**Status:** Proposed (Deferred 2026-05-08)
**Date:** 2026-05-08

> **Deferral note (2026-05-08).** Implementation deferred. Daily dev iteration
> runs through `bin/pharos-dev` (raw `_build/dev/lib/*/ebin`, no cache, fast);
> milestone-end verification runs through the burrito binary with a manual
> `rm -rf ~/.local/share/.burrito/pharos_erts-*` between rebuilds (see
> `doc/dogfood.md` Prereqs). This trades a known weekly friction step for
> the ~80 LOC + footgun-management cost of building this tool.
>
> Revisit if any of the following occur:
> - `pharos-dev` masks a stdio-class bug that ships in a release (the e857dce
>   class is the canonical example — `pharos-dev` cannot exercise it).
> - Iteration cost on `pharos-dev` climbs (e.g., compile times grow, or we
>   need to dogfood against the binary mid-milestone often enough that
>   reconnect cost dominates).
> - End-user need surfaces for hot upgrades (then the relup discussion in
>   "Follow-ups" becomes the better adoption target, not this dev-only tool).
>
> The design below is preserved as the implementation blueprint when revisited.

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

Add an MCP tool `runtime_reload_modules` (category `debug`, sibling of `runtime_kill_lsp`) plus companion shell script `bin/hot-reload.sh` and meta-flag `--print-extract-dir`. Each piece exists to neuter a specific footgun the naive "just call `code:load_file`" design would walk into.

### Footguns and mitigations

The reason the design is more than ten lines is that hot reload has ten cliffs to keep callers off of. Each numbered item below pairs the failure mode with the specific mitigation.

1. **Stale beams on disk** — `cp` skips files mix didn't recompile (mix's source-mtime cache misses can leave the dest dir holding old beams). Mitigation: `rsync -c` (checksum-based, not mtime); shell script verifies every copied beam's dest mtime exceeds a pre-copy stamp and aborts if any went backwards.
2. **Silent stale "loaded"** — `code:load_file/1` returns `{:module, M}` on success regardless of whether bytes actually changed. The LLM would see "loaded" and trust it. Mitigation: capture `code:module_md5(mod)` before *and* after each load. Report tri-state `:loaded_changed | :loaded_same | :error reason` so the caller can see "you asked for 12 modules, only 3 byte-flipped."
3. **`code:purge/1` kills processes still running old code** — hard purge brings down any process whose code-pointer hasn't advanced. Mitigation: `code:soft_purge/1` by default (refuses with a blocker list if processes still on old code). `force_purge: true` falls back to hard purge. Default behaviour never silently kills processes.
4. **Application callback / supervision tree changed** — `pharos_app_ffi:start/2` and `pharos@root_supervisor` only run their boot logic at BEAM start. Reload alone won't rerun them, so an ETS-table addition or supervisor child-spec change won't take effect. Mitigation: tool diffs md5 of those two modules; if either changed, returns a `warnings` entry telling the caller a full reconnect is required. The tool does not refuse — other modules in the same reload may still be useful — it just makes the partial-staleness loud.
5. **Stateful-actor protocol changes** — adding a new `Msg` variant means in-flight messages from the old shape are still in the mailbox and will crash the new code on receive. Mitigation: caller passes `restart_actors: ["pool", ...]`; tool reports each actor's mailbox length at the moment of restart so the LLM sees how many in-flight messages were dropped. Description text documents common pairings ("changed `pool` Msg variants → restart `pool`").
6. **ETS tables hold old-shape rows** — adding a field to a record stored in an ETS row leaves old rows around with the old shape. Mitigation: `clear_caches: ["diagnostics_cache", "lsp_proc_subjects", "log_ring"]` whitelist of known tables. Default empty; caller decides per change.
7. **Wrong extract dir** — Burrito's cache dir name is `pharos_erts-16.1_0.0.1`, but version strings drift, multiple installs may co-exist, and dev/prod build envs land in different dirs. Hard-coding the path in the shell script breaks the moment any of those move. Mitigation: add a `--print-extract-dir` meta flag to pharos that prints `:code.lib_dir(:pharos)`'s parent and halts. Shell script reads from that. Single source of truth.
8. **Deps' beams accidentally touched** — `cp _build/prod/lib/pharos/ebin/*.beam` only catches our own modules, but a future careless globbing could pull in `gleam_stdlib`, `gleam_otp`, etc. Mitigation: rsync filter `--include='pharos@*.beam' --include='pharos.app' --exclude='*'`. Tool body whitelists `pharos@*` namespace before calling `code:load_file`. Deps changes always require full rebuild + reconnect.
9. **NIFs (`.so` files)** — Erlang requires NIF modules to opt into reload via an `upgrade` callback or the load crashes. Mitigation: pharos currently has zero NIFs (audited at ADR time). Tool refuses to touch any module whose `.beam` declares a NIF and surfaces the refusal in `warnings`. Re-audit if a future dep introduces one.
10. **User forgot to call the reload tool** — easy miss after `mix compile` succeeds: dev edits a file, runs the shell script, then forgets the MCP-side trigger and tests against old code. Mitigation: shell script ends with a loud line `READY — call runtime_reload_modules in MCP host`. No auto-fire — auto-reload is a surprise vector and explicit beats implicit, especially for a tool the LLM is supposed to have agency over.

### Tool signature

```
runtime_reload_modules(
  modules: list[string] | nil,            # nil = all pharos@*
  restart_actors: list[string] = [],
  clear_caches: list[string] = [],
  force_purge: bool = false               # soft-purge → hard-purge fallback
) -> {
  reloaded: [(mod, :loaded_changed | :loaded_same | :error reason)],
  restarted: [(actor, :ok | :error reason, mailbox_len_at_restart)],
  cleared: list[string],
  warnings: list[string]                  # callback diff, NIF refusal, soft-purge blockers
}
```

### Shell side (`bin/hot-reload.sh`)

```sh
#!/usr/bin/env bash
set -euo pipefail
mix compile 1>&2
EXTRACT=$(./bin/pharos --print-extract-dir)
[ -d "$EXTRACT" ] || { echo "extract dir gone — run binary once first" >&2; exit 1; }
STAMP="$EXTRACT/.hot-reload-stamp"
PRE=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
rsync -c \
  --include='pharos@*.beam' --include='pharos.app' --exclude='*' \
  _build/prod/lib/pharos/ebin/ "$EXTRACT/"
touch "$STAMP"
# Sanity: every pharos@*.beam dest mtime > PRE
for beam in "$EXTRACT"/pharos@*.beam; do
  [ "$(stat -c %Y "$beam")" -ge "$PRE" ] || { echo "stale beam: $beam" >&2; exit 2; }
done
echo "READY — call runtime_reload_modules in MCP host"
```

The script is bash, not part of the npm wrapper. Lives next to `bin/pharos-dev` and `bin/lsp-smoke`. Zero impact on production releases.

### Gating

The MCP tool and the `--print-extract-dir` flag both ship gated behind `[runtime] reload_enabled = true` in `pharos.toml` (default `false` on production releases) so end users don't accidentally reload pharos out from under themselves on a misclick. Mirrors the existing `trace_calls_enabled` gate from M9.5.

## Consequences

**Wins.**

- Dev iteration drops from a 5-step ~30s loop to a 3-step ~5s loop (`mix compile` + `bin/hot-reload.sh` + `runtime_reload_modules` MCP call). MCP host stays connected throughout.
- The full burrito runtime (`-noshell -mode embedded -noinput`, port-bypassed stdio, real cold-launch beam IDs) stays in scope for every reload — we do not drift away from production semantics the way `pharos-dev` would.
- The "kill the LSP for hover bug" loop becomes the same shape — we already have `runtime_kill_lsp`; adding `runtime_reload_modules` is the matching tool for "kill the pharos code so the next call uses new logic."
- The md5-before/after check + soft-purge default + namespace whitelist mean the tool's failure modes are *visible*, not silent — every footgun above either errors loudly or surfaces a `warnings` entry the LLM can act on.

**Losses / risks.**

- Caller still has to know which actors to restart for protocol-level changes. The reload itself is safe; the reload-without-restart can be silently wrong if a caller forgets. Mitigated by description text + a recommended-restart list per common scenario in the tool docstring + mailbox-length reporting on actual restarts (so the LLM at least sees how many in-flight messages got dropped).
- Hot reload skips the OTP application start callback. Code that runs only at boot won't re-run. The md5 diff on `pharos_app_ffi` and `pharos@root_supervisor` raises a warning when this happens, but adding a new ETS table still requires a full reconnect — the warning makes the partial-staleness loud rather than fixing it.
- Soft-purge can refuse to release a module if a long-running process is still on its old code. Caller has to either restart the blocker actor or pass `force_purge: true`. The blocker list is returned so the caller can choose.
- Production users get an unused tool surface. Gating behind `[runtime] reload_enabled` keeps the surface invisible by default; `tools = [...]` filter still applies.
- The `bin/hot-reload.sh` script depends on `rsync` being installed on the dev machine. Acceptable: every Linux/macOS dev box has it; pharos's existing dev workflow already assumes coreutils + bash.

**Follow-ups.**

- A future ADR can extend this into real upgrade semantics if pharos ever ships hot upgrades to end users (`code_change` callbacks on the actors, version-aware mailbox handling). Out of scope for this ADR — dev-only tool first.
- Add a make target / mix alias so `mix hot-reload` runs `bin/hot-reload.sh` for owners who prefer the Mix surface.
- Once stable, consider auto-firing `runtime_reload_modules` from the shell script via `claude -p` headless mode — but that's the same "spawn new session" trap from the alternatives list and doesn't pilot the live session, so probably not worth it.

## Alternatives considered

- `pharos-dev` as the default dev runtime — rejected: hides distribution-blocking bugs (commit e857dce class).
- Custom Claude Code slash command — rejected: cannot programmatically reconnect MCP server; CLI surface lacks `mcp reconnect` subcommand.
- Tmux/screen `send-keys` automation — viable for users in a multiplexer; not portable. May still be worth a small `bin/reconnect-via-tmux.sh` helper as a separate fallback.
- Full Erlang release upgrade with `relup` files — overkill for dev, and pharos has no upgrade story for end users yet (M13 ships fresh installs only). Revisit if/when pharos publishes a v1 with semver upgrade promises.
