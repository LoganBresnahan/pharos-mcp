# 017a. lsp_proc workers under a `simple_one_for_one` supervisor with an ETS Pid↔Subject bridge

**Status:** Accepted
**Date:** 2026-05-06

## Context

ADR-017 wired the supervision tree but kept lsp_proc workers
linked to the pool actor instead of being real children of
`lsp_dyn_sup`. Crash recovery still worked (link cascade kills
workers when pool dies; pool's `process.monitor` evicts cache on
individual worker death), but individual worker crashes did NOT
auto-restart in place — the next tool call paid the cold-start
cost (5–15s for rust-analyzer indexing, ~200ms for gopls).

ADR-017 marked this a follow-up because the implementation
required solving a Pid↔Subject bridging problem that gleam_otp
does not address.

The three blockers documented in ADR-017's "Follow-up" section:

1. Erlang's `:supervisor` protocol expects `{ok, Pid}` from a
   child's start function. gleam_otp's `actor.start` returns
   `actor.Started{Pid, Subject}`. Wrapping to satisfy supervisor
   loses the Subject, but pool needs the Subject to send actor
   messages.
2. A Subject is `{Subject, Pid, Ref}` where `Ref` is a fresh
   make_ref made at actor spawn. Caller cannot reconstruct a
   Subject from a Pid alone; the Ref must be communicated.
3. `simple_one_for_one` needs an Erlang callback module exposing
   `init/1`. gleam_otp's `static_supervisor` does not expose
   this strategy.

## Decision

Solve all three with one mechanism: an ETS bridge table
`pharos_lsp_proc_subjects` mapping spawned worker Pid to its
Subject, populated by the worker's wrapper start function before
it returns to the supervisor.

### Erlang module: `pharos_lsp_dyn_sup`

```erlang
-module(pharos_lsp_dyn_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/5, terminate_child/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Cmd, Args, Workspace, InitParams, TimeoutMs) ->
    supervisor:start_child(?MODULE,
        [Cmd, Args, Workspace, InitParams, TimeoutMs]).

terminate_child(ChildPid) ->
    supervisor:terminate_child(?MODULE, ChildPid).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 5, period => 60},
    ChildSpec = #{
        id => lsp_proc,
        start => {pharos@lsp@proc, start_link_supervised, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [pharos@lsp@proc]
    },
    {ok, {Flags, [ChildSpec]}}.
```

`simple_one_for_one` strategy: every child uses the same spec;
`start_child` appends its arg list to the spec's empty default,
so `supervisor:start_child(?MODULE, [Cmd, Args, Ws, IP, T])`
calls `pharos@lsp@proc:start_link_supervised(Cmd, Args, Ws, IP, T)`.

### Gleam wrapper: `proc.start_link_supervised/5`

```gleam
pub fn start_link_supervised(
  command: String,
  args: List(String),
  workspace: String,
  init_params: Json,
  initialize_timeout_ms: Int,
) -> Result(Pid, String) {
  case start(command, args, workspace, init_params, initialize_timeout_ms) {
    Error(err) -> Error(describe_start_error(err))
    Ok(proc_handle) -> {
      let Proc(subject) = proc_handle
      let pid = pid(proc_handle)
      lsp_proc_subjects_insert(pid, subject)
      Ok(pid)
    }
  }
}
```

`actor.start` is synchronous wrt the actor's initialiser (it
waits for an `Ack` before returning), so by the time
`start_link_supervised` runs the ETS insert, the actor process
is alive and its initialiser has completed. The insert
therefore lands BEFORE the wrapper returns `{ok, Pid}` to the
supervisor, which means by the time
`supervisor:start_child(...)` returns to pool, the ETS row is
guaranteed present. **No race.**

### Bridge table: `pharos_lsp_proc_subjects`

```erlang
%% public, named_table, set, read_concurrency
%%
%% Key:   Pid (lsp_proc actor's process pid)
%% Value: Subject(pharos@lsp@proc:Msg) — opaque tuple from
%%        Gleam's perspective; a tagged tuple at the BEAM
%%        level. Stored verbatim so reads return the same
%%        Subject the wrapper inserted.
```

Pool reads with `lsp_proc_subjects_lookup(Pid)` after
`supervisor:start_child` returns. Cleans the row on cache
eviction and on graceful `proc.close`.

### Pool spawn path

`pool.handle_get`'s cache-miss branch changes:

```gleam
// Before
case spawn_proc(spec, workspace) {
  Ok(spawned) -> {
    let monitor_ref = process.monitor(proc.pid(spawned))
    ...
  }
}

// After
case lsp_dyn_sup_start_child(
  spec.command, spec.args, workspace,
  spec.init_params, initialize_timeout_ms,
) {
  Error(reason) -> ...
  Ok(pid) ->
    case lsp_proc_subjects_lookup(pid) {
      Error(_) -> Error(ProcStartFailed("ETS bridge missing entry"))
      Ok(subject) -> {
        let spawned = proc.from_subject(subject)
        // workspace_configuration handler attach + push
        // happen after subject recovered, same as before.
        let monitor_ref = process.monitor(pid)
        ...
      }
    }
}
```

Pool's `process.monitor` stays — belt-and-suspenders. If
supervisor's restart-intensity trips and `lsp_dyn_sup` itself
shuts down, monitor catches the resulting DOWN and pool evicts
cache.

### Restart races

Two races to handle:

**Race 1**: pool's monitor fires DOWN before supervisor's
restart finishes. Pool tries to start_child while old worker is
still being torn down. Supervisor returns
`{error, {already_started, NewPid}}`. Pool retries the lookup
under the new pid.

**Race 2**: supervisor's restart finishes before pool's monitor
DOWN message is processed. ETS row points at NEW pid; pool's
cache still says OLD pid. First tool call after that hits the
dead Subject. The existing
`session.with_session_and_retry` plumbing catches the
ClientFailure and respawns transparently — same path used for
any LSP transport error today.

Both races are handled. The second is masked by retry; the
first surfaces as a brief "already_started" log line in the
worst case.

### Cleanup on graceful close

`pool.handle_evict` and `pool.handle_kill_lsp` both call
`proc.close`. `proc.close` now also calls
`lsp_dyn_sup_terminate_child(pid)` so the supervisor stops
auto-restarting the (intentionally-killed) worker. ETS row is
deleted via the actor's `terminate` callback OR by the pool
explicitly after `terminate_child` returns.

## Consequences

**Easier:**
- Individual lsp_proc crashes auto-restart in place. The next
  tool call after a crash sees a warm worker (no cold-start
  re-indexing) — empirically <1s vs 5–15s today.
- `runtime_supervision_tree` MCP tool now lists real children
  under `pharos_lsp_dyn_sup`. The "why is that supervisor
  empty" question goes away.
- The bridge pattern is reusable: when sessions or other
  subsystems need typed dynamic children, the same
  `<subsystem>_subjects` ETS pattern applies.

**Harder:**
- One more Erlang module + one more ETS table to keep in sync.
- ETS row leak risk: if a worker exits without going through
  `proc.close` (supervisor-driven crash restart), the OLD pid
  row stays in the table while a NEW pid row is added on
  restart. Pool only ever reads by current pid, so the orphan
  row is harmless but unbounded over time. Mitigation: the
  worker actor's terminate callback (or trap_exit + cleanup)
  deletes its row before exiting; documented as a follow-up
  if leaks measure non-trivial.
- Workers now restart on abnormal exit. That means a buggy LSP
  server that segfaults repeatedly thrashes through the
  supervisor's intensity cap (5 restarts/60s) and then the
  whole `pool_subtree` shuts down. Acceptable: a server that
  consistently crashes is unusable, and the `rest_for_one`
  cascade lets pharos surface the failure to the LLM rather
  than masking it.

**Constraints on future work:**
- Async tools/call dispatch (ADR-016 follow-up) does not need
  changes here — the bridge is per-LSP-process, dispatch
  workers live independently.
- Multi-root rust-analyzer (ADR-015) is unaffected — promotion
  still resolves a (language, workspace) key to one cached
  proc.

## Alternatives considered

- **Named subject (atom registry) for each spawned actor.**
  Atom table grows unbounded with per-spawn unique names;
  unsafe for long-running pharos. Rejected.
- **Inline custom Gleam dynamic supervisor** that
  reimplements OTP's restart logic. ~120 LOC of risk +
  non-standard. Rejected.
- **Static sub-supervisor per worker.** Heavyweight; still
  needs dyn-add somewhere upstream. Rejected.
- **Defer ADR-017a indefinitely.** The cold-start latency on
  worker crash measurably hurts the iteration loop when
  rust-analyzer crashes (rare but non-zero — the M9 dogfood
  saw two over the course of the supervision-wiring work).
  Half-day to ship; worth shipping now.
