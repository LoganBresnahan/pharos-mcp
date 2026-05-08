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

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import pharos/log
import pharos/lsp/proc.{type Proc}
import pharos/lsp/server_request_handlers

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
    /// Wall-clock cap for the readiness drain.
    readiness_timeout_ms: Int,
    /// Wall-clock cap for the `initialize` handshake. Per-server so
    /// jdtls (heavy) gets headroom while faster servers can fail
    /// fast. Mirrored from `ServerConfig.initialize_timeout_ms` with
    /// the global default applied when None.
    initialize_timeout_ms: Int,
  )
}

pub type GetError {
  ProcStartFailed(reason: String)
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
  // Caller-side timeout MUST exceed the server's initialize budget +
  // buffer for any post-handshake work pool does (workspace_config
  // push, ETS bridge writes). 30s headroom on top of initialize.
  // Without this the pool actor processes the spawn correctly but the
  // caller's actor.call expires first, the worker crashes silently
  // (spawn_unlinked), and drive() never sees a response. Same bug
  // class as the post-didOpen drain race fixed in B1.
  let call_timeout = spec.initialize_timeout_ms + 30_000
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

    ProcDown(monitor_ref:, reason: _reason) ->
      handle_proc_down(state, monitor_ref)

    KillLsp(language, workspace, server_id, reply_to) ->
      handle_kill_lsp(state, language, workspace, server_id, reply_to)
  }
}

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
          log.warn_at(
            "pharos/lsp/pool",
            "operator-requested kill of lsp_proc for "
              <> l
              <> " / "
              <> w
              <> " / "
              <> s,
          )
          acc + 1
        })
      let killed_keys = list.map(matching, fn(entry) { entry.0 })
      let cache =
        list.fold(killed_keys, state.cache, fn(c, k) { dict.delete(c, k) })
      let opened =
        set.filter(state.opened, fn(quad) {
          let #(l, w, s, _) = quad
          !list.any(killed_keys, fn(k) {
            let #(kl, kw, ks) = k
            l == kl && w == kw && s == ks
          })
        })
      process.send(reply, Killed(count))
      actor.continue(State(
        cache: cache,
        monitors: state.monitors,
        opened: opened,
      ))
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
    Ok(existing) -> {
      process.send(reply, Ok(existing))
      actor.continue(state)
    }

    Error(_) ->
      // ADR-017a: cache-miss path. Try the ETS bridge first.
      case proc.recover_subject(language, workspace, spec.server_id) {
        Ok(subject) -> {
          let recovered = proc.from_subject(subject)
          let monitor_ref = process.monitor(proc.pid(recovered))
          process.send(reply, Ok(recovered))
          let cache = dict.insert(state.cache, key, recovered)
          let monitors = dict.insert(state.monitors, monitor_ref, key)
          actor.continue(
            State(cache: cache, monitors: monitors, opened: state.opened),
          )
        }
        Error(_) ->
          case spawn_proc(language, workspace, spec) {
            Ok(spawned) -> {
              let monitor_ref = process.monitor(proc.pid(spawned))
              process.send(reply, Ok(spawned))
              let cache = dict.insert(state.cache, key, spawned)
              let monitors = dict.insert(state.monitors, monitor_ref, key)
              actor.continue(
                State(cache: cache, monitors: monitors, opened: state.opened),
              )
            }
            Error(err) -> {
              process.send(reply, Error(err))
              actor.continue(state)
            }
          }
      }
  }
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
      let opened =
        set.filter(state.opened, fn(quad) {
          let #(l, w, s, _) = quad
          !{ l == language && w == workspace && s == server_id }
        })
      actor.continue(State(
        cache: cache,
        monitors: state.monitors,
        opened: opened,
      ))
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
  let opened =
    set.filter(state.opened, fn(quad) {
      let #(l, w, _, _) = quad
      !{ l == language && w == workspace }
    })
  actor.continue(State(
    cache: cache,
    monitors: state.monitors,
    opened: opened,
  ))
}

fn handle_close_all(state: State) -> actor.Next(State, Msg) {
  state.cache
  |> dict.values
  |> close_each
  actor.continue(State(
    cache: dict.new(),
    monitors: dict.new(),
    opened: set.new(),
  ))
}

fn handle_proc_down(
  state: State,
  monitor_ref: process.Monitor,
) -> actor.Next(State, Msg) {
  case dict.get(state.monitors, monitor_ref) {
    Error(_) -> actor.continue(state)

    Ok(key) -> {
      let #(language, workspace, server_id) = key
      log.warn_at(
        "pharos/lsp/pool",
        "lsp_proc for "
          <> language
          <> " / "
          <> workspace
          <> " / "
          <> server_id
          <> " exited; evicting pool cache entry",
      )
      let cache = dict.delete(state.cache, key)
      let monitors = dict.delete(state.monitors, monitor_ref)
      let opened =
        set.filter(state.opened, fn(quad) {
          let #(l, w, s, _) = quad
          !{ l == language && w == workspace && s == server_id }
        })
      actor.continue(State(cache: cache, monitors: monitors, opened: opened))
    }
  }
}

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
      spec.readiness_timeout_ms,
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
  readiness_timeout_ms: Int,
) -> Result(process.Pid, String)

fn settings_to_json(settings: Dict(String, json.Json)) -> json.Json {
  settings
  |> dict.to_list
  |> json.object
}
