# ADR 025 — Pool off-actor spawn with inflight waitlist + spawner monitoring

* **Status:** Accepted
* **Date:** 2026-05-14
* **Supersedes:** none
* **Related:** ADR-017a (lsp_proc simple_one_for_one), ADR-024 (readiness gate)

## Context

`pharos/lsp/pool` owns the per-`(language, workspace, server_id)`
cache of `Proc` handles. Pre-M14, `handle_get` ran the recover-or-fresh
spawn synchronously inside the pool actor — including the LSP's
`initialize` handshake and (post-ADR-024) the readiness probe loop.
The handshake alone runs 30–90 s on healthy LSPs; with the probe loop
the budget is up to 240–360 s for slow servers (`metals`, `jdtls`).

Pool is a single Gleam actor. While `handle_get` was synchronous, the
actor was unavailable for any other `Msg` — including `Get` requests
for a *different* key, which means concurrent first-touch spawns of N
distinct LSPs serialized end-to-end. M14 Pass 1 (pre-refactor) recorded
the worst case: 23 cold spawns × ~45 s = ~17 min before the last caller
saw a `Proc`. Tools layered on top hit harness wall-clock timeouts long
before pool got around to them.

## Decision

Move the spawn work off the pool actor onto a per-key worker
process. Pool's `handle_get` registers the caller in an inflight
waitlist and returns immediately. The worker performs the slow path
(recover-or-spawn → readiness probe) and posts a `SpawnCompleted`
message back to the pool. Pool then fans the result to every waiter
on that key.

Concretely:

1. `State.inflight: Dict(ProcKey, List(Subject(Result(Proc, GetError))))`
   — one entry per in-flight spawn, list of caller reply subjects
   waiting on the result.
2. `Msg::Get` handler:
   * cache hit → reply immediately;
   * inflight miss → spawn worker, register caller as the first
     waiter, monitor the worker;
   * inflight hit (another `Get` for the same key already in flight)
     → append caller to the existing waitlist.
3. Worker (`process.spawn_unlinked` from `spawn_worker/3`) runs
   `recover_or_spawn` → `run_probe_loop`, then sends
   `SpawnCompleted(key, Result(Proc, GetError))`.
4. Pool's `handle_spawn_completed` fans the result to every waiter,
   updates `cache` on success, and removes the inflight entry.
5. Pool monitors each worker via `process.monitor`. If a worker exits
   abnormally before `SpawnCompleted`, pool's `handle_spawner_down`
   replies `Error(SpawnerCrashed(reason))` to every waiter and
   clears the inflight entry. Without this, a worker crash leaves
   waiters hung forever.

Per-key dedupe falls out of the inflight dict — multiple concurrent
gets for the same key collapse onto a single worker.

## Consequences

* Pool actor returns from `handle_get` in microseconds. Concurrent
  first-touch spawns of N distinct LSPs run in parallel; total wall
  clock for the slowest LSP, not the sum.
* `pool.get` is now a long-blocking `actor.call` from the *caller's*
  perspective (caller waits for `SpawnCompleted`). Caller-side
  `call_timeout` budgets must cover `initialize_timeout_ms +
  ready_timeout_ms + slack`; this is encoded in `pool.get`.
* `GetError` gains two variants: `ProbeFailed(reason)` (ADR-024) and
  `SpawnerCrashed(reason)` (this ADR). Tool layer (`session.gleam`)
  maps both to user-visible `SpawnFailed` strings.
* Pool's state grows two fields: `inflight` and `spawner_monitors`.
  Both bounded by the number of distinct in-flight spawns
  (typically < 30).
* `runtime_lsp_state` reports `inflight_key_count`,
  `inflight_waiter_total`, and `spawner_monitor_count` so an
  operator can see a stuck spawner without attaching a debugger.

### Trap encountered during rollout

Initial M14 Pass 1 (post-refactor, pre-FFI-fix) regressed from
351→141 PASS. Root cause: BEAM occasionally delivered the worker's
DOWN message to pool *before* the worker's `SpawnCompleted` message,
which triggered `handle_spawner_down` → `describe_dynamic` →
`unicode:characters_to_binary` FFI. The FFI signature declared a
`Result(String, _)` return shape, but `unicode:characters_to_binary`
returns a raw binary directly. Pattern match failed → pool actor
crashed mid-handler → cascading havoc.

Fix: replaced direct FFI with `pharos_runtime_ffi:iolist_to_binary_safe/1`,
which absorbs the shape mismatch. Pool stays alive; spawner crashes
surface as typed `SpawnerCrashed` to waiters. Post-fix Pass 1
recorded 370/524 (+19 over baseline).

## Alternatives considered

1. **Trust-the-spawner with 24 h call_timeout** (Option B in the
   M14 plan). Set `pool.get` caller-side timeout to 86 400 000 ms and
   rely entirely on the worker + DOWN handler to bound the wait.
   Rejected: callers (request workers) lose their natural timeout
   signal and Gleam's `actor.call` does not surface a `Result(_,
   Timeout)` — it crashes the caller on timeout, masking the failure.
   Current envelope is `initialize_timeout_ms + ready_timeout_ms +
   30 s` slack which is generous enough to cover even `jdtls` on
   `kafka` without being effectively-forever.

2. **Pre-spawn every LSP at boot.** Rejected as too eager: most
   pharos sessions touch 1–3 languages. Cold start cost should be
   paid lazily. (A bounded warmup hook lands instead — see
   `pharos.warmup_from_env` for the `PHAROS_WARMUP_LANGS` CSV.)

3. **DynamicSupervisor per key.** Adds an extra OTP layer without
   buying us anything beyond what `spawn_unlinked + process.monitor`
   already gives: the workers are one-shot and their failures are
   non-fatal to the pool. supervisor restart semantics would actively
   hurt — we *want* a failed spawn to surface as an error, not be
   retried under the rug.
