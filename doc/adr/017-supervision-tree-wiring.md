# 017. Supervision tree wiring (Phase B of ADR-013)

**Status:** Accepted
**Date:** 2026-05-06

## Context

ADR-013 specified pharos's intended supervision shape and Phase A
landed module-level scaffolding (`pharos/supervisor.gleam`,
`pharos/lsp/supervisor.gleam`) with empty child lists. Phase B —
actually wiring children, having `pharos:main` start the
supervisor instead of inline `pool.start()` — was deferred while
M9.5 (logging + tracing + tier-4 introspection) and M9 polish
items (retry, cancel tracking, language overrides, multi-root)
shipped.

Today's pharos wires major subsystems (`pool`, `sessions`,
`log_writer`, `stdio_loop`) directly from `pharos:main`. None of
them are supervised: a pool actor crash, a log writer crash, or
an HTTP listener bind failure all linked-process-cascade out to
the BEAM root → BEAM exits → pharos dies → MCP host re-spawns
the binary if it knows to. All retry plumbing the M9 commits
added (`with_session_and_retry`, diagnostics retry, drain_loop
cache poll) operates inside an UNsupervised pool, so a single
pool crash voids every guarantee.

This ADR locks the Phase B decisions and ships the wiring.

## Decision

### Tree shape

```
pharos_root (one_for_one, intensity 5/period 60)
  ├─ log_subtree (rest_for_one, permanent)        ◄── new
  │   ├─ ring_keeper        (permanent)
  │   └─ log_writer         (permanent)
  │
  ├─ pool_subtree (rest_for_one, permanent)
  │   ├─ pool_actor         (permanent)
  │   └─ lsp_dyn_sup        (one_for_one, permanent)
  │       └─ lsp_proc[*]    (transient, spawned dynamically by pool)
  │
  ├─ sessions_actor         (permanent)              ◄── HTTP/Both only
  ├─ http_listener_subtree  (permanent)              ◄── HTTP/Both only
  │
  └─ stdio_worker           (transient)              ◄── Stdio/Both only
```

Strategies and rationale:

- **`pharos_root` = one_for_one**: subsystems are independent.
  Pool death does not invalidate sessions; log writer death does
  not invalidate the pool.
- **`log_subtree` = rest_for_one**: ring_keeper FIRST so it
  survives writer restarts. If writer dies, only writer
  restarts. If keeper dies (rare — it's almost no logic), both
  restart (ring data lost; the new keeper starts a fresh table).
- **`pool_subtree` = rest_for_one**: pool actor FIRST. If pool
  dies, lsp_dyn_sup terminates too — every cached lsp_proc dies
  with it, no orphans. If a single lsp_proc dies, dyn_sup's
  `one_for_one` keeps siblings alive; pool's existing
  `process.monitor` evicts the cache entry for the dead one.
- **`lsp_dyn_sup` = one_for_one**: lsp_proc workers are
  independent.
- **lsp_proc workers** are `transient` (ADR-013 unchanged):
  abnormal exit restarts, normal exit (operator-requested via
  `runtime_kill_lsp` or pool-driven via terminate_child) does
  not.
- **`sessions` and `http_listener_subtree`** are `permanent`:
  HTTP transport is unusable without them.
- **`stdio_worker`** is `transient`: stdin EOF returns
  `actor.stop()` cleanly, supervisor does not restart. Crash
  (some bug) returns abnormally and supervisor restarts up to
  the intensity cap.

`intensity 5 / period 60` everywhere: prevents thrash loops; if a
subsystem fails 5 times in 60 seconds the supervisor itself
shuts down, forcing the BEAM to restart fresh under whatever
external supervisor (Burrito wrapper, systemd, MCP host) spawned
us.

### Pool spawn path: workers linked to pool, dyn_sup structural

ADR-013's spec said lsp_proc workers should be children of
`lsp_dyn_sup`. Implementing that cleanly through gleam_otp's
`static_supervisor` (which has no runtime-add API for dynamic
workers) requires either a raw Erlang `simple_one_for_one`
supervisor with a Pid↔Subject bridging layer, OR pre-spawning
fixed children at boot (incompatible with our per-workspace
worker model).

Phase B v1 instead keeps `proc.start` linking workers to the
pool actor (current behavior) and includes `lsp_dyn_sup` in the
tree as a structural — empty — supervisor. The crash-recovery
semantics are equivalent for the failure modes that matter:

- **Pool crashes:** Erlang link cascade kills every worker the
  pool spawned. `rest_for_one` then restarts pool + dyn_sup
  together, both empty. Next tool call repopulates. **No
  orphans.**
- **Individual lsp_proc crashes:** pool's existing
  `process.monitor` fires `ProcDown`, pool evicts the cache
  entry. Next tool call respawns. **Higher latency on the
  first request post-crash, no functional gap.**

What v1 forgoes vs the full ADR-013 model:
- Individual worker crashes do not auto-restart in place. Pool
  evicts and the next request rebuilds. Acceptable for
  pharos's small process count.
- `runtime_kill_lsp` continues to use `proc.close → pool.evict`;
  no `supervisor.terminate_child` round trip.

Follow-up (`017a`): real `simple_one_for_one` integration with
Pid↔Subject bridge. Adds proper individual-restart behavior.
Defer until usage shows the latency hit matters.

Consequence today: pool crash → link cascade kills workers (no
orphans) → rest_for_one restarts pool + dyn_sup → empty fresh.

### Pool global lookup

Tool code today receives `pool: Pool` as a function argument
threaded from `pharos:main` down through `mcp/server.handle_line`
to every tier1/tier2 handler. After supervisor wiring, the pool
actor is started by the supervisor; main no longer holds the
Subject directly.

Add `pool.global() -> Pool` reading from `persistent_term` under
the key `pharos_pool_subject`. `pool.start_supervised`'s init
registers the Subject in persistent_term before returning. Tool
call sites unchanged: `mcp/server.handle_line` reads
`pool.global()` once at the entry point and threads `pool`
downward exactly as today.

Test harnesses that call `pool.start()` directly (bypassing the
supervisor) keep that path. The struct returned is the same; the
global lookup is just an additional access path.

### Log subtree: sidecar ring keeper

Today the writer actor owns the ring buffer ETS table. ETS rule:
table dies with owner. If writer crashes, all ring contents are
gone before any post-mortem can run.

Phase B splits ownership: a new `pharos/log/ring_keeper` actor
starts before the writer, calls `ring.init/0` (which creates the
ETS table owned by the keeper), and otherwise does almost
nothing (just a `Stop` handler for graceful shutdown). The
writer is the producer: it does ETS inserts via `ring.insert/2`
without owning the table. Writer crashes are isolated; ring
data persists.

Keeper is `permanent`; its only state is the ETS table itself,
so crashes are vanishingly rare. Writer is `permanent` too;
crashes there go through supervisor restart while the ring is
already safe.

### Crash dump on writer restart

When the writer restarts (which a healthy run never triggers),
the supervisor invariant tells us the prior incarnation died
abnormally. To preserve forensic context, the new writer's init
does:

1. Tail the last N entries from the ring (ring keeper still
   alive, ring intact).
2. If the count is non-zero AND a prior-incarnation marker was
   left in the ring (sentinel row inserted at `start_supervised`
   time, removed on graceful `Stop`), append the tail to
   `~/.cache/pharos/log/crash-YYYY-MM-DD-hhmmss.log`.
3. Start fresh: insert a new sentinel, register subject,
   resume normal operation.

The dump is best-effort: ENOSPC, permission errors, etc. log via
`direct_stderr` and the new writer continues. This matches what
`logger`'s default file handler does for similar transient
post-mortem snapshots.

### stdio_worker as supervised actor

Today `pharos:main` runs `stdio_loop(pool)` recursively in the
main process. Move that into `pharos/stdio_worker` as a
supervised actor:

- Worker's init reads `pool.global()`.
- Worker's handle_message takes one self-tick `Read`, calls
  `stdio.read_line`, dispatches via `mcp/server.handle_line`,
  writes response via `mcp/stdio.write`, then re-sends `Read` to
  itself.
- EOF / read error returns `actor.stop()`. Restart strategy
  `transient` so this terminates the worker without supervisor
  cascade.
- Crash inside dispatch returns abnormally; supervisor restarts.
  Worker re-reads `pool.global()` (fresh subject if pool also
  restarted) and resumes.

stdout writes are line-atomic at the BEAM level (`io:put_chars`
on a single binary is atomic). No separate writer actor needed
for stdio v1 — stdin worker IS the only writer.

(The async-dispatch refactor noted in ADR-016 — spawning a
worker per `tools/call` — is orthogonal and lands later. For
now stdio_worker is single-line-at-a-time, just supervised.)

### main flow

```
pub fn main() -> Nil {
  // Pre-supervisor init (idempotent ETS tables, registered
  // before the supervisor's children read them).
  diagnostics_cache.init()
  registry.init()
  inflight.init()

  let transport = read_transport()
  case supervisor.start(transport) {
    Error(_) -> Nil  // already logged via direct_stderr
    Ok(_root) -> {
      log.info(
        "pharos starting (transport=" <> transport_label(transport) <> ")",
      )
      // For Stdio / Both, stdio_worker drives termination via
      // stdin EOF returning normal exit; main blocks until the
      // root supervisor itself exits.
      // For Http only, no termination signal — sleep_forever
      // until external SIGTERM.
      process.sleep_forever()
    }
  }
}
```

## Consequences

**Easier:**
- Real fault tolerance: any supervised subsystem crash recovers
  without taking down pharos. The retry plumbing M9 added
  (`with_session_and_retry`, diagnostics retry, etc.) becomes
  meaningful — the underlying actors actually stay alive.
- ETS heir / sidecar-keeper pattern preserves observability data
  (ring, diagnostics cache) across writer restarts. Crash dump
  to `~/.cache/pharos/log/` gives post-mortem fidelity for
  conditions runtime_log_tail cannot reach.
- `pool.global()` makes tool layer transport-agnostic — same
  tool code regardless of whether pool started from supervisor
  or direct test harness.

**Harder:**
- One more module (`pharos/log/ring_keeper`), one more actor in
  the boot sequence. Modest; mirrors `pharos_diagnostics_cache`'s
  init pattern.
- Existing tests that call `pool.start()` directly keep that
  path but new tests targeting supervision behavior need to
  spin up the full root supervisor in isolation. Test harness
  helpers land alongside the wiring.
- Restart cascades have surprise factors: pool restart kills
  every cached lsp_proc (good — no orphans), but means a
  pool-actor bug forces every workspace to re-handshake. Cost
  is amortized (one bug → all LSPs re-spawn), so the test
  matrix needs to include "pool crash; tools/call recovers".

**Constraints on future work:**
- Async tools/call dispatch (ADR-016 follow-up) plugs into the
  stdio_worker module; the dispatch path will spawn workers
  under a new `tools_call_dyn_sup` rather than running
  synchronously inside stdio_worker.
- Adding new long-lived subsystems (telemetry, metrics
  collector) must register under `pharos_root` with appropriate
  restart strategy, not as standalone processes.

## Alternatives considered

- **Skip wiring; rely on external supervisor (systemd, Burrito,
  MCP host).** Rejected: each external supervisor has different
  semantics; hardcoding our own makes behavior identical across
  deploy environments.
- **`one_for_all` root strategy** instead of `one_for_one`.
  Rejected: pool crash should not kill log writer; sessions
  death should not invalidate pool. Subsystems are
  independent.
- **Snapshot-based ring crash dump** (writer dumps ring to disk
  every N seconds). Rejected: lossy + IO load; the sidecar
  keeper preserves entire ring with zero ongoing cost.
- **Skip the ring keeper sidecar; use ETS heir pointing at
  supervisor.** Considered. ETS heir works but requires the
  supervisor to handle `{ETS-TRANSFER, ...}` messages and dump
  contents inside its `terminate_child` callback — adds custom
  logic to gleam_otp's static_supervisor, fighting the
  abstraction. Sidecar is the OTP-idiomatic factoring.
- **Spawn lsp_proc workers via direct `proc.start` and skip
  lsp_dyn_sup entirely.** Rejected: leaves orphan procs on
  pool crash, undermines ADR-013's whole point.
