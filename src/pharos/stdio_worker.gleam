//// Stdio transport worker actor (ADR-017 + M10 async dispatch).
////
//// Wraps the read-line/dispatch/write-response loop in a supervised
//// actor with `transient` restart strategy: stdin EOF returns
//// `actor.stop()` so the supervisor does NOT restart (clean
//// program exit), but a crash inside dispatch returns abnormally
//// and the supervisor brings the worker back.
////
//// **Async dispatch (M10).** Each inbound JSON-RPC line is handed
//// off to an unlinked dispatcher process (`pharos/mcp/request_workers`)
//// instead of being processed inline. The dispatcher calls
//// `mcp/server.handle_line/2`, sends the resulting reply back to
//// stdio_worker via the `Write` message variant, and deregisters
//// itself from the worker table. Stdio_worker reads the next line
//// immediately rather than blocking on LSP work — which is what lets
//// `notifications/cancelled` arrive in time to act on the in-flight
//// request (closes the deferred ADR-016 follow-up).
////
//// Stdout writes funnel through this single actor, so concurrent
//// dispatchers can produce responses in any order without
//// interleaving line-atomicity hazards.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/dynamic/decode
import gleam/otp/actor

import pharos/log
import pharos/lsp/pool.{type Pool}
import pharos/mcp/request_workers.{type WriterMsg, WorkerDone, WriteResponse}
import pharos/mcp/server
import pharos/mcp/stdio

pub type Worker {
  Worker(subject: Subject(Msg))
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Stop
  /// Dispatcher → stdio_worker: write `json` as one stdout line.
  Write(json: String)
  /// Dispatcher → stdio_worker: completed with no response (e.g.
  /// notifications/initialized, notifications/cancelled, or
  /// killed-by-cancel). Logged but not written.
  WorkerComplete(mcp_id: String)
  /// Raw mailbox message captured by the selector — typically a
  /// stdin-port `{Port, {data, {eol, Line}}}` / `{Port, eof}` tuple.
  /// `decode_port_event` projects it into the `PortEvent` shape.
  PortMailbox(payload: Dynamic)
}

type State {
  State(
    pool: Pool,
    self: Subject(Msg),
    /// Subject the dispatcher processes send their replies to. The
    /// stdio_worker actor owns this Subject's mailbox; selector
    /// translates each WriterMsg into the matching Msg variant.
    writer: Subject(WriterMsg),
    /// Number of dispatcher processes spawned but not yet drained.
    /// Goes up on every line dispatched, down on every Write or
    /// WorkerComplete. Used by the drain path on stdin EOF to wait
    /// for outstanding work before shutting down.
    inflight: Int,
    /// True once stdin reached EOF. Stops the read loop; once
    /// `inflight` reaches 0 the actor exits cleanly.
    draining: Bool,
  )
}

/// Supervised entry point. Reads the pool from `pool.global/0`
/// inside the initialiser, captures `self` for self-scheduling,
/// kicks off the first `Read`. EOF / read error terminates with
/// `actor.stop` (transient restart strategy on the parent
/// supervisor turns this into a clean program exit).
pub fn start_supervised() -> Result(
  actor.Started(Subject(Msg)),
  actor.StartError,
) {
  let initialise = fn(self) {
    case pool.global() {
      Error(_) -> Error("pool.global() returned no subject")
      Ok(pool_handle) -> {
        // Port owner is the calling process (the actor's pid).
        // Subsequent Port messages — `{Port, {data, {eol, Line}}}`
        // and `{Port, eof}` — arrive in the actor's mailbox and
        // get caught by `select_other` below as `PortMailbox`.
        open_stdin_port()
        let writer = make_writer(self)
        let state =
          State(
            pool: pool_handle,
            self: self,
            writer: writer,
            inflight: 0,
            draining: False,
          )
        let selector = build_selector(self, writer)
        Ok(
          actor.initialised(state)
          |> actor.selecting(selector)
          |> actor.returning(self),
        )
      }
    }
  }

  actor.new_with_initialiser(5000, initialise)
  |> actor.on_message(handle_message)
  |> actor.start()
}

@external(erlang, "pharos_stdin_ffi", "stdin_port")
fn open_stdin_port() -> Dynamic

/// Build a Subject(WriterMsg) that targets the same actor as `self`.
/// Conversion happens via `select_map` in the selector below — every
/// WriterMsg cast becomes the matching `Write` / `WorkerComplete`
/// variant on the way into `handle_message`.
fn make_writer(self: Subject(Msg)) -> Subject(WriterMsg) {
  // The Subject's underlying mailbox is the actor's pid. We project
  // the WriterMsg shape onto Msg by sending a one-of-Msg under the
  // hood. gleam_erlang has no public `cast_subject`, so we own this
  // via the selector pattern: dispatchers send WriterMsg to a
  // separate Subject; the selector below maps each WriterMsg into a
  // Msg variant before the actor handler sees it.
  case process.subject_owner(self) {
    Ok(_pid) -> {
      // Create a fresh Subject; selector merges its inbox with
      // `self`'s under a `select_map` projection.
      process.new_subject()
    }
    Error(_) -> process.new_subject()
  }
}

fn build_selector(
  self: Subject(Msg),
  writer: Subject(WriterMsg),
) -> process.Selector(Msg) {
  process.new_selector()
  |> process.select(self)
  |> process.select_map(writer, fn(wmsg) {
    case wmsg {
      WriteResponse(json) -> Write(json: json)
      WorkerDone -> WorkerComplete(mcp_id: "")
    }
  })
  // Catch raw Port mailbox tuples (stdin port emits `{Port, {data,
  // {eol, Line}}}` etc.) and project them into the typed Msg.
  |> process.select_other(PortMailbox)
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    PortMailbox(payload) -> handle_port_event(state, payload)
    Write(json) -> {
      stdio.write(json)
      step_inflight(state)
    }
    WorkerComplete(_) -> step_inflight(state)
    Stop -> actor.stop()
  }
}

/// Decode a raw Port mailbox payload from the stdin port into either
/// a complete line (dispatch via `dispatch_line`), a partial line
/// (no eol — discard for now; lines >65535 bytes don't occur in
/// practice for MCP), or EOF (transition to drain).
fn handle_port_event(
  state: State,
  payload: Dynamic,
) -> actor.Next(State, Msg) {
  case decode_port_event(payload) {
    PortLine(line) -> {
      case line {
        "" -> actor.continue(state)
        body -> {
          dispatch_line(state, body)
          actor.continue(State(..state, inflight: state.inflight + 1))
        }
      }
    }
    PortEof -> handle_eof(state)
    PortOther -> actor.continue(state)
  }
}

type PortEvent {
  PortLine(String)
  PortEof
  PortOther
}

@external(erlang, "pharos_stdin_ffi", "decode_port_event")
fn decode_port_event(payload: Dynamic) -> PortEvent

/// One unit of dispatcher cleanup arrived (either a Write reply or a
/// WorkerComplete). Decrement the in-flight counter and, if we are
/// draining and the counter reaches zero, exit the actor so the
/// supervisor's transient strategy treats this as a clean shutdown.
fn step_inflight(state: State) -> actor.Next(State, Msg) {
  let next = State(..state, inflight: state.inflight - 1)
  case next.draining, next.inflight {
    True, 0 -> {
      log.info("stdio_worker drained in-flight workers; exiting")
      pool.close_all(state.pool)
      actor.stop()
    }
    _, _ -> actor.continue(next)
  }
}

/// stdin closed (or unrecoverable read error). If no in-flight
/// dispatchers remain, exit immediately. Otherwise transition to a
/// draining state — the read loop stops, but `Write` and
/// `WorkerComplete` messages continue draining the counter until it
/// reaches zero, at which point `step_inflight/1` exits.
fn handle_eof(state: State) -> actor.Next(State, Msg) {
  case state.inflight {
    0 -> {
      log.info("stdin closed; stdio_worker exiting")
      pool.close_all(state.pool)
      actor.stop()
    }
    n -> {
      log.info(
        "stdin closed; stdio_worker draining "
          <> int_to_text(n)
          <> " in-flight worker(s)",
      )
      actor.continue(State(..state, draining: True))
    }
  }
}

/// Spawn a dispatcher process for one inbound JSON-RPC line and
/// return immediately. The dispatcher registers its pid in the
/// `pharos_request_workers` ETS table keyed by the request's MCP id
/// (or the anonymous sentinel for parse errors / notifications),
/// runs `server.handle_line/2`, sends the reply back via the writer
/// Subject, and deregisters itself.
fn dispatch_line(state: State, body: String) -> Nil {
  let mcp_id = peek_mcp_id(body)
  let pool_handle = state.pool
  let writer = state.writer
  let _pid =
    process.spawn_unlinked(fn() {
      let self_pid = process.self()
      request_workers.insert(mcp_id, self_pid)
      let result = server.handle_line(pool_handle, body)
      case result {
        server.Reply(json) ->
          request_workers.send_reply(writer, WriteResponse(json))
        server.ProtocolError(json) ->
          request_workers.send_reply(writer, WriteResponse(json))
        server.NoReply ->
          request_workers.send_reply(writer, WorkerDone)
      }
      request_workers.delete(mcp_id)
    })
  Nil
}

/// Decode just the `id` field out of an inbound JSON-RPC line. Used
/// to key the request-workers table so a follow-up
/// `notifications/cancelled` can find the dispatcher. Returns the
/// anonymous sentinel for parse errors and for notifications (no
/// `id` field).
fn peek_mcp_id(body: String) -> String {
  let decoder = {
    use id <- decode.optional_field("id", PeekNone, peek_id_decoder())
    decode.success(id)
  }
  case json.parse(body, decoder) {
    Ok(PeekInt(n)) -> int_to_text(n)
    Ok(PeekString(s)) -> s
    _ -> request_workers.anonymous_id
  }
}

type PeekedId {
  PeekInt(Int)
  PeekString(String)
  PeekNone
}

fn peek_id_decoder() -> decode.Decoder(PeekedId) {
  let int_dec = decode.int |> decode.map(PeekInt)
  let str_dec = decode.string |> decode.map(PeekString)
  decode.one_of(int_dec, [str_dec])
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_text(n: Int) -> String
