# 014. Runtime introspection tools — scope and safety

**Status:** Accepted
**Date:** 2026-05-05

## Context

M9.5 Part C exposes BEAM runtime state to the LLM via MCP tools so a
chat-driven debugging session can read process state, the supervision
tree, ETS tables, the structured-log ring buffer, and the LSP traffic
tracer without leaving the conversation surface. The init doc's first
sketch listed every BIF a developer might reach for, including
`runtime_kill_pid` (raw `erlang:exit/2`) and `runtime_trace_module`
(raw `:dbg.tracer`).

Two issues surfaced when laying these against the existing supervision
tree (ADR-013):

- **Raw `kill_pid` races the supervisor.** ADR-013 sets `lsp_proc` to
  `transient`, so an abnormal exit triggers automatic restart under
  `lsp_dyn_sup`. The pool's monitor also fires `ProcDown` and evicts
  the cache entry. Result: supervisor spawns a replacement that the
  pool no longer references, and the next tool call spawns a third
  process via the cache-miss path. Two zombies per kill.

- **Raw `:dbg.tracer` mutates global VM state.** Trace flags live on
  every process's PCB; the pattern table lives at the BEAM level.
  Forgetting to clean up — or letting an unbounded mailbox grow on the
  collector process — degrades the whole node. The Erlang docs
  explicitly warn against `:dbg` in production. `recon_trace` (Fred
  Hebert) wraps it with built-in caps (max events, max rate, max time,
  auto-stop) and is the de facto production-safe API.

The "give the LLM full debugging power" requirement is real: a stuck
LSP must be killable and self-healing, function-call tracing must be
available when other observability is exhausted. The shape of *how* to
expose those capabilities is the question.

## Decision

Three classes of Part C tools, each with explicit safety guarantees:

**1. Read-only observation tools.** No state changes, no caps needed
beyond output clipping. Always available regardless of env config.

```
runtime_processes        runtime_supervision_tree
runtime_ets_tables       runtime_memory
runtime_applications     runtime_scheduler_util
runtime_pid_info         runtime_log_tail
runtime_log_clear        runtime_log_level
runtime_trace_lsp        (toggles filter, reads ring; no global state mutation)
```

`runtime_log_clear` is technically a write but bounded to the ring
buffer table; recovery is "wait for the next log line to land."

**2. Scoped destructive tools.** Always available. Always routed
through their owning subsystem, never through raw BIFs that bypass
supervision invariants.

```
runtime_kill_lsp(language, workspace)
```

Implementation: tool handler calls `pool.kill_lsp(language, workspace)`
which (a) looks up the lsp_proc pid for the key, (b) calls
`supervisor.terminate_child(lsp_dyn_sup, pid)` — supervisor distinguishes
operator-requested termination from crashes and does not restart, (c)
evicts the pool cache entry. Next tool call for the same key spawns a
fresh worker via the normal pool-miss path. Exactly one new LSP, no
race with the supervisor.

The LLM can kill any LSP without being able to kill the log writer,
the pool actor, the sessions table, the supervisors themselves, or
core BEAM processes — none of which it has any reason to terminate.

**3. Powerful tracing, gated.** Behind `PHAROS_RUNTIME_TRACE_ENABLED=1`
env var. Refuses to run otherwise.

```
runtime_trace_calls(module, function?, duration_ms, max_events)
```

Implementation: thin Gleam wrapper over `:recon_trace.calls/2`. recon
enforces:
- `max_events` trip — stops tracing when N events are collected
- `time_limit` trip — stops after `duration_ms`
- formatting + clipping per event
- automatic clean-up regardless of which trip fires first

The handler additionally hard-caps `duration_ms` at 30000 and
`max_events` at 5000, refuses to trace specific hot modules
(`erlang`, `ets`, `gleam@otp@actor`, `gleam@erlang@process`), and
wraps the body in `try ... after :recon_trace.clear() end` so any
crash path still removes trace flags from the BEAM.

**Cut from scope:**
- `runtime_kill_pid` — no use case `runtime_kill_lsp` does not cover;
  raw kill of arbitrary BEAM pids has too many ways to break the
  system in ways the LLM cannot recover from.
- Raw `:dbg`-based `runtime_trace_module` — superseded by
  `runtime_trace_calls` via recon.

## Consequences

**Easier:**
- LLM can fully debug LSP issues end-to-end: see the wire trace, read
  the log ring, list supervised children, kill a stuck worker, watch
  it self-heal.
- Pool stays the sole owner of `lsp_proc` lifecycle. Supervisor only
  intervenes on actual crashes (segfaults, untrapped exits inside
  `lsp_proc`), preserving the invariant that there is exactly one
  worker per `(language, workspace)` key in the cache at any moment.
- recon's safety story carries over for free. We are not the first
  team to wrap `:dbg` for production use.
- The full-power-without-footguns principle generalizes: future
  destructive tools route through their subsystem, never through raw
  BIFs.

**Harder:**
- One additional dependency (`recon`). Small, no transitive deps,
  available on Hex. Pinned at compatibility floor.
- `runtime_trace_calls` requires explicit env-var enablement to run.
  This is friction during interactive debugging but inverts the
  default-off footgun where a bad arg pattern silently degrades the
  node. Documented in the tool's description so the LLM surfaces the
  setup step to the user.
- Two flavors of "list all things" tools — the read-only ones list
  state; `runtime_kill_lsp` does not let the LLM kill anything other
  than what `runtime_supervision_tree` lists under `lsp_dyn_sup`.
  This is a feature; if the LLM asks the user to kill a non-LSP
  process, the answer is to fix the supervisor strategy or restart
  the BEAM, not to expose another sharp tool.

**Constraints on future work:**
- Any new destructive tool must follow the same pattern: route
  through the owning subsystem; refuse to take a raw pid as a target.
- Adding tracing for non-call events (gc, send, receive) means
  another `runtime_trace_*` tool, each with its own caps. recon
  exposes those primitives but they are not wired by default.
- Exposing distributed-Erlang multi-node introspection is explicitly
  out of scope (pharos is single-node).

## Alternatives considered

- **Ship `runtime_kill_pid` with an allowlist of safe pids.** Too
  brittle — every new actor type would require allowlist updates,
  and the failure mode of a forgotten entry is "LLM cannot kill the
  thing the user wants killed." `runtime_kill_lsp` covers the
  realistic use case directly.
- **Ship `runtime_kill_pid` with a denylist of unsafe pids.** Same
  shape, mirror failure mode (LLM kills something we forgot to
  deny). Worse default.
- **Skip destructive tools entirely.** Read-only would cover
  observability, but the "stuck LSP, please reset" case is exactly
  what the tools should solve. Forcing the user to manually restart
  pharos undermines the chat-driven-debugging premise.
- **Roll our own `:dbg` wrapper instead of taking the recon dep.**
  The first 80% is a screen of code; the remaining 20% (rate caps,
  hot-module guards, format buffer bounds, race-free cleanup) is
  exactly what production-tracing libraries spend years getting
  right. Not worth re-deriving.
