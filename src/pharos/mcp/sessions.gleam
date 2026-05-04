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
    /// Subject the SSE handler runs against. When set, the session
    /// has an active `GET /mcp/events` stream the routing actor can
    /// push server-initiated requests to. None for sessions that
    /// have not opened (or have closed) their SSE channel.
    sse_subject: Option(Subject(SseMsg)),
  )
}

/// Messages the routing layer sends down an SSE channel. Each one
/// becomes a single SSE event written to the stream by the SSE
/// loop in `pharos/mcp/http`.
pub type SseMsg {
  /// Server-initiated request to forward to the MCP client. Body is
  /// the pre-encoded JSON-RPC request frame; `correlation_id` is
  /// the UUID the client must include in its `POST /mcp/respond`.
  Push(correlation_id: String, body: String)
  /// Idle heartbeat — the SSE loop turns this into a comment-line so
  /// proxies do not idle-close the stream.
  Heartbeat
  /// Cooperative shutdown signal — the routing layer asks the SSE
  /// loop to close cleanly (e.g. on session eviction).
  Close
}

pub opaque type Msg {
  Issue(reply_to: Subject(String))
  Validate(session_id: String, reply_to: Subject(Bool))
  Touch(session_id: String)
  AttachSse(
    session_id: String,
    subject: Subject(SseMsg),
    reply_to: Subject(Bool),
  )
  DetachSse(session_id: String)
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

/// Attach an SSE subject to an existing session. Returns `False` if
/// the session is unknown — callers should reject with 400 in that
/// case. Replaces any prior SSE subject for the session
/// (re-connecting after a drop).
pub fn attach_sse(
  sessions: Sessions,
  session_id: String,
  subject: Subject(SseMsg),
) -> Bool {
  let Sessions(actor_subject) = sessions
  actor.call(actor_subject, default_call_timeout_ms, fn(reply) {
    AttachSse(session_id, subject, reply)
  })
}

/// Detach the SSE subject for a session. Used by the SSE loop on
/// graceful shutdown. No-op if the session is gone or never had an
/// SSE channel.
pub fn detach_sse(sessions: Sessions, session_id: String) -> Nil {
  let Sessions(subject) = sessions
  actor.send(subject, DetachSse(session_id))
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Issue(reply) -> {
      let id = generate_session_id()
      let now = now_us()
      let table =
        dict.insert(state.table, id, SessionState(
          last_activity_us: now,
          sse_subject: None,
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

    AttachSse(session_id, subject, reply) ->
      case dict.get(state.table, session_id) {
        Error(_) -> {
          process.send(reply, False)
          actor.continue(state)
        }
        Ok(existing) -> {
          let updated = SessionState(..existing, sse_subject: option.Some(subject))
          let table = dict.insert(state.table, session_id, updated)
          process.send(reply, True)
          actor.continue(State(table: table))
        }
      }

    DetachSse(session_id) ->
      case dict.get(state.table, session_id) {
        Error(_) -> actor.continue(state)
        Ok(existing) -> {
          let updated = SessionState(..existing, sse_subject: None)
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
