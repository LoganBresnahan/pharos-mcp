//// Kept-warm LSP pool.
////
//// One actor owns a cache of `(language, workspace) -> Client`.
//// Tools call `get/4` to fetch a Client; on cache miss the pool
//// spawns the LSP and runs the initialize handshake before
//// returning. On cache hit the pool returns the existing Client
//// immediately — cold-start cost is paid once per (language,
//// workspace) per session, not per tool call.
////
//// At Milestone 4 the pool is in-process and lives for the duration
//// of `mix start`. Idle eviction and crash detection arrive in M5+.
//// The MCP host's session typically aligns with the pool's lifetime,
//// so simple "keep until process exits" is enough for v0.1.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import pharos/log
import pharos/lsp/client.{type Client}
import pharos/lsp/lifecycle
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
    /// override on the Client. Keyed by section name (e.g.
    /// `"typescript"`, `"javascript"`); each section's value is the
    /// JSON the server wants for that scope. `None` means the server
    /// gets neither push nor per-language pull-handler. See ADR-012.
    workspace_configuration: option.Option(dict.Dict(String, json.Json)),
  )
}

pub type GetError {
  StartFailed(client.Error)
  HandshakeFailed(lifecycle.InitializeError)
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Get(
    language: String,
    workspace: String,
    spec: SpawnSpec,
    reply_to: Subject(Result(Client, GetError)),
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
}

pub type EnsureOpenError {
  /// No LSP cached for this (language, workspace) — caller must
  /// `get/4` first to spawn one.
  NoCachedClient
  /// `port.send` returned an error — the LSP subprocess is gone.
  SendFailed
}

type State {
  State(
    cache: Dict(#(String, String), Client),
    opened: Set(#(String, String, String)),
  )
}

const initialize_timeout_ms: Int = 30_000

const default_call_timeout_ms: Int = 60_000

/// Spawn the pool. Returns a handle the rest of the program shares
/// for `get/4`, `evict/3`, and `close_all/1`.
pub fn start() -> Result(Pool, StartError) {
  actor.new(State(cache: dict.new(), opened: set.new()))
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) { Pool(subject: started.data) })
  |> result.map_error(StartFailedActor)
}

/// Fetch a Client for the given language and workspace, spawning a
/// fresh LSP if none is cached.
pub fn get(
  pool: Pool,
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Client, GetError) {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    Get(language, workspace, spec, reply)
  })
}

/// Drop the cached entry for one (language, workspace). Use when an
/// LSP appears to have crashed (next get respawns it transparently).
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
/// Client and records the URI as opened.
///
/// Used by tier-1 tools' session prelude to avoid sending didOpen
/// on every tool call — repeat opens trigger rust-analyzer's
/// "content modified" cancellation against in-flight requests.
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
  }
}

fn handle_get(
  state: State,
  language: String,
  workspace: String,
  spec: SpawnSpec,
  reply: Subject(Result(Client, GetError)),
) -> actor.Next(State, Msg) {
  let key = #(language, workspace)
  let caller_pid = case process.subject_owner(reply) {
    Ok(pid) -> pid
    Error(_) -> process.self()
  }

  case dict.get(state.cache, key) {
    Ok(existing) -> {
      // Cache hit: re-transfer ownership to this caller in case the
      // previous caller's process exited. Idempotent — no-op if the
      // current owner is already this caller.
      let _ = client.connect(existing, caller_pid)
      process.send(reply, Ok(existing))
      actor.continue(state)
    }

    Error(_) ->
      case spawn_and_initialize(spec, workspace) {
        Ok(client_handle) -> {
          // Transfer Port ownership to the calling process. Until
          // this point the pool actor owns the Port and was
          // receiving its messages (necessary for the initialize
          // handshake to read the response). Now the tool will be
          // doing the reading.
          let _ = client.connect(client_handle, caller_pid)
          process.send(reply, Ok(client_handle))
          let cache = dict.insert(state.cache, key, client_handle)
          actor.continue(State(cache: cache, opened: state.opened))
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
    Ok(client_handle) -> {
      client.close(client_handle)
      let cache = dict.delete(state.cache, key)
      // Drop opened-doc entries for this (language, workspace) — when
      // a fresh LSP spawns later it will not know about previously
      // opened documents.
      let opened =
        set.filter(state.opened, fn(triple) {
          let #(l, w, _) = triple
          !{ l == language && w == workspace }
        })
      actor.continue(State(cache: cache, opened: opened))
    }
    Error(_) -> actor.continue(state)
  }
}

fn handle_close_all(state: State) -> actor.Next(State, Msg) {
  state.cache
  |> dict.values
  |> close_each
  actor.continue(State(cache: dict.new(), opened: set.new()))
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

        Ok(client_handle) -> {
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

          case client.send_body(client_handle, body) {
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

fn close_each(clients: List(Client)) -> Nil {
  case clients {
    [] -> Nil
    [first, ..rest] -> {
      client.close(first)
      close_each(rest)
    }
  }
}

fn spawn_and_initialize(
  spec: SpawnSpec,
  workspace: String,
) -> Result(Client, GetError) {
  use lsp <- result.try(
    client.start(spec.command, spec.args, workspace)
    |> result.map_error(StartFailed),
  )

  use #(lsp, _capabilities) <- result.try(
    lifecycle.initialize(lsp, 0, spec.init_params, initialize_timeout_ms)
    |> result.map_error(HandshakeFailed),
  )

  // Stage 0C: if the language declared workspace settings, install a
  // per-language workspace/configuration handler (overrides the
  // default null-array reply with real per-section values) and push
  // them via `workspace/didChangeConfiguration`. Push failure is
  // logged and swallowed per ADR-012 decision 4: most servers degrade
  // gracefully without the config; full refusal would be too strict.
  let lsp = case spec.workspace_configuration {
    option.None -> lsp

    option.Some(settings) -> {
      let registry =
        server_request_handlers.defaults()
        |> server_request_handlers.insert(
          "workspace/configuration",
          server_request_handlers.workspace_configuration_handler(settings),
        )

      let lsp = client.with_handlers(lsp, registry)

      case lifecycle.push_configuration(lsp, settings_to_json(settings)) {
        Ok(Nil) -> lsp
        Error(_err) -> {
          log.warn(
            "workspace/didChangeConfiguration push failed; "
            <> "server may run with degraded settings",
          )
          lsp
        }
      }
    }
  }

  Ok(lsp)
}

fn settings_to_json(settings: Dict(String, json.Json)) -> json.Json {
  settings
  |> dict.to_list
  |> json.object
}
