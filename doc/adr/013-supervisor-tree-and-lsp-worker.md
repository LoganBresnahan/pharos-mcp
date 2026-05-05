# 013. Supervisor tree and per-LSP worker process

**Status:** Accepted
**Date:** 2026-05-04

## Context

Through Milestone 8 pharos used the BEAM VM but barely any of OTP. The application had:

- **No real supervisor tree.** `pharos@supervisor` and `pharos/lsp/supervisor` exist as stub modules with placeholder constants. The actual application start callback (`pharos_app_ffi:start/2`) `spawn_link`s `pharos:main/0` directly. If `pharos:main` exits abnormally, the linked process dies and (in `:prod` with `start_permanent: true`) the BEAM crashes with "Kernel pid terminated."
- **Pool actor unsupervised.** `pool.start/0` is called inline from `pharos:main` via `actor.start`. If the pool actor crashes, it takes the linked main process down with it; whole BEAM dies.
- **LSP child processes unmonitored.** Each LSP is wrapped in a Client struct holding an Erlang `Port`. The Port's owner is initially the pool, transferred to the calling tool process via `client.connect` so the tool's mailbox receives port data. When an LSP child crashes, the Port dies, the tool's next call surfaces a transport error to the LLM, but **the pool still holds a stale Client in its cache pointing at the dead Port**. Subsequent calls from any tool fail until manually restarted.
- **Sessions actor unsupervised.** Same shape as the pool — started inline from `start_http`.
- **No concurrency model per LSP.** Port ownership is exclusive to one process at a time. `client.connect` transfers ownership per-call. Two tools wanting the same LSP simultaneously is racy at best.

This was acceptable for M1 through M8 because dogfood was single-tool-at-a-time and crash recovery wasn't a goal. Stage 0F dogfood started showing the gaps: rust-analyzer transient errors leave stale clients in cache; SSE long-poll connections need supervised lifecycle; Tier 2's `rename_preview` capture flow needs concurrent server-request dispatch alongside the in-flight LSP request.

M8 Stage 2 documents seven reliability issues. Three (auto-evict on crash, transparent retry-on-transport-error, $/cancelRequest propagation) are structural — they cannot be cleanly added without a supervisor tree and a per-LSP worker. The other four can land independently.

This ADR pins the supervision and worker design before M9 implementation begins, so the tree shape, restart strategies, and Port-ownership model are not litigated mid-refactor.

The forces:

- **OTP idioms exist for exactly this problem.** Supervisors are restart machines parameterized by strategy; monitors are point-to-point liveness signals. Using them buys crash recovery, isolation, and graceful shutdown semantics for free.
- **Per-LSP workers add a hop per tool call** but unify what is currently scattered across `lifecycle.gleam`, `client.gleam`, and the pool: id correlation, server-request handler dispatch, `$/progress` tracking, Port ownership. Centralizing this state inside one supervisable actor matches OTP's design grain.
- **Pool's cache is a coherence concern, not a supervision concern.** Supervisors don't notify peers when a child dies. Pool needs its own monitor on each LSP worker to keep the cache from going stale. This is the standard OTP pattern: structure-by-supervision, communication-by-monitoring.
- **The application's primary lifecycle is "stdin EOF or external SIGTERM."** Stdin reader exiting normally should bring the whole application down cleanly; abnormal exit should restart it and keep the rest of the system alive. That asymmetry maps cleanly to OTP's `transient` restart type.

Six decisions were aligned in the design pass; this section records the forces, the next section records the picks.

### 1. Root supervisor strategy

`one_for_one`, `rest_for_one`, or `one_for_all` at the root. Pool, sessions actor, and transport listener (HTTP + stdin reader) are independent failure domains: a pool crash should not bring down the HTTP listener that has live SSE streams. `one_for_one` matches.

### 2. Per-LSP worker existence

Today the Port is owned by tool processes after `client.connect` transfers ownership. The alternative — a dedicated `lsp_proc` actor per LSP that owns the Port for its lifetime — adds one mailbox hop per request but enables real supervision, real concurrency between tools, and a single home for per-LSP state.

The hop cost is microseconds against LSP server response times of hundreds of milliseconds. Negligible.

### 3. Tool → lsp_proc API shape

Synchronous `actor.call(proc, ...)` blocks the tool process until the LSP replies (with timeout). Async would require threading reply Subjects through every tool callsite — significant churn for a feature current Tier 1 / Tier 2 do not need (no tool currently issues parallel requests inside a single tool call).

### 4. Restart strategies per child

- **pool actor:** `permanent`. Pool crashing without restart leaves the application unable to spawn LSPs.
- **sessions actor:** `permanent`. Session loss terminates active HTTP clients but a fresh table allows new connections.
- **lsp_dyn_sup:** `permanent`. The dynamic supervisor for LSP workers must always be available.
- **individual `lsp_proc` under lsp_dyn_sup:** `transient`. Abnormal exit restarts; clean exit (e.g., pool intentionally evicted the worker) does not bring it back.
- **stdin reader:** `transient`. EOF on stdin is the application's normal end; abnormal exit (e.g., framing failure) restarts.
- **http_listener:** `permanent` when `transport=http|both`.

### 5. Max restart frequency at root

`5 / 60` (OTP common default): if the root sees 5 child restarts within 60 seconds, the BEAM exits. Burrito returns nonzero; the MCP host re-spawns from scratch.

### 6. Pool ↔ lsp_proc coupling

Pool monitors each `lsp_proc` via `process.monitor` — distinct from supervision. When a worker dies, pool receives `{'DOWN', ref, process, pid, reason}` and evicts the cache entry. Belt-and-suspenders with `lsp_dyn_sup`'s own restart policy: the supervisor decides whether to bring back the worker; the pool's monitor ensures the cache stays coherent regardless.

### 7. Graceful shutdown order

Reverse of startup: stdin EOF → root supervisor receives shutdown → children stop in declaration order's reverse → each `lsp_proc`'s `terminate/2` sends LSP `shutdown` request + `exit` notification, then closes the Port → BEAM exits 0 cleanly via `init:stop`.

### 8. Module placement

- `pharos/lsp/supervisor.gleam` — currently a stub — becomes the root supervisor.
- New `pharos/lsp/proc.gleam` — the per-LSP worker.
- `pharos/lsp/client.gleam` — kept as the low-level Port wrapper, now used internally by `lsp_proc`. Its public API shrinks accordingly.
- `pharos/lsp/pool.gleam` — interface unchanged from outside; internally returns `Proc` handles instead of `Client`. Tools migrate to call `proc.request/4` instead of `lifecycle.request/5`.

## Decision

Adopt the following supervisor topology for M9:

```
:pharos OTP application
└─ pharos_root_supervisor (one_for_one, max=5/60s)
   ├─ pool_subtree_sup (rest_for_one, permanent)
   │  ├─ pool actor (permanent)
   │  └─ lsp_dyn_sup (one_for_one, permanent)
   │     ├─ lsp_proc (rust)            (transient)
   │     ├─ lsp_proc (go)              (transient)
   │     ├─ lsp_proc (typescript)      (transient)
   │     └─ lsp_proc (python)          (transient)
   ├─ sessions actor (permanent)
   └─ transport_subtree_sup (rest_for_one, permanent if transport=http|both, transient if stdio-only)
      ├─ stdin reader (worker, transient)
      └─ http_listener (mist's own supervisor, permanent when applicable)
```

Specifics per decision:

1. **Root strategy:** `one_for_one`, `max_restart 5 / 60s`.
2. **`lsp_proc` worker exists.** Owns one LSP's Port for its lifetime. Hosts request id correlation, server-request handler dispatch (per ADR-012), `$/progress` tracking, and pending-reply Subjects.
3. **Synchronous tool API:** `actor.call(proc, fn(reply) { Request(method, params, reply) }, timeout_ms)`. The tool's process blocks on the reply Subject; the worker's mailbox handles N concurrent requests internally and demuxes responses by id.
4. **Restart strategies as described above.**
5. **5 restarts / 60s** at root.
6. **Pool monitors lsp_proc** via `process.monitor`, evicts cache on DOWN. lsp_dyn_sup independently restarts the worker per its own restart strategy. Both layers fire on the same crash event; pool's eviction is idempotent.
7. **Shutdown order:** stdin reader → http_listener → sessions → pool subtree (which cascades to lsp_dyn_sup → individual lsp_procs that send LSP shutdown handshake before closing Ports).
8. **Module placement** as described above.

### Implementation phases

Phase A — supervision skeleton, no behavioral change:
- Implement `pharos_root_supervisor` and the two sub-trees as `gleam_otp/static_supervisor` definitions.
- Wire `pharos_app_ffi:start/2` to return the root supervisor pid.
- Existing pool actor moves under `pool_subtree_sup` unchanged. Existing sessions actor moves under root unchanged. Existing http_listener moves under transport_subtree_sup unchanged. stdin reader becomes a child instead of an inline call.
- Net effect: supervision wired but no new restart-on-crash behavior beyond what `start_permanent: true` already gave us. The point of Phase A is to land the tree shape with zero functional regression risk.

Phase B — `lsp_proc` worker:
- New module `pharos/lsp/proc.gleam`. Spawn-and-initialize moves from pool into proc's `start/2` callback.
- Pool's `Get` message returns a `Proc` handle instead of a `Client`. Pool internally calls `lsp_dyn_sup.start_child(spec)` on cache miss.
- Pool monitors each Proc via `process.monitor`. On DOWN, evict cache entry.
- Tool callsites: `lifecycle.request(client, ...)` → `proc.request(proc, ...)`. The lifecycle module's classifier and handler-dispatch logic moves into proc; lifecycle becomes a thinner wrapper over proc for tools that still need direct access (mostly internal).

Phase C — retry + cancellation:
- Tool helper `with_retry/2` wraps any LSP call; on `ClientFailure` (transport error), pool evicts + respawns + retries once.
- `notifications/cancelled` from the MCP client routes to the corresponding `proc`, which sends `$/cancelRequest` to the LSP.

Phase D — Stage 2 reliability fixes that depend on the new tree:
- Pool auto-evict crash item from M8 Stage 2 closes naturally — Phase B implements it.
- `$/progress` tracking lives in `proc.State` instead of the Client struct. wait_for_ready can be reimplemented as a proc-side gate ("wait for token's begin then end") rather than the dogfood-broken idle-bail variant.

The four phases land as separate commits. Tests (unit + integration) accompany each.

## Consequences

**Easier:**

- A crashed LSP child is invisible to the LLM after one retry. Today every LSP crash surfaces as a tool error; tomorrow most are transparent.
- Pool's cache stays coherent with reality automatically. The `evict/3` public API stays for tools that have other reasons to evict (e.g. capability change), but the implicit auto-evict on crash means manual eviction is no longer how pharos recovers from LSP failures.
- Concurrency story is real. Two tools calling rust-analyzer simultaneously each get their own pending-reply Subject; the proc serializes the writes but routes responses by id. No Port-ownership transfer dance.
- $/cancelRequest becomes possible because there is now one process per LSP that knows about every in-flight request id and can match cancellation to it.
- Graceful shutdown actually works. Today stdin EOF triggers `init:stop(0)` from inside the spawn_link'd process; LSPs sometimes do not see a clean shutdown handshake before their Ports close. Tomorrow the supervisor cascade gives each `lsp_proc` a `terminate/2` window to send `shutdown` + `exit` to its LSP.
- ADR-012's Stage 0E `with_handler` API moves cleanly into proc state — overrides install on the proc, not on a Client struct that gets passed around.

**Harder:**

- Per-request hop through the proc's mailbox adds microseconds. Negligible vs LSP latency, real for benchmarks.
- One more layer of indirection in the codebase. New contributors must learn the proc abstraction before tracing a tool call. Mitigated by keeping the proc API small (`request`, `notify`, `with_handler`) and modeled after lifecycle's existing surface.
- Tool tests that previously stubbed `Client` and called `lifecycle.request` directly need to stub `Proc` instead. Test infrastructure churn during the migration. Stage 2 lands first in part to nail the test patterns.
- Phase B is the riskiest commit in the whole project: it touches every Tier 1 / Tier 2 tool's dispatch path. Mitigation: Phase A lands first (no behavior change), Phase B follows with a feature flag that can switch between Client-direct and Proc-mediated paths during the transition.

**Living with:**

- The supervisor tree shape is conservative. We could consolidate `pool_subtree_sup` and the root if simplicity matters more than restart isolation. Easy to flatten later if the layered shape proves unnecessary.
- `rest_for_one` inside `pool_subtree_sup` couples pool restarts with `lsp_dyn_sup` restarts — if pool dies, all LSP workers die too. Justified because the workers are addressed via pool's cache; a pool restart with stale workers would leak processes.
- `transient` for `lsp_proc` means a clean LSP shutdown does not auto-restart. If the LSP gets its `shutdown` handshake from us and exits 0, lsp_dyn_sup leaves it dead. The next tool call repeats `pool.get_or_spawn`. Correct behavior.
- The proc actor's mailbox is a serialization point. If one tool sends a 30-second `find_references` request, other tool requests to the same LSP queue behind it. Real LSPs do not parallelize all methods anyway (rust-analyzer holds an analysis lock during writes), but we should be aware that pharos cannot work around an LSP's serialization with more concurrency. Future M-tier optimization: per-method routing tables that bypass the actor for known-parallel-safe reads.
- Phase B's "feature flag for transition" implies dead code for one milestone. ADR-014 (when written) should authorize its removal.

## Alternatives considered

- **`rest_for_one` at root** — couples sessions to pool, which is wrong: a pool crash should not invalidate active HTTP sessions.
- **`one_for_all` at root** — overly aggressive: any single subsystem failure restarts everything. Unjustified.
- **No worker per LSP; pool owns all Ports** — possible, but pool becomes a god-object: handles cache, monitoring, AND request multiplexing. The proc abstraction separates concerns at zero net cost.
- **Worker per (LSP, language) but shared workspaces** — rust-analyzer specifically does not handle this well; one server per workspace is the safer default, matching today's `(language, workspace)` cache key.
- **Async tool API (Subjects everywhere)** — flexibility we do not need today, complexity we do not want today. Add later if Tier 3 streaming completions require it.
- **Skip Phase A and go directly to Phase B** — high regression risk; a behavior-preserving supervisor wrap landing first is cheap insurance.
