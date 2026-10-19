# Pharos architecture

End-to-end map of every long-lived process pharos spawns, the
supervision relationships between them, every place a synchronous
boundary is crossed, and every timeout that gates wall-clock
behaviour. The intent is operational: when something hangs, this
doc tells you which process to look at, which actor.call is
likely blocking, and which timeout is supposed to bound it.

Source-of-truth file references appear inline; if this doc
drifts, the linked code is canonical.

## Process tree at runtime

```
┌─────────────────────────────────── BEAM node ────────────────────────────────────┐
│                                                                                  │
│  ┌────────────────── pharos_root ───────────────────┐  (one_for_one, 5/60)       │
│  │                                                  │  doc/adr/013, 017          │
│  │  ┌─ log_subtree ──────┐  (rest_for_one, 5/60)    │                            │
│  │  │  ring_keeper       │ permanent  GenServer     │  in-memory log ring        │
│  │  │  log_writer        │ permanent  GenServer     │  fan-out to filter, file,  │
│  │  │                    │                          │  stderr; persistent_term   │
│  │  └────────────────────┘                          │  global = pharos_log_writer│
│  │                                                  │                            │
│  │  ┌─ pool_subtree ─────┐  (rest_for_one, 5/60)    │                            │
│  │  │  pool_actor        │ permanent  GenServer     │  pharos/lsp/pool.gleam     │
│  │  │  lsp_dyn_sup       │ permanent  supervisor    │  pharos_lsp_dyn_sup.erl    │
│  │  │   └── simple_one_for_one, children spawned    │  (transient restart)       │
│  │  │       on demand via pool's spawn worker:      │                            │
│  │  │                                               │                            │
│  │  │       lsp_proc(rust, /cargo,    rust-analyzer)│  one per (lang, ws, srv)   │
│  │  │       lsp_proc(go,   /prom,     gopls)        │  GenServer wrapping        │
│  │  │       lsp_proc(java, /kafka,    jdtls)        │  one OS Port to the LSP    │
│  │  │       lsp_proc(...)                           │                            │
│  │  └────────────────────┘                          │                            │
│  │                                                  │                            │
│  │  ┌─ HTTP subtree (only if transport ∈ {Http,     │                            │
│  │  │   Both})                                      │                            │
│  │  │  sessions_actor    │ permanent  GenServer     │  pharos/mcp/sessions.gleam │
│  │  │  http_listener     │ permanent  mist acceptor │  per-conn process spawned  │
│  │  │   └── mist conn-N  │ ephemeral  per request   │  by mist; lives one HTTP   │
│  │  │                    │                          │  request (or SSE stream)   │
│  │  └────────────────────┘                          │                            │
│  │                                                  │                            │
│  │  ┌─ Stdio subtree (only if transport ∈ {Stdio,   │                            │
│  │  │   Both})                                      │                            │
│  │  │  stdio_worker      │ transient  GenServer     │  pharos/stdio_worker.gleam │
│  │  │   └── dispatch_N   │ ephemeral  per JSON-RPC  │  process.spawn_unlinked    │
│  │  │                    │            line          │  per request_workers       │
│  │  └────────────────────┘                          │                            │
│  └──────────────────────────────────────────────────┘                            │
│                                                                                  │
│  ETS registries (out-of-tree, persistent_term globals):                          │
│    pharos_lsp_proc_subjects        (lang, ws, srv) → lsp_proc Subject            │
│    pharos_request_workers          session|mcp_id  → dispatcher pid              │
│    pharos_inflight                 session|mcp_id  → (lsp_proc_subj, lsp_id)     │
│    pharos_diagnostics_cache        uri             → latest Diagnostic[]         │
│    pharos_log_writer_subject       global          → log writer Subject          │
│    pharos_session_overrides        session→(tool,lang) → bumped timeout_ms       │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Session context (ADR-034): every dispatcher process binds its
session's id, cwd, env, Config and language registry in its process
dictionary ([src/pharos/session_ctx.gleam](../src/pharos/session_ctx.gleam)).
`config.cached/0` and `registry.cached/0` resolve through it, and the
two request-keyed tables above qualify the MCP id with the session id,
because two clients both send id `2`. Direct mode is a single session
built from the process cwd and env. Processes with no session bound
(the HTTP transport, boot) see the process-wide Config.

Supervision wiring: [src/pharos/supervisor.gleam](../src/pharos/supervisor.gleam)
(supervision tree definition), [src/pharos_lsp_dyn_sup.erl](../src/pharos_lsp_dyn_sup.erl)
(LSP child supervisor — `simple_one_for_one`, gleam_otp doesn't expose
that strategy hence the Erlang shim).

Restart strategy summary:

- `pharos_root` — **one_for_one**. One child failing doesn't cascade.
  `intensity 5 / period 60` shuts the whole tree if more than 5
  children die in a minute (the shim, systemd or the MCP host then restarts
  pharos cleanly).
- `log_subtree`, `pool_subtree` — **rest_for_one**. If `ring_keeper`
  dies, `log_writer` is restarted; if `pool_actor` dies, `lsp_dyn_sup`
  is restarted. Order matters because later children depend on
  earlier ones.
- `lsp_dyn_sup` — **simple_one_for_one**, per-child **transient**.
  Abnormal LSP exit restarts in place. Normal exit (operator
  `runtime_kill_lsp` or graceful EOF) does NOT restart.
- `stdio_worker` — **transient**. Clean stdin EOF returns
  `actor.stop`; supervisor lets it die without restart.

## Request lifecycle — stdio transport

```
LLM host  ─NDJSON line─►  stdio_port  ─PortMailbox─►  stdio_worker
                                                          │
                                                          │ async dispatch
                                                          │ process.spawn_unlinked
                                                          ▼
                                                    dispatch_N (worker)
                                                    ├── inserts pid into
                                                    │   pharos_request_workers[mcp_id]
                                                    │
                                                    ├── server.handle_line(pool, body)
                                                    │     │
                                                    │     ▼
                                                    │   tool's handle/2
                                                    │     │
                                                    │     ▼
                                                    │   session.with_session_and_retry
                                                    │     │
                                                    │     ▼
                                                    │   pool.get  ◄── actor.call SYNC
                                                    │     │           caller blocks
                                                    │     │           until SpawnCompleted
                                                    │     │           OR cache hit
                                                    │     ▼
                                                    │   proc.request  ◄── actor.call SYNC
                                                    │     │              caller blocks
                                                    │     │              on LSP reply
                                                    │     ▼
                                                    │   tool_helpers.json_encode(result)
                                                    │
                                                    ├── writer ← WriteResponse(json)
                                                    └── pharos_request_workers.delete(mcp_id)

stdio_worker on receiving Write(json):
   writes one stdout line. Single funnel — concurrent dispatchers
   can complete in any order without interleaving.

cancel path:
   stdio_worker reads notifications/cancelled; its dispatcher looks
   up pharos_request_workers[session|mcp_id] → the request's
   dispatcher pid, and kills it FIRST, so no reply goes out for a
   cancelled request. Then pharos_inflight[session|mcp_id] →
   (lsp_proc_subj, lsp_id): forwards $/cancelRequest to the lsp_proc.
   The kill works even when the LSP ignores $/cancelRequest.
```

Async-dispatch refactor: [src/pharos/stdio_worker.gleam](../src/pharos/stdio_worker.gleam),
[src/pharos/mcp/request_workers.gleam](../src/pharos/mcp/request_workers.gleam).

## Request lifecycle — HTTP transport

```
LLM host  ─POST /mcp─►  mist acceptor  ─►  mist conn-N (one process per HTTP req)
                                              │
                                              │ validates Mcp-Session-Id via
                                              │   sessions.validate (actor.call SYNC,
                                              │   default 60s, but O(1) op in handler)
                                              │
                                              │ runs server.handle_line(pool, body)
                                              │ ON ITS OWN PROCESS (no extra spawn)
                                              │
                                              │   tool.handle/2 → session → pool.get
                                              │   → proc.request → ... same as stdio
                                              │
                                              ▼
                                          writes JSON response, closes conn.

SSE notifications path:
   client opens GET /mcp with Accept: text/event-stream. mist conn
   process registers itself via sessions.attach_sse, then sits in
   sse_loop reading from the Subject. Server-side messages
   (diagnostics, progress) come via that channel.
```

HTTP transport: [src/pharos/mcp/http.gleam](../src/pharos/mcp/http.gleam)
(mist handler + sse_loop). Note: HTTP path does NOT populate
`pharos_request_workers` — the dispatcher table is stdio-only — so
cancel on HTTP only fires the LSP-side `$/cancelRequest`, not the
worker-kill arm.

## Daemon mode (ADR-034)

`pharos daemon --socket <path> --build <id> --key <key>` replaces the
transport children with one `daemon` actor. Every MCP session arrives
as a connection on a Unix socket and shares the one pool.

```
pharos_root
  ├─ log_subtree, pool_subtree      (as above)
  └─ daemon            permanent   pharos/daemon.gleam
       │ owns the listening socket, the session registry, the idle timer
       └─ acceptor      linked      blocks in accept/1
            └─ conn-N   UNLINKED    pharos/daemon/conn.gleam, one per shim
                 └─ dispatch_N      pharos/mcp/dispatch.gleam (as stdio)
```

Connection lifecycle:

```
accept → conn-N gets the socket → first line = hello
   op=status|stop → one JSON reply, close
   op=mcp, build matches → register (id sN), build SessionCtx from the
     hello's cwd + env, bind it, send {"pharos_hello_ok":1,...}
   then each NDJSON line → dispatch_N (bound to the session); replies
     go back on the same socket. conn-N monitors each dispatcher and
     counts it done on DOWN (a cancel kills it before it can reply).
socket closed (shim stdin EOF / shim died)
   → inflight 0: finish
   → else wait PHAROS_SHUTDOWN_DRAIN_MS (2000), then kill the session's
     leftover dispatchers + $/cancelRequest their LSP calls, finish
finish → drop the session's timeout overrides, unregister, close
last session gone → after PHAROS_DAEMON_IDLE_SECS (1800) with none:
   init:stop → app stop removes the socket + pid file
```

The shim side (`shim/`, Rust): `pharos` with no arguments connects to
`<runtime dir>/<build>-<key>.sock`. On a miss it takes `<…>.lock`
(flock), re-checks, waits on a live daemon named in `<…>.pid`, or
replaces a stale socket and spawns `erlexec … -extra daemon …` detached
(setsid, inherited fds close-on-exec, stdout/stderr to the boot log,
inside `systemd-run --user --scope` when a user manager runs). It
sends the hello and relays only complete lines to stdout. On stop or
idle exit the daemon unlinks its socket and pid file *before* the
orderly stop, so a shim arriving meanwhile starts a fresh daemon
instead of joining one on its way out.

A crashed connection is unlinked from the acceptor, so it takes only
its own session down. A crashed acceptor or daemon actor takes the
listener down; the supervisor rebuilds it, and `listen/1` replaces the
stale socket file. The daemon's stderr is its boot log (the shim
redirects it), and it logs to `<log dir>/daemon-<build>-<key>-<pid>.log`.

## Self-management (ADR-036)

`pharos self update|rollback|prune|uninstall` never boots the BEAM.
The shim works out the install from its own real path
(`<install dir>/versions/<v>` → install.sh; `…/node_modules/@pharos-mcp/<plat>/release`
→ npm, which only gets the npm command printed), then **execs**
`sh -s -- <flags>` with install.sh on stdin: the release's
`<root>/install.sh`, or for `update` one curl just downloaded (opened,
then unlinked). The shim's pid becomes `sh`. Nothing waits on a
daemon: install.sh reads `ps` once and keeps any version a running
process names (a daemon names its version dir in `-root`/`-bindir`),
and `--uninstall` refuses while one runs. `self prune` first removes
unused 0.1.x Burrito unpacks itself, by the same `ps` rule.

## pool spawn lifecycle (post-M14 refactor)

```
tool worker                  pool_actor                    spawner (process.spawn_unlinked)
    │                            │                                 (one per cache-miss key)
    │  pool.get(lang, ws, spec)  │
    │ ──actor.call(SYNC)───────► │
    │                            │  cache hit  → reply Ok(proc) ──────────────┐
    │                            │                                            │
    │                            │  inflight hit → append reply to waiters ──┐│
    │                            │                                           ││
    │                            │  miss + first → register {key: [reply]}  ▼▼
    │                            │             process.spawn_unlinked(self_subj, …)
    │                            │                            │
    │                            ◄────  actor.continue (FAST) │
    │                                                         │
    │                                                  recover_or_spawn
    │                                                  ├─ proc.recover_subject(ETS)
    │                                                  │    ↳ Ok: reuse Subject
    │                                                  │
    │                                                  └─ Error: spawn_proc
    │                                                       │
    │                                                       ▼
    │                                              dyn_sup_start_child(...)
    │                                                       │ (BLOCKING)
    │                                                       ▼ ~30-90s+
    │                                          proc.start_link_supervised
    │                                            ├─ lifecycle.start(client)
    │                                            ├─ initialize handshake
    │                                            │     (initialize_timeout_ms)
    │                                            ├─ send `initialized`
    │                                            ├─ workspace_configuration push
    │                                            └─ proc.wait_for_ready
    │                                                  (ready_timeout_ms,
    │                                                   only if readiness_token set)
    │                                                       │
    │                                                       ▼
    │                            ◄────────────── SpawnCompleted(key, Ok(proc))
    │                            │
    │                            │  monitor proc.pid via process.monitor
    │                            │  cache[key] = proc
    │                            │  each waiter ← Ok(proc)
    │                            │  inflight.delete(key)
    │                            │
    │ ◄──── Ok(proc) ─────────── │   (reply to original actor.call)
    ▼
proc.request(method, params, timeout_ms)
   │ actor.call(proc_subj, timeout_ms + 5000, SYNC)
   │
   ▼
lsp_proc's actor mailbox queues Request msg
   │ handler writes to LSP Port, blocks on Port reply
   │ inflight registers (mcp_id → (lsp_proc_subj, lsp_id))
   │
   ▼
LSP responds via Port (or pharos's per-call timeout fires) → Result
```

Pool refactor: [src/pharos/lsp/pool.gleam:440](../src/pharos/lsp/pool.gleam#L440)
(`handle_get` registers + spawns), `handle_spawn_completed` fans
out to waiters, `spawn_worker` runs the recover-or-spawn loop in
its own process so `handle_get` never blocks the actor.

## Timeout map

Every wall-clock budget that can fire, where it lives, and what
condition surfaces when it does.

| # | Layer | Where | Default | Tunable via | Fires when |
|---|-------|-------|---------|-------------|-----------|
| 1 | **Per-tool compile-time `default_timeout_ms`** | `pharos/tools/<tool>.gleam` constant | 30s (60s for `find_references`) | source edit only | Last-resort cap when no other layer overrides it. |
| 2 | **`[tool_config.<name>] default_timeout_ms`** | TOML | unset | `pharos.toml` | Per-tool global override across all languages. |
| 3 | **`[tool_config.<name>.<lang>] default_timeout_ms`** | TOML | unset | `pharos.toml` | Per-tool × per-language override (matches workspace's resolved lang id). |
| 4 | **Session override** | `pharos_session_overrides` persistent_term | unset | `runtime_set_tool_timeout` MCP tool | LLM-driven runtime bump, scoped to the MCP session that set it (ADR-034); lasts until that session disconnects or pharos restarts. ADR-021. |
| 5 | **Per-call `timeout_ms` arg** | MCP request `params.arguments.timeout_ms` | caller-supplied | every call site | Wins all other layers. The harness uses this for the matrix. |
| 6 | **`initialize_timeout_ms`** | `ServerConfig` per server | 90s; scala 180s | `pharos.toml` `[[languages.<id>.servers]] initialize_timeout_ms` | LSP `initialize` handshake. Pool's spawner returns `Error(SpawnFailed)` if this fires. |
| 7 | **`ready_timeout_ms`** | `ServerConfig` per server | 60s (`languages.default_ready_timeout_ms`) | `pharos.toml` | Total spawn-time readiness budget: `$/progress` drain **plus** the ADR-024 probe loop, combined. Renamed from `readiness_timeout_ms` by ADR-024. |
| 8 | **`pool.get` outer `actor.call`** | `pool.gleam` | `spec.initialize_timeout_ms + 30_000` | derived from #6 | Caller's deadline waiting for `SpawnCompleted` from spawner. Returns `Error(ProcStartFailed("call timed out"))`. |
| 9 | **`proc.request` outer `actor.call`** | `proc.gleam` | `timeout_ms + 5_000` | derived from #5 | Caller's deadline waiting for the LSP-side reply. Returns `ProcCallTimeout` (distinct from the LSP's own timeout). |
| 10 | **`proc.{push_configuration,send_notification}` `actor.call`** | `proc.gleam` | 5s | not exposed | Backpressure on the Port write. |
| 11 | **`proc.get_client`** | `proc.gleam` | 1s | not exposed | Cheap fetch of the underlying `Client` reference. |
| 12 | **`sessions.{issue,validate,attach,detach}` `actor.call`** | `sessions.gleam` | 60s (`default_call_timeout_ms`) | not exposed | HTTP session bookkeeping — should never fire in practice. |
| 13 | **HTTP request timeout** | mist | mist defaults | not exposed | Per-HTTP-request wall-clock. |
| 15 | **Daemon idle exit** | `daemon.gleam` | 1800s | `PHAROS_DAEMON_IDLE_SECS` | No session connected for this long: the daemon stops itself (ADR-034). |
| 17 | **LSP idle stop** | `pool.gleam` (`IdleSweep`) | 1800s; java, scala, haskell 7200s | `PHAROS_LSP_IDLE_SECS` (all languages), `[languages.<id>] idle_stop_secs` | No `pool.get` for the key, from any session: the LSP is evicted (stdin closed) and respawns on the next call (ADR-034). |
| 16 | **Session drain on disconnect** | `daemon/conn.gleam` | 2000ms | `PHAROS_SHUTDOWN_DRAIN_MS` | A closed connection's in-flight requests get this long before they are cancelled. |
| 14 | **Harness wall-clock** | `bin/dogfood-23lang.py` | `timeout_ms / 1000 + 45s` | `PER_LANG_TIMEOUT_MS` const + per-target override | Harness gives up + sends `notifications/cancelled`. M14 dogfood-only. |

Resolution stack at request time (ADR-021): #5 wins → #4 → #3 → #2
→ #1. The pool / proc / readiness timeouts (#6-12) operate on
different dimensions: they bound spawn + handshake, not per-call
work, so they layer rather than compete.

## Sync vs async map

Every place where one process waits on another. "Sync" means the
caller is blocked on `actor.call` (or equivalent). "Async" means
the caller posts and continues.

| Caller → Callee | Kind | Note |
|-----------------|------|------|
| stdio_worker → dispatch_N | **async** (`process.spawn_unlinked`) | M10 refactor. Worker reads next line immediately. |
| mist conn-N → server.handle_line | sync (in-process call, no actor hop) | Each HTTP conn process owns its own dispatch. |
| dispatch_N → server.handle_line | sync (in-process call) | Same module, plain function. |
| server.handle_line → tool.handle | sync | Same module, plain function. |
| tool.handle → session.with_session_and_retry | sync | Pure orchestration. |
| session.with_session_and_retry → **pool.get** | **SYNC actor.call** (#9) | Caller blocks until `SpawnCompleted` from spawner (or cache hit). Pool's HANDLER returns fast since M14; only the caller is blocked. |
| pool actor → **spawner process** | **async** (`process.spawn_unlinked`) | M14 refactor. Pool actor doesn't block. |
| spawner → dyn_sup_start_child | sync (Erlang FFI) | Blocking shell-out + handshake + readiness drain runs IN the spawner, not the pool. |
| pool actor → **proc.send_notification** | **SYNC actor.call (5s)** (#11) | `handle_ensure_open` blocks pool actor up to 5s waiting on LSP port write. Audit follow-up — not the M14 bottleneck. |
| session → **proc.request** | **SYNC actor.call** (#10) | Caller blocks until LSP responds OR proc-side timeout (#5). Per-LSP serialization is correct: each LSP has its own actor. |
| proc actor → LSP Port write | sync (Port `command`) | Port write is non-blocking at the OS level; appears sync to the actor. |
| proc actor → LSP Port read | async (Port message into mailbox) | Decoded inside the actor's handle loop. |
| sessions.{issue,validate,…} | **SYNC actor.call** (#13) | Always O(1) ETS-like dict ops; never the bottleneck. |
| pool.evict / EvictAllServers | **async** (`actor.send`) | Fire-and-forget. |
| pool.close_all / kill_lsp | **SYNC actor.call** | Caller awaits confirmation. |
| log.emit | async (`actor.send` to log_writer) | All hot-path log calls are fire-and-forget. |

**Cross-LSP parallelism in practice:**

- Concurrent tool calls to **the same LSP** serialize at the
  `proc` actor's mailbox. The LSP itself is single-stream over a
  Port so this matches the protocol.
- Concurrent tool calls to **different LSPs** run fully parallel —
  each `proc` is an independent actor; pool returns cache hits
  for each in O(1).
- **Concurrent cold-start spawns of different LSPs** run in
  parallel since M14: each cache-miss key gets its own spawner
  process under `process.spawn_unlinked`. Pre-M14, the pool actor
  serialized them.
- **Concurrent cold-start spawns of the same key** dedupe to one
  spawner with N waiters via `inflight` waitlist.

## LSP child lifecycle inside one `lsp_proc`

```
lsp_proc actor                    LSP child (OS process)
    │                                  │
    │   port = open_port(cmd, args)    │
    │ ──────────────────────────────►  │  (BEAM Port wraps OS subprocess)
    │                                  │
    │   write initialize                ►  reads from stdin
    │                                  │
    │  ◄──────────────────────────────  reply initialize
    │  (within initialize_timeout_ms)  │
    │                                  │
    │   write initialized               ►
    │                                  │
    │   write workspace/configuration  ─►  (if workspace_configuration set)
    │   ◄── server replies              ─
    │                                  │
    │   wait_for_ready                  │  (if readiness_token set)
    │  ◄── $/progress begin            ─
    │  ◄── $/progress report           ─
    │  ◄── $/progress end              ─  (token end signals indexing done)
    │  (within ready_timeout_ms)       │
    │                                  │
    │ ━━ ready for tool requests ━━    │
    │                                  │
    │   write textDocument/didOpen     ─►  (once per (lang, ws, srv, uri);
    │                                       deduped in pool actor state)
    │                                  │
    │   write request (method, params) ─►
    │  ◄── reply / error / notification ─
    │   ... interleaved with $/progress, $/log, diagnostics, server requests
    │                                  │
    │   on Close: write shutdown        ─►
    │             write exit            ─►
    │                                  ── process exits
    │                                  │
    │   actor.stop                      │
```

Lifecycle source: [src/pharos/lsp/lifecycle.gleam](../src/pharos/lsp/lifecycle.gleam),
[src/pharos/lsp/proc.gleam](../src/pharos/lsp/proc.gleam).

## Where things get stuck (M14 dogfood findings)

Tracing the cascade observed in M14 Pass 1 ([doc/m14-test-plan.md](m14-test-plan.md)):

- **Pre-M14**: pool actor blocked 30-90s per spawn inside
  `handle_get`. 23 cold-start `pool.get` calls serialized through
  one mailbox = ~17 min before the last caller saw a Proc.
  Harness's 35s wall-clock fired repeatedly, orphaning ~316
  in-flight workers (one per timed-out tool call) all waiting on
  `pool.get`. Even broken-LSP short-circuit only bounded the
  damage per-lang, not pharos-wide.
- **M14 pool refactor**: pool actor handler always returns fast.
  Spawns run in parallel under `process.spawn_unlinked`. But the
  CALLER of `pool.get` still blocks until `SpawnCompleted` since
  it's an `actor.call`. So the harness's wall-clock still fires
  on the FIRST tool call to a slow LSP — it's just no longer
  serializing OTHER LSPs.
- **Remaining bottleneck**: per-LSP cold-start cost itself.
  jdtls (5-15 min real cold-start on kafka), HLS (5+ min cabal
  v2-repl), metals (2-3 min Bloop bootstrap) genuinely take long
  enough that the harness's 3-tool short-circuit threshold fires
  before the first response. Pharos's `initialize_timeout_ms` /
  `ready_timeout_ms` are tuned conservatively but the harness
  gives up before pharos's own deadline. Future fix candidates:
  per-spawn **warmup probe** (fire `workspace/symbol`, retry
  until non-error) so pool releases waiters only when the LSP
  has demonstrably answered something; auto-tuned timeout cache
  keyed on observed first-call cost; LLM-visible `$/progress`
  pass-through so the harness knows "still working" vs "dead".

## File index

| Concern | File |
|---------|------|
| Top-level supervisor | [src/pharos/supervisor.gleam](../src/pharos/supervisor.gleam) |
| Boot path | [src/pharos.gleam](../src/pharos.gleam) |
| LSP child supervisor | [src/pharos_lsp_dyn_sup.erl](../src/pharos_lsp_dyn_sup.erl) |
| Pool actor | [src/pharos/lsp/pool.gleam](../src/pharos/lsp/pool.gleam) |
| LSP proc actor | [src/pharos/lsp/proc.gleam](../src/pharos/lsp/proc.gleam) |
| LSP handshake | [src/pharos/lsp/lifecycle.gleam](../src/pharos/lsp/lifecycle.gleam) |
| Per-LSP config | [src/pharos/lsp/languages.gleam](../src/pharos/lsp/languages.gleam) |
| MCP stdio worker | [src/pharos/stdio_worker.gleam](../src/pharos/stdio_worker.gleam) |
| Per-request dispatcher | [src/pharos/mcp/request_workers.gleam](../src/pharos/mcp/request_workers.gleam) |
| MCP HTTP listener | [src/pharos/mcp/http.gleam](../src/pharos/mcp/http.gleam) |
| HTTP session store | [src/pharos/mcp/sessions.gleam](../src/pharos/mcp/sessions.gleam) |
| MCP dispatch | [src/pharos/mcp/server.gleam](../src/pharos/mcp/server.gleam) |
| Tool session orchestrator | [src/pharos/tools/session.gleam](../src/pharos/tools/session.gleam) |
| Per-tool defaults | `src/pharos/tools/<tool>.gleam` (`default_timeout_ms` const) |
| Session timeout overrides | [src/pharos/tools/session_overrides.gleam](../src/pharos/tools/session_overrides.gleam) |
| Per-session context | [src/pharos/session_ctx.gleam](../src/pharos/session_ctx.gleam) |
| Per-line dispatch (stdio + daemon) | [src/pharos/mcp/dispatch.gleam](../src/pharos/mcp/dispatch.gleam) |
| Daemon listener, registry, idle timer | [src/pharos/daemon.gleam](../src/pharos/daemon.gleam) |
| Daemon connection (hello, session, drain) | [src/pharos/daemon/conn.gleam](../src/pharos/daemon/conn.gleam) |
| Shim + launcher (Rust; spawn lock, hello, line relay) | [shim/src/client.rs](../shim/src/client.rs), [shim/src/launch.rs](../shim/src/launch.rs) |
| `pharos self …` and the 0.1.x cleanup (Rust) | [shim/src/self_cmd.rs](../shim/src/self_cmd.rs), [install.sh](../install.sh) |
| Log subtree | [src/pharos/log/](../src/pharos/log/) |
| Inflight table | [src/pharos/lsp/inflight.gleam](../src/pharos/lsp/inflight.gleam) |
| Cancel routing | [src/pharos/mcp/server.gleam](../src/pharos/mcp/server.gleam) `log_cancel_notification` |
