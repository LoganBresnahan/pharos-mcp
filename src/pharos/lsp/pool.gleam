//// Kept-warm LSP pool.
////
//// One actor owns a cache of `(language, workspace, server_id) -> Proc`.
//// Tools call `get/5` to fetch a Proc; on cache miss the pool spawns
//// a fresh `lsp_proc` (which itself runs the initialize handshake)
//// and stashes it. On cache hit the pool returns the existing Proc
//// immediately — cold-start cost is paid once per
//// `(language, workspace, server_id)` per session, not per tool call.
////
//// Stage 2 of ADR-019: the cache key gains a `server_id` component so
//// a single language can spawn multiple LSPs (e.g. python = pyright +
//// ruff at Stage 3) without the pool collapsing them onto the same
//// Proc. Single-server languages still produce one cache entry per
//// workspace; the new key dimension is invisible to them.
////
//// M9 Phase B: pool monitors each `Proc` via `process.monitor`. On
//// the proc's exit (DOWN), pool evicts the cache entry so the next
//// tool call respawns transparently. ADR-013 calls this
//// "structure-by-supervision, communication-by-monitoring."
////
//// M14 polish: spawn work runs on a per-(lang, ws, server_id) worker
//// process instead of inside the pool actor's `handle_get`. Before
//// the change, the pool actor blocked 30-90s during each cold-start
//// (rust-analyzer initialize + readiness drain), serializing every
//// other `pool.get` queued in its mailbox — 23 fresh-pool gets at
//// ~45s each = ~17 min before the last caller saw a Proc. With the
//// worker pattern, the pool actor's handler returns immediately
//// after registering the caller in an `inflight` waitlist; the
//// worker does the slow spawn off-actor and sends `SpawnCompleted`
//// back to the pool. Multiple concurrent spawns of distinct keys
//// run in parallel (one worker each); concurrent gets for the SAME
//// key dedupe — one worker, many waiters share its result. See the
//// M14 dogfood Pass 1 finding (143/523 cells PASS, 16/23 langs
//// short-circuiting) for the regression this fixes.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/languages.{
  type WarmupProbe, ProbeDocumentSymbol, ProbeNone, ProbeWorkspaceSymbol,
}
import pharos/lsp/lifecycle
import pharos/lsp/proc.{type Proc}
import pharos/lsp/server_request_handlers
import pharos/workspace_root

/// Cache key tuple. `(language, workspace, server_id)`. Stage 2 of
/// ADR-019 — server_id distinguishes per-language servers like
/// `"pyright"` and `"ruff"` for the same `(language, workspace)`.
pub type ProcKey =
  #(String, String, String)

pub opaque type Pool {
  Pool(subject: Subject(Msg))
}

pub type SpawnSpec {
  SpawnSpec(
    /// Server id within the language. Becomes part of the cache key
    /// so a multi-server language spawns one Proc per server.
    server_id: String,
    command: String,
    args: List(String),
    init_params: json.Json,
    /// Optional `workspace/didChangeConfiguration` payload pushed
    /// post-`initialized`. Also used to answer the server's pull-style
    /// `workspace/configuration` requests via a per-language handler
    /// override on the Proc.
    workspace_configuration: option.Option(dict.Dict(String, json.Json)),
    /// Optional `$/progress` token the freshly-spawned LSP emits when
    /// indexing kicks in.
    readiness_token: option.Option(String),
    /// Per ADR-024: total wall-clock budget for `$/progress` drain +
    /// the readiness probe loop combined. The probe waits up to this
    /// long for the LSP to demonstrably answer one query before pool
    /// releases waiters.
    ready_timeout_ms: Int,
    /// Wall-clock cap for the `initialize` handshake. Per-server so
    /// jdtls (heavy) gets headroom while faster servers can fail
    /// fast. Mirrored from `ServerConfig.initialize_timeout_ms` with
    /// the global default applied when None.
    initialize_timeout_ms: Int,
    /// Spawn-time readiness probe (ADR-024). Pool's spawner fires
    /// this query post-drain and waits for a non-null / non-error
    /// response before marking the proc Ready. Default
    /// `ProbeWorkspaceSymbol("")` covers nearly every bundled LSP;
    /// per-server overrides land in `languages.gleam`.
    warmup_probe: WarmupProbe,
  )
}

/// Per-LSP spawn-time state (ADR-024). Tracked per cache key in
/// `state.lsp_state` alongside `cache` and `inflight`. Successful
/// init+drain+probe transitions Spawning → Probing → Ready; init
/// or probe-budget exhaustion lands as Failed; the existing
/// ProcDown handler evicts the cache entry on death (no explicit
/// Dead state — absence from the map is the post-mortem signal).
pub type LspState {
  Spawning
  Probing
  Ready
  Failed(reason: String)
}

/// Per-key bookkeeping for `runtime_lsp_state`. Records the cache
/// key plus probe progress so operators can see at a glance which
/// LSPs are warming, ready, or failed.
pub type LspStateEntry {
  LspStateEntry(
    language: String,
    workspace: String,
    server_id: String,
    state: LspState,
    spawned_at_unix_ms: Int,
    probe_attempts: Int,
    last_probe_error: option.Option(String),
    /// Number of callers currently parked in the inflight waitlist
    /// for this key. Zero once `SpawnCompleted` fires. Used to
    /// diagnose stuck spawns where many waiters accumulated.
    inflight_waiters: Int,
  )
}

/// Pool-level diagnostics returned by `snapshot/1`. Captures
/// metrics that don't fit on a per-key entry (mailbox depth,
/// totals) so the operator can correlate "many in-flight spawns"
/// with "pool mailbox blocked" when the regression is
/// investigated. ADR-024 follow-up for diagnosing the Option B
/// regression.
pub type PoolSnapshot {
  PoolSnapshot(
    entries: List(LspStateEntry),
    /// `erlang:process_info(self(), message_queue_len)` measured
    /// inside the pool actor handler — a non-zero value means
    /// other Msg's were waiting behind this SnapshotReq.
    mailbox_len: Int,
    /// Number of distinct keys currently in `inflight`.
    inflight_key_count: Int,
    /// Sum of waiter Subjects across every inflight entry.
    inflight_waiter_total: Int,
    /// Number of distinct keys currently being awaited via a
    /// spawner monitor. Equals number of in-flight spawn workers.
    spawner_monitor_count: Int,
    /// Number of LSP-child monitors active (i.e. cached procs
    /// with a live DOWN monitor).
    lsp_child_monitor_count: Int,
    /// Number of entries in `cache` (live Ready procs).
    cache_size: Int,
  )
}

pub type GetError {
  ProcStartFailed(reason: String)
  /// ADR-024: spawn-time readiness probe failed to surface a
  /// non-null / non-error response within `ready_timeout_ms`. The
  /// LSP may have init'd but never finished indexing (or never
  /// answered `workspace/symbol`).
  ProbeFailed(reason: String)
  /// ADR-024 follow-up: spawn worker process died (Erlang
  /// exception, FFI panic, etc.) before it could send
  /// `SpawnCompleted`. Pool's monitor caught the DOWN; waiters
  /// get this typed error rather than hanging forever.
  SpawnerCrashed(reason: String)
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Get(
    language: String,
    workspace: String,
    spec: SpawnSpec,
    reply_to: Subject(Result(Proc, GetError)),
  )
  Evict(language: String, workspace: String, server_id: String)
  /// Evict every cached entry for `(language, workspace)`, regardless
  /// of server_id. Used by tool layer's transport-error retry path so
  /// a single transport failure clears every server for the failing
  /// workspace, not just the one that hit the error.
  EvictAllServers(language: String, workspace: String)
  CloseAll
  EnsureOpen(
    language: String,
    workspace: String,
    server_id: String,
    uri: String,
    language_id: String,
    content: String,
    reply_to: Subject(Result(Nil, EnsureOpenError)),
  )
  /// Sent to the pool actor when one of its monitored procs exits.
  ProcDown(monitor_ref: process.Monitor, reason: dynamic.Dynamic)
  /// Operator-requested kill via `kill_lsp/4`. server_id="" means
  /// "kill every server cached for this (language, workspace)".
  KillLsp(
    language: String,
    workspace: String,
    server_id: String,
    reply_to: Subject(KillStatus),
  )
  /// Sent by a spawner worker when its recover-or-spawn finished.
  /// The worker captures the pool's self-subject at spawn time so
  /// `process.send/2` reaches the pool actor's mailbox. The pool
  /// handler reads the waitlist for `key` from `inflight`, replies
  /// to every waiter with the result, updates `cache` on success,
  /// and removes the `inflight` entry. See `spawn_worker/4`.
  SpawnCompleted(key: ProcKey, result: Result(Proc, GetError))
  /// Sent by the spawner worker mid-flight to advance the LSP state
  /// machine (Spawning → Probing) and bump probe-attempt counters
  /// for `runtime_lsp_state`. Side-effect only: never replies.
  SpawnProgress(
    key: ProcKey,
    state: LspState,
    probe_attempts: Int,
    last_probe_error: option.Option(String),
  )
  /// Read-only snapshot of cache + state-map + inflight for
  /// `runtime_lsp_state`. Bookkeeping-only — handler returns
  /// immediately.
  SnapshotReq(reply_to: Subject(PoolSnapshot))
}

pub type EnsureOpenError {
  /// No LSP cached for this `(language, workspace, server_id)`.
  NoCachedClient
  /// `proc.send_notification` returned an error.
  SendFailed
}

type State {
  State(
    cache: Dict(ProcKey, Proc),
    /// Reverse index from monitor ref to cache key.
    monitors: Dict(process.Monitor, ProcKey),
    /// `(language, workspace, server_id, uri)` — track which
    /// documents have been opened on which (language, workspace,
    /// server_id) combo.
    opened: Set(#(String, String, String, String)),
    /// In-flight spawn waitlists. While a spawner worker is running
    /// for `key`, every additional `Get(key, ...)` appends its
    /// reply Subject to the list. When `SpawnCompleted(key, ...)`
    /// arrives, the pool replies to every waiter with the same
    /// result and clears the entry. Dedupes concurrent gets for the
    /// same key onto a single spawn.
    inflight: Dict(ProcKey, List(Subject(Result(Proc, GetError)))),
    /// ADR-024 per-LSP state map. Populated when a spawn starts
    /// (`Spawning`), advanced to `Probing` via `SpawnProgress` when
    /// the worker transitions from init/drain into the probe loop,
    /// advanced to `Ready` on `SpawnCompleted(Ok(_))`, or to
    /// `Failed` on `SpawnCompleted(Error(_))`. Entries persist
    /// beyond spawn completion so `runtime_lsp_state` can show
    /// "Ready since when"; removed on cache eviction.
    lsp_state: Dict(ProcKey, LspStateBookkeeping),
    /// Reverse index from spawner-process monitor ref to the cache
    /// key whose spawn it owns. Pool monitors each spawn worker so
    /// a spawner crash before `SpawnCompleted` fan-replies an
    /// explicit error to waiters instead of leaving them hung.
    /// Removed in `handle_spawn_completed` (normal path) or in
    /// `handle_proc_down` (crash path). Separate from `monitors`
    /// because LSP-child DOWN and spawner DOWN need different
    /// recovery.
    spawner_monitors: Dict(process.Monitor, ProcKey),
    /// Pool actor's own Subject — captured at init so spawner
    /// workers (running off-actor) can post `SpawnCompleted`
    /// back into the pool's mailbox.
    self_subject: Subject(Msg),
  )
}

/// Pool-local extension of `LspStateEntry` minus the cache key
/// (which is the dict key). Carries spawn timestamps + probe
/// counters used by `runtime_lsp_state`.
type LspStateBookkeeping {
  LspStateBookkeeping(
    state: LspState,
    spawned_at_unix_ms: Int,
    probe_attempts: Int,
    last_probe_error: option.Option(String),
  )
}

// initialize_timeout_ms is now per-server via SpawnSpec; the global
// default lives in `pharos/lsp/languages.default_initialize_timeout_ms`.
// SpawnSpec.initialize_timeout_ms is filled by callers (session.gleam)
// from ServerConfig.initialize_timeout_ms with the default applied
// when None.

const default_call_timeout_ms: Int = 60_000

/// Spawn the pool. Returns a handle the rest of the program shares
/// for `get/5`, `evict/4`, and `close_all/1`.
pub fn start() -> Result(Pool, StartError) {
  start_internal()
  |> result.map(fn(started) {
    let pool = Pool(subject: started.data)
    register_global(started.data)
    pool
  })
  |> result.map_error(StartFailedActor)
}

/// Supervised entry point — spawns the pool with the same wiring
/// as `start/0` but returns the `actor.Started` shape.
pub fn start_supervised() -> Result(
  actor.Started(Subject(Msg)),
  actor.StartError,
) {
  case start_internal() {
    Ok(started) -> {
      register_global(started.data)
      // Emit a boot line so a supervisor-driven restart is visible in
      // logs without needing SASL reports. Pool restart wipes the
      // cache + drops in-flight workers, so every dogfood + production
      // log read should be able to spot it cheaply.
      log.info_at(
        "pharos/lsp/pool",
        "pool actor started (subject registered in persistent_term)",
      )
      Ok(started)
    }
    Error(e) -> Error(e)
  }
}

fn start_internal() -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  let initialise = fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(monitor: m, reason: r, ..) ->
            ProcDown(monitor_ref: m, reason: process_reason_as_dynamic(r))
          process.PortDown(monitor: m, reason: r, ..) ->
            ProcDown(monitor_ref: m, reason: process_reason_as_dynamic(r))
        }
      })
    Ok(
      actor.initialised(State(
        cache: dict.new(),
        monitors: dict.new(),
        opened: set.new(),
        inflight: dict.new(),
        lsp_state: dict.new(),
        spawner_monitors: dict.new(),
        self_subject: self,
      ))
      |> actor.selecting(selector)
      |> actor.returning(self),
    )
  }

  actor.new_with_initialiser(default_call_timeout_ms, initialise)
  |> actor.on_message(handle_message)
  |> actor.start()
}

/// Read the supervised pool's Subject from persistent_term.
pub fn global() -> Result(Pool, Nil) {
  case lookup_global() {
    Ok(subject) -> Ok(Pool(subject: subject))
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "pharos_runtime_ffi", "pool_register")
fn register_global(subject: Subject(Msg)) -> Nil

@external(erlang, "pharos_runtime_ffi", "pool_lookup")
fn lookup_global() -> Result(Subject(Msg), Nil)

@external(erlang, "pharos_runtime_ffi", "as_dynamic")
fn coerce_to_dynamic(x: a) -> dynamic.Dynamic

fn process_reason_as_dynamic(reason: process.ExitReason) -> dynamic.Dynamic {
  coerce_to_dynamic(reason)
}

/// Fetch a `Proc` for the given language and workspace, spawning a
/// fresh LSP if none is cached. `spec.server_id` becomes part of the
/// cache key.
pub fn get(
  pool: Pool,
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Proc, GetError) {
  let Pool(subject) = pool
  // Caller-side timeout covers the worst-case spawn cost: the LSP's
  // initialize budget plus the post-init drain + readiness probe
  // budget (ADR-024), plus 5s slack for pool's own bookkeeping
  // (workspace_config push, ETS bridge writes, monitor wiring).
  // ADR-024 retired the older `initialize + 30_000` magic: the probe
  // budget is now explicit so callers can reason about the envelope.
  // ADR-024 "trust the spawner" envelope. Gleam_otp's actor.call
  // KILLS the caller on timeout (no Result(_, Timeout); raises a
  // runtime exception that exits the calling process). Pool's
  // spawner already self-bounds at `initialize_timeout_ms +
  // ready_timeout_ms` and pool actor's `handle_spawn_completed`
  // always replies (success OR error). The cross-layer call_timeout
  // here used to be `init + ready + 5_000` but the 5s slack was
  // fragile: actor scheduling + message latency under load
  // occasionally pushed past it on slow LSPs (jdtls on kafka), the
  // caller (tool dispatcher worker) died, and the harness saw
  // mysterious silence instead of a typed error. Solution: defer
  // entirely to the spawner. Pool actor's `handle_proc_down` for
  // spawner DOWN events fans error to waiters, so a crashed
  // spawner unblocks waiters quickly. Caller never timeout-dies.
  // 24h is "effectively forever" — if a spawn hangs for a day, the
  // host already timed out at MCP layer.
  let call_timeout = 86_400_000
  actor.call(subject, call_timeout, fn(reply) {
    Get(language, workspace, spec, reply)
  })
}

/// Drop one cached entry. Tool layer can call this on transport
/// error before retrying.
pub fn evict(
  pool: Pool,
  language: String,
  workspace: String,
  server_id: String,
) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, Evict(language, workspace, server_id))
}

/// Drop every cached entry for `(language, workspace)`, regardless of
/// server_id. Tools that don't care about which server hit a
/// transport error use this to keep the retry path simple.
pub fn evict_all_servers(
  pool: Pool,
  language: String,
  workspace: String,
) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, EvictAllServers(language, workspace))
}

pub type KillStatus {
  Killed(count: Int)
  NotFound
}

/// Operator-requested kill of one or all LSPs for a
/// `(language, workspace)`. Empty `server_id` kills every server
/// cached for that pair.
pub fn kill_lsp(
  pool: Pool,
  language: String,
  workspace: String,
  server_id: String,
) -> KillStatus {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    KillLsp(language, workspace, server_id, reply)
  })
}

/// Close every cached LSP. Called on graceful shutdown.
pub fn close_all(pool: Pool) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, CloseAll)
}

/// ADR-024: read-only snapshot of every per-LSP state entry pool
/// is currently tracking — both in-flight spawns and finished
/// (Ready / Failed) — plus pool-level diagnostics (mailbox depth,
/// inflight/monitor totals). Bookkeeping-only synchronous call;
/// the actor returns immediately so this is safe to invoke from
/// request handlers.
pub fn snapshot(pool: Pool) -> PoolSnapshot {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    SnapshotReq(reply)
  })
}

/// Ensure the cached LSP for
/// `(language, workspace, server_id)` has been told about this
/// document via `textDocument/didOpen`. Idempotent.
pub fn ensure_open(
  pool: Pool,
  language: String,
  workspace: String,
  server_id: String,
  uri: String,
  language_id: String,
  content: String,
) -> Result(Nil, EnsureOpenError) {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    EnsureOpen(language, workspace, server_id, uri, language_id, content, reply)
  })
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Get(language, workspace, spec, reply) ->
      handle_get(state, language, workspace, spec, reply)

    Evict(language, workspace, server_id) ->
      handle_evict(state, language, workspace, server_id)

    EvictAllServers(language, workspace) ->
      handle_evict_all(state, language, workspace)

    CloseAll -> handle_close_all(state)

    EnsureOpen(language, workspace, server_id, uri, language_id, content, reply) ->
      handle_ensure_open(
        state,
        language,
        workspace,
        server_id,
        uri,
        language_id,
        content,
        reply,
      )

    ProcDown(monitor_ref:, reason:) ->
      handle_proc_down(state, monitor_ref, reason)

    KillLsp(language, workspace, server_id, reply_to) ->
      handle_kill_lsp(state, language, workspace, server_id, reply_to)

    SpawnCompleted(key, result) -> handle_spawn_completed(state, key, result)

    SpawnProgress(key, lsp_state, probe_attempts, last_probe_error) ->
      handle_spawn_progress(
        state,
        key,
        lsp_state,
        probe_attempts,
        last_probe_error,
      )

    SnapshotReq(reply_to) -> handle_snapshot(state, reply_to)
  }
}

fn handle_spawn_progress(
  state: State,
  key: ProcKey,
  lsp_state: LspState,
  probe_attempts: Int,
  last_probe_error: option.Option(String),
) -> actor.Next(State, Msg) {
  trace_pool_event(
    "SPAWN_PROGRESS",
    key,
    [
      #("state", describe_lsp_state(lsp_state)),
      #("probe_attempts", int.to_string(probe_attempts)),
      #(
        "last_err",
        case last_probe_error {
          option.Some(e) -> e
          option.None -> ""
        },
      ),
    ],
  )
  let spawned_at = case dict.get(state.lsp_state, key) {
    Ok(bk) -> bk.spawned_at_unix_ms
    Error(_) -> system_time_ms()
  }
  let updated =
    dict.insert(
      state.lsp_state,
      key,
      LspStateBookkeeping(
        state: lsp_state,
        spawned_at_unix_ms: spawned_at,
        probe_attempts: probe_attempts,
        last_probe_error: last_probe_error,
      ),
    )
  actor.continue(State(..state, lsp_state: updated))
}

fn handle_snapshot(
  state: State,
  reply_to: Subject(PoolSnapshot),
) -> actor.Next(State, Msg) {
  let entries =
    state.lsp_state
    |> dict.to_list
    |> list.map(fn(pair) {
      let #(#(language, workspace, server_id), bk) = pair
      let waiters = case dict.get(state.inflight, #(language, workspace, server_id)) {
        Ok(list) -> list.length(list)
        Error(_) -> 0
      }
      LspStateEntry(
        language: language,
        workspace: workspace,
        server_id: server_id,
        state: bk.state,
        spawned_at_unix_ms: bk.spawned_at_unix_ms,
        probe_attempts: bk.probe_attempts,
        last_probe_error: bk.last_probe_error,
        inflight_waiters: waiters,
      )
    })
  let inflight_waiter_total =
    state.inflight
    |> dict.values
    |> list.fold(0, fn(acc, l) { acc + list.length(l) })
  let snap =
    PoolSnapshot(
      entries: entries,
      mailbox_len: self_mailbox_len(),
      inflight_key_count: dict.size(state.inflight),
      inflight_waiter_total: inflight_waiter_total,
      spawner_monitor_count: dict.size(state.spawner_monitors),
      lsp_child_monitor_count: dict.size(state.monitors),
      cache_size: dict.size(state.cache),
    )
  process.send(reply_to, snap)
  actor.continue(state)
}

@external(erlang, "pharos_runtime_ffi", "self_mailbox_len")
fn self_mailbox_len() -> Int

fn handle_kill_lsp(
  state: State,
  language: String,
  workspace: String,
  server_id: String,
  reply: Subject(KillStatus),
) -> actor.Next(State, Msg) {
  // Server_id == "" → kill every server for (language, workspace).
  let matching =
    state.cache
    |> dict.to_list
    |> list.filter(fn(entry) {
      let #(#(l, w, s), _) = entry
      l == language
      && w == workspace
      && case server_id {
        "" -> True
        _ -> s == server_id
      }
    })

  case matching {
    [] -> {
      process.send(reply, NotFound)
      actor.continue(state)
    }
    _ -> {
      let count =
        list.fold(matching, 0, fn(acc, entry) {
          let #(key, spawned) = entry
          let #(l, w, s) = key
          proc.close(spawned)
          proc.forget_subject(l, w, s)
          log.fields_at(
            "pharos/lsp/pool",
            log_entry.Warn,
            "operator-requested kill of lsp_proc",
            [#("language", l), #("workspace", w), #("server", s)],
          )
          acc + 1
        })
      let killed_keys = list.map(matching, fn(entry) { entry.0 })
      let cache =
        list.fold(killed_keys, state.cache, fn(c, k) { dict.delete(c, k) })
      let lsp_state =
        list.fold(killed_keys, state.lsp_state, fn(s, k) { dict.delete(s, k) })
      let opened =
        set.filter(state.opened, fn(quad) {
          let #(l, w, s, _) = quad
          !list.any(killed_keys, fn(k) {
            let #(kl, kw, ks) = k
            l == kl && w == kw && s == ks
          })
        })
      process.send(reply, Killed(count))
      actor.continue(
        State(..state, cache: cache, opened: opened, lsp_state: lsp_state),
      )
    }
  }
}

fn handle_get(
  state: State,
  language: String,
  workspace: String,
  spec: SpawnSpec,
  reply: Subject(Result(Proc, GetError)),
) -> actor.Next(State, Msg) {
  let key = #(language, workspace, spec.server_id)

  case dict.get(state.cache, key) {
    // Cache hit — reply immediately, no actor blocking.
    Ok(existing) -> {
      trace_pool_event(
        "GET",
        key,
        [
          #("path", "cache_hit"),
          #("inflight_total", int.to_string(dict.size(state.inflight))),
        ],
      )
      process.send(reply, Ok(existing))
      actor.continue(state)
    }

    Error(_) ->
      case dict.get(state.inflight, key) {
        // Another caller already kicked off the spawner. Join its
        // waitlist; one spawn, many waiters share the result.
        Ok(waiters) -> {
          let inflight =
            dict.insert(state.inflight, key, [reply, ..waiters])
          trace_pool_event(
            "GET",
            key,
            [
              #("path", "join_waitlist"),
              #("waiters", int.to_string(list.length(waiters) + 1)),
              #("inflight_total", int.to_string(dict.size(state.inflight))),
            ],
          )
          actor.continue(State(..state, inflight: inflight))
        }

        // First caller — register and spawn a worker that does the
        // recover-or-fresh-spawn off-actor. The worker posts
        // SpawnCompleted back to the pool when finished. Monitor
        // the worker so a crash before SpawnCompleted fans an
        // error to waiters via handle_proc_down (ADR-024 follow-up).
        Error(_) -> {
          let spawner_pid = spawn_worker(state.self_subject, key, spec)
          let spawner_monitor = process.monitor(spawner_pid)
          let inflight = dict.insert(state.inflight, key, [reply])
          let spawner_monitors =
            dict.insert(state.spawner_monitors, spawner_monitor, key)
          trace_pool_event(
            "GET",
            key,
            [
              #("path", "spawn_started"),
              #("spawner_pid", describe_pid(spawner_pid)),
              #(
                "inflight_total",
                int.to_string(dict.size(state.inflight) + 1),
              ),
              #(
                "spawner_monitors",
                int.to_string(dict.size(state.spawner_monitors) + 1),
              ),
            ],
          )
          // ADR-024: record the Spawning state immediately so
          // runtime_lsp_state can observe an in-flight spawn between
          // Get arrival and the worker's first SpawnProgress message.
          let lsp_state =
            dict.insert(
              state.lsp_state,
              key,
              LspStateBookkeeping(
                state: Spawning,
                spawned_at_unix_ms: system_time_ms(),
                probe_attempts: 0,
                last_probe_error: option.None,
              ),
            )
          actor.continue(
            State(
              ..state,
              inflight: inflight,
              lsp_state: lsp_state,
              spawner_monitors: spawner_monitors,
            ),
          )
        }
      }
  }
}

fn handle_spawn_completed(
  state: State,
  key: ProcKey,
  result: Result(Proc, GetError),
) -> actor.Next(State, Msg) {
  let waiters = case dict.get(state.inflight, key) {
    Ok(list) -> list
    Error(_) -> []
  }
  let result_tag = case result {
    Ok(_) -> "ok"
    Error(err) -> "err:" <> describe_get_error(err)
  }
  trace_pool_event(
    "SPAWN_COMPLETED",
    key,
    [
      #("result", result_tag),
      #("waiters_to_reply", int.to_string(list.length(waiters))),
      #("inflight_remaining", int.to_string(dict.size(state.inflight) - 1)),
    ],
  )
  let inflight = dict.delete(state.inflight, key)
  // Spawner is about to exit cleanly; remove its monitor entry so
  // the upcoming DOWN doesn't trip the crash-flush branch in
  // handle_proc_down. spawner_monitors keyed by Monitor (reverse
  // map); find the entry whose value is this key.
  let spawner_monitors = remove_spawner_monitor_for_key(state.spawner_monitors, key)

  // Preserve probe-attempt counters that the worker accumulated via
  // SpawnProgress; only the terminal state field changes here.
  let prior = dict.get(state.lsp_state, key)

  case result {
    Ok(spawned) -> {
      let monitor_ref = process.monitor(proc.pid(spawned))
      list.each(waiters, fn(r) { process.send(r, Ok(spawned)) })
      let cache = dict.insert(state.cache, key, spawned)
      let monitors = dict.insert(state.monitors, monitor_ref, key)
      let lsp_state =
        dict.insert(
          state.lsp_state,
          key,
          advance_state(prior, Ready, option.None),
        )
      actor.continue(
        State(
          ..state,
          cache: cache,
          monitors: monitors,
          inflight: inflight,
          lsp_state: lsp_state,
          spawner_monitors: spawner_monitors,
        ),
      )
    }
    Error(err) -> {
      list.each(waiters, fn(r) { process.send(r, Error(err)) })
      let reason = describe_get_error(err)
      let lsp_state =
        dict.insert(
          state.lsp_state,
          key,
          advance_state(prior, Failed(reason), option.Some(reason)),
        )
      actor.continue(
        State(
          ..state,
          inflight: inflight,
          lsp_state: lsp_state,
          spawner_monitors: spawner_monitors,
        ),
      )
    }
  }
}

fn describe_get_error(err: GetError) -> String {
  case err {
    ProcStartFailed(reason) -> "spawn failed: " <> reason
    ProbeFailed(reason) -> "probe failed: " <> reason
    SpawnerCrashed(reason) -> "spawner crashed: " <> reason
  }
}

/// Drop the spawner-monitor entry pointing at `key`. Map is keyed
/// by Monitor ref; spawner-DOWN handler needs ref→key lookup so
/// we keep this direction. SpawnCompleted only knows the key, so
/// linear scan. Map size is bounded by the number of in-flight
/// spawns (typically <30), so O(N) is fine.
fn remove_spawner_monitor_for_key(
  spawner_monitors: Dict(process.Monitor, ProcKey),
  key: ProcKey,
) -> Dict(process.Monitor, ProcKey) {
  let matched =
    spawner_monitors
    |> dict.to_list
    |> list.find(fn(entry) { entry.1 == key })
  case matched {
    Ok(#(monitor_ref, _)) -> dict.delete(spawner_monitors, monitor_ref)
    Error(_) -> spawner_monitors
  }
}

fn advance_state(
  prior: Result(LspStateBookkeeping, Nil),
  new_state: LspState,
  last_error: option.Option(String),
) -> LspStateBookkeeping {
  case prior {
    Ok(bk) ->
      LspStateBookkeeping(
        state: new_state,
        spawned_at_unix_ms: bk.spawned_at_unix_ms,
        probe_attempts: bk.probe_attempts,
        last_probe_error: case last_error {
          option.None -> bk.last_probe_error
          option.Some(_) -> last_error
        },
      )
    Error(_) ->
      LspStateBookkeeping(
        state: new_state,
        spawned_at_unix_ms: system_time_ms(),
        probe_attempts: 0,
        last_probe_error: last_error,
      )
  }
}

/// Kick off a recover-or-spawn worker process. The worker runs
/// off the pool actor so the actor's `handle_get` returns
/// immediately. The worker performs:
///   1. `recover_or_spawn` — init handshake + optional `$/progress`
///      drain (lifecycle.wait_for_ready inside proc's initialiser).
///   2. ADR-024 readiness probe — fires `warmup_probe` and retries
///      with exponential backoff until non-error / non-null result
///      OR `ready_timeout_ms` elapses.
/// On success: posts `SpawnCompleted(key, Ok(proc))`. On
/// probe-budget exhaustion or spawn error: posts
/// `SpawnCompleted(key, Error(...))` and closes the proc.
///
/// Crash safety: pool monitors the spawner process via
/// `process.monitor`. On Erlang-level crash (gleam exception,
/// FFI panic) the pool receives `ProcDown(monitor_ref, reason)`
/// and `handle_proc_down` checks `spawner_monitors` — if matched,
/// fan-replies `Error(SpawnerCrashed)` to every waiter and clears
/// the inflight entry. Normal `SpawnCompleted` reply demonitors.
/// Returns the spawner's Pid so the caller can monitor it.
fn spawn_worker(
  self_subject: Subject(Msg),
  key: ProcKey,
  spec: SpawnSpec,
) -> process.Pid {
  let #(language, workspace, _) = key
  process.spawn_unlinked(fn() {
      case recover_or_spawn(language, workspace, spec) {
        Error(err) ->
          process.send(self_subject, SpawnCompleted(key, Error(err)))
        Ok(spawned) -> {
          // Transition Spawning → Probing so runtime_lsp_state can
          // distinguish "still doing init handshake" from "init done,
          // now warming the index via probe".
          process.send(
            self_subject,
            SpawnProgress(key, Probing, 0, option.None),
          )
          let probe_result =
            run_probe_loop(
              self_subject,
              key,
              spawned,
              workspace,
              spec.warmup_probe,
              spec.ready_timeout_ms,
            )
          case probe_result {
            Ok(_) ->
              process.send(self_subject, SpawnCompleted(key, Ok(spawned)))
            Error(reason) -> {
              // Probe budget exhausted — close the proc so we don't
              // cache a half-warm LSP. Pool's monitor will see the
              // DOWN and (already) clean up; SpawnCompleted with
              // Error short-circuits the inflight waiters first.
              proc.close(spawned)
              process.send(
                self_subject,
                SpawnCompleted(key, Error(ProbeFailed(reason))),
              )
            }
          }
        }
      }
    })
}

/// ADR-017a recover-first, spawn-on-miss. Cheap when the lsp_proc
/// actor for this `(language, workspace, server_id)` already exists
/// in the ETS bridge (e.g., supervisor restarted the pool but the
/// per-lsp processes survived); falls back to a fresh spawn
/// otherwise. Runs in the worker process, NOT the pool actor.
fn recover_or_spawn(
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Proc, GetError) {
  case proc.recover_subject(language, workspace, spec.server_id) {
    Ok(subject) -> Ok(proc.from_subject(subject))
    Error(_) -> spawn_proc(language, workspace, spec)
  }
}

// ADR-024 per-attempt probe budget. The probe's actor.call inherits
// the proc actor's `request_timeout + 5_000` slack so the probe
// errors before the actor.call expires.
//
// 5s was too tight for LSPs whose first workspace/symbol after
// `initialized` blocks on a side-channel: gleam-lsp downloads its
// dependency manifest before answering anything; elp emits the
// workspace-symbol response only after the initial -32801 indexing
// burst settles. Both surfaced as `transport error during probe`
// on every attempt of the M14 Pass 1c–4 dogfood. 30s gives those
// LSPs room without making healthy ones (gopls / rust-analyzer /
// pyright) noticeably slower — they return in <2s and immediately
// satisfy the probe regardless of the cap.
const probe_attempt_timeout_ms: Int = 30_000

/// Run the readiness probe loop. Returns Ok(Nil) on success,
/// Error(reason) when the total elapsed exceeds `total_budget_ms`.
/// Backoff: attempt 1 immediately; subsequent attempts sleep
/// `min(2^attempt, 10)` seconds between tries. Posts `SpawnProgress`
/// after each attempt so runtime_lsp_state observes counter movement.
fn run_probe_loop(
  self_subject: Subject(Msg),
  key: ProcKey,
  spawned: Proc,
  workspace: String,
  probe: WarmupProbe,
  total_budget_ms: Int,
) -> Result(Nil, String) {
  case probe {
    ProbeNone -> Ok(Nil)
    _ -> probe_loop_step(self_subject, key, spawned, workspace, probe, 1, 0, total_budget_ms, option.None)
  }
}

fn probe_loop_step(
  self_subject: Subject(Msg),
  key: ProcKey,
  spawned: Proc,
  workspace: String,
  probe: WarmupProbe,
  attempt: Int,
  elapsed_ms: Int,
  total_budget_ms: Int,
  last_err: option.Option(String),
) -> Result(Nil, String) {
  case elapsed_ms >= total_budget_ms {
    True -> {
      let reason =
        "ready_timeout_ms ("
        <> int.to_string(total_budget_ms)
        <> "ms) elapsed without a non-null probe response"
        <> case last_err {
          option.Some(e) -> "; last error: " <> e
          option.None -> ""
        }
      Error(reason)
    }
    False -> {
      let attempt_started_ms = system_time_ms()
      let probe_outcome = run_one_probe(spawned, workspace, probe)
      let attempt_duration =
        int_max(0, system_time_ms() - attempt_started_ms)
      let next_err = case probe_outcome {
        Ok(_) -> option.None
        Error(e) -> option.Some(e)
      }
      process.send(
        self_subject,
        SpawnProgress(key, Probing, attempt, next_err),
      )
      case probe_outcome {
        Ok(_) -> Ok(Nil)
        Error(reason_str) if reason_str == lsp_proc_dead_reason ->
          // Fast-fail: retry pointless. Pool never respawns a dead
          // lsp_proc inside a single Get; only the next Get triggers
          // a fresh spawn worker. Burning the full ready_timeout
          // budget here (4 min @ 240s) just blocks the cascade for
          // broken-LSP langs (scala/gleam/erlang on Pass 1b) without
          // any chance of recovery.
          Error(reason_str)
        Error(_) -> {
          let backoff_ms = probe_backoff_ms(attempt)
          let after_sleep_elapsed =
            elapsed_ms + attempt_duration + backoff_ms
          case after_sleep_elapsed >= total_budget_ms {
            True -> {
              let reason =
                "ready_timeout_ms ("
                <> int.to_string(total_budget_ms)
                <> "ms) would be exceeded by next backoff sleep"
                <> case next_err {
                  option.Some(e) -> "; last error: " <> e
                  option.None -> ""
                }
              Error(reason)
            }
            False -> {
              process.sleep(backoff_ms)
              probe_loop_step(
                self_subject,
                key,
                spawned,
                workspace,
                probe,
                attempt + 1,
                after_sleep_elapsed,
                total_budget_ms,
                next_err,
              )
            }
          }
        }
      }
    }
  }
}

fn probe_backoff_ms(attempt: Int) -> Int {
  // Exponential backoff capped at 10s.
  case attempt {
    1 -> 1_000
    2 -> 2_000
    3 -> 4_000
    4 -> 8_000
    _ -> 10_000
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// Fire one probe attempt. Returns Ok when the LSP responded with
/// a non-error / non-null result; Error otherwise.
fn run_one_probe(
  spawned: Proc,
  workspace: String,
  probe: WarmupProbe,
) -> Result(Nil, String) {
  case probe {
    ProbeNone -> Ok(Nil)
    ProbeWorkspaceSymbol(query) -> {
      let params = json.object([#("query", json.string(query))])
      probe_call(spawned, "workspace/symbol", params)
    }
    ProbeDocumentSymbol(rel) -> {
      let uri = workspace_root.path_to_uri(workspace <> "/" <> rel)
      let params =
        json.object([
          #("textDocument", json.object([#("uri", json.string(uri))])),
        ])
      probe_call(spawned, "textDocument/documentSymbol", params)
    }
  }
}

/// Sentinel reason string matched by `probe_loop_step` to short-
/// circuit retries. Stored in a constant so both producer and
/// matcher agree byte-for-byte. ADR-024 follow-up M14 Pass 1b.
const lsp_proc_dead_reason: String = "lsp_proc died before probe (initialize likely failed)"

fn probe_call(
  spawned: Proc,
  method: String,
  params: json.Json,
) -> Result(Nil, String) {
  // Guard against a dead lsp_proc: the supervisor's start_child can
  // return Ok while the lsp_proc actor immediately dies during its
  // initialize handshake (LSP binary crashed, init request returned
  // bogus payload, etc.). Without this check, the subsequent
  // proc.request → actor.call panics on `callee exited Noproc` and
  // kills the spawner — the dominant spawner-crash mode for
  // scala/gleam/erlang in M14 Pass 1. The small race between this
  // check and the actor.call below is acceptable: most failures hit
  // before any probe attempt, so an O(1) is_alive read removes the
  // entire cascade. (A full try/catch wrapper is a follow-up.)
  case process.is_alive(proc.pid(spawned)) {
    False -> Error(lsp_proc_dead_reason)
    True ->
      // Wrap the inner call in a try/catch FFI to close the
      // residual race: is_alive can return True, lsp_proc can die
      // before actor.call's monitor wire-up, then perform_call's
      // dead-Subject panic crashes the spawner. M14 Pass 1c showed
      // 1 such race vs. 45 caught by the is_alive pre-check; the
      // wrap takes that residual to zero.
      case safe_call_0(fn() { probe_call_inner(spawned, method, params) }) {
        Ok(inner_result) -> inner_result
        Error(reason) -> Error("probe call panicked: " <> reason)
      }
  }
}

@external(erlang, "pharos_runtime_ffi", "safe_call_0")
fn safe_call_0(closure: fn() -> a) -> Result(a, String)

fn probe_call_inner(
  spawned: Proc,
  method: String,
  params: json.Json,
) -> Result(Nil, String) {
  case proc.request(spawned, method, params, probe_attempt_timeout_ms) {
    // Transport down or decode failure → LSP itself isn't responding
    // to us. Real failure; retry.
    Error(lifecycle.ClientFailure(_)) ->
      Error("transport error during probe")
    Error(lifecycle.ResponseDecodeError(reason)) ->
      Error("decode error during probe: " <> reason)
    // proc.request now catches actor.call panics from a dead lsp_proc
    // Subject. Equivalent to "client transport failure" for probe's
    // purposes — the LSP isn't reachable via this Subject.
    Error(lifecycle.ActorCallPanic(reason)) ->
      Error("actor.call panic during probe: " <> reason)
    // Any ServerError means the LSP answered — it processed our
    // message and returned a structured error. The readiness probe
    // is measuring "LSP alive and processing messages," not
    // "workspace fully indexed." `-32801 content modified` from
    // rust-analyzer or elp during the initial indexing burst still
    // means the LSP is responsive — real tool calls land in the
    // queue and complete once indexing finishes (or get retried by
    // the tool layer's `request_with_content_modified_retry`).
    // Retrying the probe instead burns the entire ready_timeout
    // budget on broken-by-design LSPs (elp on kafka-sized rebar
    // fixtures, M14 Pass 1c–4 dogfood: 12 attempts × 25s = full
    // 300s exhausted, 1/22 cells for erlang).
    Error(lifecycle.ServerError(_code, _message)) -> Ok(Nil)
    // Successful response — Ok regardless of body shape (null,
    // empty array, populated). LSP is ready.
    Ok(_value) -> Ok(Nil)
  }
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: ErlangTimeUnit) -> Int

type ErlangTimeUnit {
  Millisecond
}

fn system_time_ms() -> Int {
  system_time(Millisecond)
}

fn handle_evict(
  state: State,
  language: String,
  workspace: String,
  server_id: String,
) -> actor.Next(State, Msg) {
  let key = #(language, workspace, server_id)
  case dict.get(state.cache, key) {
    Ok(spawned) -> {
      proc.close(spawned)
      proc.forget_subject(language, workspace, server_id)
      let cache = dict.delete(state.cache, key)
      let lsp_state = dict.delete(state.lsp_state, key)
      let opened =
        set.filter(state.opened, fn(quad) {
          let #(l, w, s, _) = quad
          !{ l == language && w == workspace && s == server_id }
        })
      actor.continue(
        State(..state, cache: cache, opened: opened, lsp_state: lsp_state),
      )
    }
    Error(_) -> actor.continue(state)
  }
}

fn handle_evict_all(
  state: State,
  language: String,
  workspace: String,
) -> actor.Next(State, Msg) {
  let matching =
    state.cache
    |> dict.to_list
    |> list.filter(fn(entry) {
      let #(#(l, w, _), _) = entry
      l == language && w == workspace
    })
  let cache =
    list.fold(matching, state.cache, fn(c, entry) {
      let #(key, spawned) = entry
      let #(l, w, s) = key
      proc.close(spawned)
      proc.forget_subject(l, w, s)
      dict.delete(c, key)
    })
  let lsp_state =
    list.fold(matching, state.lsp_state, fn(s, entry) {
      dict.delete(s, entry.0)
    })
  let opened =
    set.filter(state.opened, fn(quad) {
      let #(l, w, _, _) = quad
      !{ l == language && w == workspace }
    })
  actor.continue(
    State(..state, cache: cache, opened: opened, lsp_state: lsp_state),
  )
}

fn handle_close_all(state: State) -> actor.Next(State, Msg) {
  state.cache
  |> dict.values
  |> close_each
  actor.continue(
    State(
      ..state,
      cache: dict.new(),
      monitors: dict.new(),
      opened: set.new(),
      inflight: dict.new(),
      lsp_state: dict.new(),
    ),
  )
}

fn handle_proc_down(
  state: State,
  monitor_ref: process.Monitor,
  reason: dynamic.Dynamic,
) -> actor.Next(State, Msg) {
  // Two monitor sources tracked: `monitors` (LSP child procs) and
  // `spawner_monitors` (in-flight spawn workers). Check both.
  case dict.get(state.monitors, monitor_ref) {
    Ok(key) -> {
      trace_pool_event(
        "DOWN",
        key,
        [#("source", "lsp_child"), #("reason", describe_dynamic(reason))],
      )
      handle_lsp_child_down(state, monitor_ref, key)
    }
    Error(_) ->
      case dict.get(state.spawner_monitors, monitor_ref) {
        Ok(key) -> {
          trace_pool_event(
            "DOWN",
            key,
            [#("source", "spawner"), #("reason", describe_dynamic(reason))],
          )
          handle_spawner_down(state, monitor_ref, key, reason)
        }
        Error(_) -> {
          trace_pool_event(
            "DOWN",
            #("?", "?", "?"),
            [
              #("source", "unknown_monitor"),
              #("reason", describe_dynamic(reason)),
            ],
          )
          actor.continue(state)
        }
      }
  }
}

fn handle_lsp_child_down(
  state: State,
  monitor_ref: process.Monitor,
  key: ProcKey,
) -> actor.Next(State, Msg) {
  let #(language, workspace, server_id) = key
  log.fields_at(
    "pharos/lsp/pool",
    log_entry.Warn,
    "lsp_proc exited; evicting pool cache entry",
    [
      #("language", language),
      #("workspace", workspace),
      #("server", server_id),
    ],
  )
  let cache = dict.delete(state.cache, key)
  let monitors = dict.delete(state.monitors, monitor_ref)
  let lsp_state = dict.delete(state.lsp_state, key)
  let opened =
    set.filter(state.opened, fn(quad) {
      let #(l, w, s, _) = quad
      !{ l == language && w == workspace && s == server_id }
    })
  actor.continue(
    State(
      ..state,
      cache: cache,
      monitors: monitors,
      opened: opened,
      lsp_state: lsp_state,
    ),
  )
}

/// Spawner worker died before sending SpawnCompleted — fan a typed
/// `SpawnerCrashed` error to every waiter so they get a real
/// response instead of hanging. Clears inflight + spawner_monitors
/// + lsp_state for the key. Normal-exit spawners get their
/// `spawner_monitors` entry removed in `handle_spawn_completed`
/// before BEAM delivers DOWN, so this branch only fires on real
/// crashes (gleam exception, FFI panic).
fn handle_spawner_down(
  state: State,
  monitor_ref: process.Monitor,
  key: ProcKey,
  reason: dynamic.Dynamic,
) -> actor.Next(State, Msg) {
  let #(language, workspace, server_id) = key
  let reason_text =
    "spawn worker exited before completing: " <> describe_dynamic(reason)
  log.fields_at(
    "pharos/lsp/pool",
    log_entry.Warn,
    "spawn worker crashed; failing in-flight waiters",
    [
      #("language", language),
      #("workspace", workspace),
      #("server", server_id),
      #("reason", reason_text),
    ],
  )
  let waiters = case dict.get(state.inflight, key) {
    Ok(list) -> list
    Error(_) -> []
  }
  list.each(waiters, fn(r) {
    process.send(r, Error(SpawnerCrashed(reason_text)))
  })
  let inflight = dict.delete(state.inflight, key)
  let spawner_monitors = dict.delete(state.spawner_monitors, monitor_ref)
  let prior = dict.get(state.lsp_state, key)
  let lsp_state =
    dict.insert(
      state.lsp_state,
      key,
      advance_state(prior, Failed(reason_text), option.Some(reason_text)),
    )
  actor.continue(
    State(
      ..state,
      inflight: inflight,
      spawner_monitors: spawner_monitors,
      lsp_state: lsp_state,
    ),
  )
}

@external(erlang, "io_lib", "format")
fn io_lib_format(fmt: String, args: List(dynamic.Dynamic)) -> dynamic.Dynamic

fn describe_dynamic(value: dynamic.Dynamic) -> String {
  // Render any Erlang term as a string via io_lib:format("~p", ...).
  // Returns a charlist (dynamic IoList); converted to binary by the
  // shim. Best-effort — only used for error message text.
  let formatted = io_lib_format("~p", [value])
  iolist_to_string_safe(formatted)
}

@external(erlang, "pharos_runtime_ffi", "iolist_to_binary_safe")
fn iolist_to_string_safe(io: dynamic.Dynamic) -> String

fn handle_ensure_open(
  state: State,
  language: String,
  workspace: String,
  server_id: String,
  uri: String,
  language_id: String,
  content: String,
  reply: Subject(Result(Nil, EnsureOpenError)),
) -> actor.Next(State, Msg) {
  let doc_key = #(language, workspace, server_id, uri)
  case set.contains(state.opened, doc_key) {
    True -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }

    False ->
      case dict.get(state.cache, #(language, workspace, server_id)) {
        Error(_) -> {
          process.send(reply, Error(NoCachedClient))
          actor.continue(state)
        }

        Ok(spawned) -> {
          let body =
            json.object([
              #("jsonrpc", json.string("2.0")),
              #("method", json.string("textDocument/didOpen")),
              #(
                "params",
                json.object([
                  #(
                    "textDocument",
                    json.object([
                      #("uri", json.string(uri)),
                      #("languageId", json.string(language_id)),
                      #("version", json.int(1)),
                      #("text", json.string(content)),
                    ]),
                  ),
                ]),
              ),
            ])
            |> json.to_string
            |> bit_array.from_string

          case proc.send_notification(spawned, body) {
            Ok(Nil) -> {
              process.send(reply, Ok(Nil))
              actor.continue(
                State(..state, opened: set.insert(state.opened, doc_key)),
              )
            }
            Error(_) -> {
              process.send(reply, Error(SendFailed))
              actor.continue(state)
            }
          }
        }
      }
  }
}

fn close_each(procs: List(Proc)) -> Nil {
  case procs {
    [] -> Nil
    [first, ..rest] -> {
      proc.close(first)
      close_each(rest)
    }
  }
}

fn spawn_proc(
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Proc, GetError) {
  // ADR-017a: spawn the lsp_proc actor as a child of
  // `pharos_lsp_dyn_sup`. ETS bridge keys (lang, workspace, server_id).
  use _spawned_pid <- result.try(case
    dyn_sup_start_child(
      language,
      workspace,
      spec.server_id,
      spec.command,
      spec.args,
      spec.init_params,
      spec.initialize_timeout_ms,
      spec.readiness_token,
      spec.ready_timeout_ms,
    )
  {
    Ok(p) -> Ok(p)
    Error(reason) ->
      Error(ProcStartFailed("lsp_dyn_sup.start_child failed: " <> reason))
  })

  use subject <- result.try(case
    proc.recover_subject(language, workspace, spec.server_id)
  {
    Ok(s) -> Ok(s)
    Error(_) ->
      Error(ProcStartFailed(
        "ETS bridge missing entry for spawned lsp_proc; "
        <> "(ADR-017a invariant violation)",
      ))
  })

  let spawned = proc.from_subject(subject)

  case spec.workspace_configuration {
    option.None -> Nil

    option.Some(settings) -> {
      proc.add_handler(
        spawned,
        "workspace/configuration",
        server_request_handlers.workspace_configuration_handler(settings),
      )

      case proc.push_configuration(spawned, settings_to_json(settings)) {
        Ok(Nil) -> Nil
        Error(_err) ->
          log.warn_at(
            "pharos/lsp/pool",
            "workspace/didChangeConfiguration push failed; "
              <> "server may run with degraded settings",
          )
      }
    }
  }

  Ok(spawned)
}

@external(erlang, "pharos_lsp_dyn_sup", "start_child")
fn dyn_sup_start_child(
  language: String,
  workspace: String,
  server_id: String,
  command: String,
  args: List(String),
  init_params: json.Json,
  initialize_timeout_ms: Int,
  readiness_token: option.Option(String),
  ready_timeout_ms: Int,
) -> Result(process.Pid, String)

fn settings_to_json(settings: Dict(String, json.Json)) -> json.Json {
  settings
  |> dict.to_list
  |> json.object
}

/// Emit a structured Debug-level trace tagged "pharos/lsp/pool/trace"
/// so operators can flip just the pool trace channel on via
/// `PHAROS_LOG=info,pharos/lsp/pool/trace=debug` without drowning in
/// the rest of pool's existing Warn logs. Used to diagnose the
/// Option B regression where pool state transitions need to be
/// reconstructable from the log alone.
fn trace_pool_event(
  event: String,
  key: ProcKey,
  fields: List(#(String, String)),
) -> Nil {
  let #(language, workspace, server_id) = key
  let header = [
    #("event", event),
    #("language", language),
    #("workspace", workspace),
    #("server", server_id),
  ]
  // Emit at Info so the default writer routes to stderr without needing
  // a separate PHAROS_LOG override. ADR-024 follow-up: this channel is
  // diagnostic, not high-volume — Pool sees one event per Get / cache
  // hit / spawn transition, bounded by the number of cached LSPs and
  // their lifecycle. Cost is negligible compared to the request flight
  // already in progress.
  log.fields_at(
    "pharos/lsp/pool/trace",
    log_entry.Info,
    "pool_event",
    list.append(header, fields),
  )
  // Belt-and-suspenders: also dump straight to stderr so this signal
  // survives writer-mailbox saturation under load (the very scenario
  // we're trying to diagnose). Diagnostic output, not a log.
  let line =
    "[pool_trace] "
    <> event
    <> " "
    <> language
    <> "/"
    <> server_id
    <> " "
    <> field_pairs_to_line(list.append(header, fields))
  direct_stderr_line(line)
}

fn field_pairs_to_line(fields: List(#(String, String))) -> String {
  list.fold(fields, "", fn(acc, p) {
    let #(k, v) = p
    acc <> k <> "=" <> v <> " "
  })
}

@external(erlang, "pharos_log_ffi", "direct_stderr")
fn direct_stderr_line(line: String) -> Nil

fn describe_lsp_state(s: LspState) -> String {
  case s {
    Spawning -> "Spawning"
    Probing -> "Probing"
    Ready -> "Ready"
    Failed(reason) -> "Failed(" <> reason <> ")"
  }
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list_ffi(pid: process.Pid) -> dynamic.Dynamic

fn describe_pid(pid: process.Pid) -> String {
  iolist_to_string_safe(pid_to_list_ffi(pid))
}
