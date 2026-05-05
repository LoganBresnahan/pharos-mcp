//// Kept-warm LSP pool.
////
//// One actor owns a cache of `(language, workspace) -> Proc`. Tools
//// call `get/4` to fetch a Proc; on cache miss the pool spawns
//// a fresh `lsp_proc` (which itself runs the initialize handshake)
//// and stashes it. On cache hit the pool returns the existing
//// Proc immediately — cold-start cost is paid once per (language,
//// workspace) per session, not per tool call.
////
//// M9 Phase B: pool monitors each `Proc` via `process.monitor`. On
//// the proc's exit (DOWN), pool evicts the cache entry so the
//// next tool call respawns transparently. ADR-013 calls this
//// "structure-by-supervision, communication-by-monitoring."
////
//// At Milestone 4 the pool was in-process and lived for the
//// duration of `mix start`. Phase A's supervisor scaffolding does
//// not yet wrap the pool; Phase C adds tool-level retry that
//// transparently respawns on transport error in addition to the
//// auto-evict here.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import pharos/log
import pharos/lsp/proc.{type Proc}
import pharos/lsp/server_request_handlers

pub opaque type Pool {
  Pool(subject: Subject(Msg))
}

pub type SpawnSpec {
  SpawnSpec(
    command: String,
    args: List(String),
    init_params: json.Json,
    /// Optional `workspace/didChangeConfiguration` payload pushed
    /// post-`initialized`. Also used to answer the server's pull-style
    /// `workspace/configuration` requests via a per-language handler
    /// override on the Proc. Keyed by section name (e.g.
    /// `"typescript"`, `"javascript"`); each section's value is the
    /// JSON the server wants for that scope. `None` means the server
    /// gets neither push nor per-language pull-handler. See ADR-012.
    workspace_configuration: option.Option(dict.Dict(String, json.Json)),
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
  Evict(language: String, workspace: String)
  CloseAll
  EnsureOpen(
    language: String,
    workspace: String,
    uri: String,
    language_id: String,
    content: String,
    reply_to: Subject(Result(Nil, EnsureOpenError)),
  )
  /// Sent to the pool actor when one of its monitored procs exits.
  /// `reason` is included for diagnostic logging; pool just evicts
  /// the cache entry regardless of why.
  ProcDown(monitor_ref: process.Monitor, reason: dynamic.Dynamic)
}

pub type EnsureOpenError {
  /// No LSP cached for this (language, workspace) — caller must
  /// `get/4` first to spawn one.
  NoCachedClient
  /// `proc.send_notification` returned an error — the LSP
  /// subprocess is gone or its Port is closed.
  SendFailed
}

type State {
  State(
    cache: Dict(#(String, String), Proc),
    /// Reverse index from monitor ref to cache key, so when a
    /// `ProcDown` arrives we can find which entry to evict.
    monitors: Dict(process.Monitor, #(String, String)),
    opened: Set(#(String, String, String)),
  )
}

const initialize_timeout_ms: Int = 30_000

const default_call_timeout_ms: Int = 60_000

/// Spawn the pool. Returns a handle the rest of the program shares
/// for `get/4`, `evict/3`, and `close_all/1`.
pub fn start() -> Result(Pool, StartError) {
  actor.new(State(cache: dict.new(), monitors: dict.new(), opened: set.new()))
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) { Pool(subject: started.data) })
  |> result.map_error(StartFailedActor)
}

/// Fetch a `Proc` for the given language and workspace, spawning a
/// fresh LSP if none is cached.
pub fn get(
  pool: Pool,
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Proc, GetError) {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    Get(language, workspace, spec, reply)
  })
}

/// Drop the cached entry for one (language, workspace). Tool layer
/// can call this on transport error before retrying. The Proc is
/// closed (which kills its Port and the LSP child).
pub fn evict(pool: Pool, language: String, workspace: String) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, Evict(language, workspace))
}

/// Close every cached LSP. Called on graceful shutdown.
pub fn close_all(pool: Pool) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, CloseAll)
}

/// Ensure the cached LSP for (language, workspace) has been told
/// about this document via `textDocument/didOpen`. Idempotent — if
/// the (language, workspace, uri) tuple has already been opened on
/// this LSP in this session, this is a no-op. Otherwise the pool
/// builds and sends a didOpen notification through the cached
/// Proc and records the URI as opened.
pub fn ensure_open(
  pool: Pool,
  language: String,
  workspace: String,
  uri: String,
  language_id: String,
  content: String,
) -> Result(Nil, EnsureOpenError) {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    EnsureOpen(language, workspace, uri, language_id, content, reply)
  })
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Get(language, workspace, spec, reply) ->
      handle_get(state, language, workspace, spec, reply)

    Evict(language, workspace) ->
      handle_evict(state, language, workspace)

    CloseAll -> handle_close_all(state)

    EnsureOpen(language, workspace, uri, language_id, content, reply) ->
      handle_ensure_open(
        state,
        language,
        workspace,
        uri,
        language_id,
        content,
        reply,
      )

    ProcDown(monitor_ref:, reason: _reason) ->
      handle_proc_down(state, monitor_ref)
  }
}

fn handle_get(
  state: State,
  language: String,
  workspace: String,
  spec: SpawnSpec,
  reply: Subject(Result(Proc, GetError)),
) -> actor.Next(State, Msg) {
  let key = #(language, workspace)

  case dict.get(state.cache, key) {
    Ok(existing) -> {
      process.send(reply, Ok(existing))
      actor.continue(state)
    }

    Error(_) ->
      case spawn_proc(spec, workspace) {
        Ok(spawned) -> {
          // Auto-evict on proc exit per ADR-013. Pool monitors the
          // proc actor's pid; on DOWN, lookup ref→key and remove.
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

fn handle_evict(
  state: State,
  language: String,
  workspace: String,
) -> actor.Next(State, Msg) {
  let key = #(language, workspace)
  case dict.get(state.cache, key) {
    Ok(spawned) -> {
      proc.close(spawned)
      let cache = dict.delete(state.cache, key)
      // Drop opened-doc entries for this (language, workspace) — when
      // a fresh LSP spawns later it will not know about previously
      // opened documents.
      let opened =
        set.filter(state.opened, fn(triple) {
          let #(l, w, _) = triple
          !{ l == language && w == workspace }
        })
      // Monitor cleanup happens implicitly when ProcDown fires after
      // proc.close terminates the actor; no explicit demonitor here.
      actor.continue(State(cache: cache, monitors: state.monitors, opened: opened))
    }
    Error(_) -> actor.continue(state)
  }
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
      let #(language, workspace) = key
      log.warn(
        "lsp_proc for "
        <> language
        <> " / "
        <> workspace
        <> " exited; evicting pool cache entry",
      )
      let cache = dict.delete(state.cache, key)
      let monitors = dict.delete(state.monitors, monitor_ref)
      let opened =
        set.filter(state.opened, fn(triple) {
          let #(l, w, _) = triple
          !{ l == language && w == workspace }
        })
      actor.continue(State(cache: cache, monitors: monitors, opened: opened))
    }
  }
}

fn handle_ensure_open(
  state: State,
  language: String,
  workspace: String,
  uri: String,
  language_id: String,
  content: String,
  reply: Subject(Result(Nil, EnsureOpenError)),
) -> actor.Next(State, Msg) {
  let doc_key = #(language, workspace, uri)
  case set.contains(state.opened, doc_key) {
    True -> {
      // Already opened on this LSP this session. didOpen-once.
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }

    False ->
      case dict.get(state.cache, #(language, workspace)) {
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
  spec: SpawnSpec,
  workspace: String,
) -> Result(Proc, GetError) {
  use spawned <- result.try(
    proc.start(
      spec.command,
      spec.args,
      workspace,
      spec.init_params,
      initialize_timeout_ms,
    )
    |> result.map_error(describe_proc_start_error),
  )

  // Per-language workspace_configuration (Stage 0C). Install a
  // workspace/configuration handler on the proc and push
  // workspace/didChangeConfiguration. Push failure is logged and
  // swallowed per ADR-012 decision 4.
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
          log.warn(
            "workspace/didChangeConfiguration push failed; "
            <> "server may run with degraded settings",
          )
      }
    }
  }

  Ok(spawned)
}

fn describe_proc_start_error(err: proc.StartError) -> GetError {
  case err {
    proc.ClientStartFailed(_) ->
      ProcStartFailed("LSP subprocess could not be spawned")
    proc.HandshakeFailed(_) ->
      ProcStartFailed("LSP initialize handshake failed")
    proc.ActorStartFailed(_) ->
      ProcStartFailed("lsp_proc actor failed to start")
  }
}

fn settings_to_json(settings: Dict(String, json.Json)) -> json.Json {
  settings
  |> dict.to_list
  |> json.object
}
