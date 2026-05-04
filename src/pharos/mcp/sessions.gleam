//// MCP HTTP session table.
////
//// Owns the mapping `Dict(SessionId, SessionState)`. New sessions are
//// issued on the first `initialize` POST to `/mcp` (Stage 0D); every
//// subsequent request must carry the `Mcp-Session-Id` header
//// matching an active session. Sessions evict on idle: any session
//// untouched for `idle_timeout_ms` is removed by the eviction sweep
//// running every `eviction_interval_ms`.
////
//// A session-id-based table is required for Tier 2 over HTTP because
//// server-initiated requests (e.g. `workspace/applyEdit`) need to
//// reach the originating MCP client. The SSE delivery channel
//// (`GET /mcp/events`) attaches by session id; a follow-up commit
//// stores the SSE subject in `SessionState`.
////
//// See ADR-012 decisions 3 and 8.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/result

const idle_timeout_ms: Int = 1_800_000

const eviction_interval_ms: Int = 60_000

const default_call_timeout_ms: Int = 5000

pub type Sessions {
  Sessions(subject: Subject(Msg))
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub type SessionState {
  SessionState(
    last_activity_us: Int,
    /// Reserved for the SSE channel handle added in the follow-up
    /// commit. Holding the field shape now keeps the struct stable
    /// for the actor's message protocol.
    sse_channel: Option(SseChannel),
  )
}

/// Placeholder for the SSE channel handle. Filled in when SSE lands.
pub type SseChannel {
  SseChannel
}

pub opaque type Msg {
  Issue(reply_to: Subject(String))
  Validate(session_id: String, reply_to: Subject(Bool))
  Touch(session_id: String)
  Evict(now_us: Int)
}

type State {
  State(table: Dict(String, SessionState))
}

/// Spawn the session table actor. The eviction sweep is scheduled on
/// the actor itself via `process.send_after`.
pub fn start() -> Result(Sessions, StartError) {
  actor.new(State(table: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) {
    schedule_eviction(started.data)
    Sessions(subject: started.data)
  })
  |> result.map_error(StartFailedActor)
}

/// Issue a new session. Returns the freshly generated session id.
/// Caller (typically the HTTP transport on `initialize`) sends the
/// id back to the client in the `Mcp-Session-Id` response header.
pub fn issue(sessions: Sessions) -> String {
  let Sessions(subject) = sessions
  actor.call(subject, default_call_timeout_ms, fn(reply) { Issue(reply) })
}

/// Validate that `session_id` corresponds to an active session and
/// touch its `last_activity_us`. Returns `True` on hit, `False` on
/// miss or eviction. Used by the HTTP transport on every non-
/// initialize POST.
pub fn validate(sessions: Sessions, session_id: String) -> Bool {
  let Sessions(subject) = sessions
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    Validate(session_id, reply)
  })
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Issue(reply) -> {
      let id = generate_session_id()
      let now = now_us()
      let table =
        dict.insert(state.table, id, SessionState(
          last_activity_us: now,
          sse_channel: None,
        ))
      process.send(reply, id)
      actor.continue(State(table: table))
    }

    Validate(session_id, reply) ->
      case dict.get(state.table, session_id) {
        Error(_) -> {
          process.send(reply, False)
          actor.continue(state)
        }
        Ok(existing) -> {
          let now = now_us()
          let updated = SessionState(..existing, last_activity_us: now)
          let table = dict.insert(state.table, session_id, updated)
          process.send(reply, True)
          actor.continue(State(table: table))
        }
      }

    Touch(session_id) ->
      case dict.get(state.table, session_id) {
        Error(_) -> actor.continue(state)
        Ok(existing) -> {
          let now = now_us()
          let updated = SessionState(..existing, last_activity_us: now)
          let table = dict.insert(state.table, session_id, updated)
          actor.continue(State(table: table))
        }
      }

    Evict(now_us: now) -> {
      let cutoff_us = now - idle_timeout_ms * 1000
      let table =
        dict.filter(state.table, fn(_id, session) {
          session.last_activity_us >= cutoff_us
        })
      actor.continue(State(table: table))
    }
  }
}

fn schedule_eviction(subject: Subject(Msg)) -> Nil {
  process.send_after(subject, eviction_interval_ms, Evict(now_us: now_us()))
  Nil
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

type TimeUnit {
  Microsecond
}

fn now_us() -> Int {
  system_time(Microsecond)
}

@external(erlang, "pharos_session_ffi", "generate_session_id")
fn generate_session_id() -> String
