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

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/otp/actor
import gleam/result
import llm_lsp_mcp/lsp/client.{type Client}
import llm_lsp_mcp/lsp/lifecycle

pub opaque type Pool {
  Pool(subject: Subject(Msg))
}

pub type SpawnSpec {
  SpawnSpec(command: String, args: List(String), init_params: json.Json)
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
}

type State {
  State(cache: Dict(#(String, String), Client))
}

const initialize_timeout_ms: Int = 30_000

const default_call_timeout_ms: Int = 60_000

/// Spawn the pool. Returns a handle the rest of the program shares
/// for `get/4`, `evict/3`, and `close_all/1`.
pub fn start() -> Result(Pool, StartError) {
  actor.new(State(cache: dict.new()))
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

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Get(language, workspace, spec, reply) ->
      handle_get(state, language, workspace, spec, reply)

    Evict(language, workspace) ->
      handle_evict(state, language, workspace)

    CloseAll -> handle_close_all(state)
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
          actor.continue(State(cache: cache))
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
      actor.continue(State(cache: cache))
    }
    Error(_) -> actor.continue(state)
  }
}

fn handle_close_all(state: State) -> actor.Next(State, Msg) {
  state.cache
  |> dict.values
  |> close_each
  actor.continue(State(cache: dict.new()))
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

  Ok(lsp)
}
