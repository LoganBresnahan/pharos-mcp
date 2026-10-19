//// One shim connection to the shared daemon (ADR-034).
////
//// The connection's first line is the shim's hello. An `mcp` hello
//// becomes a session: its cwd and env build a `SessionCtx`, the
//// connection binds it, answers with the ack, and from then on runs
//// the same per-line dispatch as the stdio worker, writing replies
//// back to the socket. `status` and `stop` hellos are one-shot
//// operator requests.
////
//// When the shim goes away (its stdin closed, or it died) the
//// session's in-flight requests get `PHAROS_SHUTDOWN_DRAIN_MS` to
//// finish, the rest are cancelled, its timeout overrides are dropped,
//// and the daemon forgets it. A session never stops the daemon.
////
//// The hello env can hold secrets (API keys): it is never logged,
//// echoed or returned. A session is reported by id and cwd.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import pharos/env
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/inflight
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc
import pharos/mcp/dispatch
import pharos/mcp/request_workers.{type WriterMsg, WorkerDone, WriteResponse}
import pharos/session_ctx.{type SessionCtx}
import pharos/tools/session_overrides

pub type Socket

/// What a connection needs from the daemon. Closures rather than the
/// daemon's Subject so this module does not import the daemon.
pub type Hooks {
  Hooks(
    /// This daemon's build id; an `mcp` hello must match it.
    build: String,
    /// Register a session; returns its id.
    register: fn(String, Int, Int) -> String,
    unregister: fn(String) -> Nil,
    /// The `status` op's JSON reply.
    status: fn() -> String,
    stop: fn() -> Nil,
  )
}

pub opaque type Msg {
  /// The acceptor handed the socket over; start reading.
  Begin
  SocketMsg(payload: Dynamic)
  Write(json: String)
  WorkerComplete
  WorkerExited
  DrainTimeout
}

type Phase {
  AwaitHello
  Serving(session: SessionCtx)
}

type State {
  State(
    self: Subject(Msg),
    socket: Socket,
    pool: Pool,
    hooks: Hooks,
    writer: Subject(WriterMsg),
    /// Chunks of the unterminated line read so far (newest first) and
    /// their total size; see `pharos_daemon_ffi:split_lines/2`.
    pending: #(List(BitArray), Int),
    phase: Phase,
    /// Dispatchers spawned and not yet exited.
    inflight: Int,
    /// The shim closed its end; finish once `inflight` drains.
    closed: Bool,
  )
}

/// Largest hello line accepted, 1 MiB.
const max_hello_bytes = 1_048_576

/// Largest MCP line accepted, 256 MiB. Past it the connection is
/// dropped rather than buffered without bound.
const max_line_bytes = 268_435_456

pub fn start(
  socket: Socket,
  pool: Pool,
  hooks: Hooks,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    let writer = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_map(writer, fn(wmsg) {
        case wmsg {
          WriteResponse(json) -> Write(json)
          WorkerDone -> WorkerComplete
        }
      })
      |> process.select_monitors(fn(_down) { WorkerExited })
      |> process.select_other(SocketMsg)
    let state =
      State(
        self: self,
        socket: socket,
        pool: pool,
        hooks: hooks,
        writer: writer,
        pending: #([], 0),
        phase: AwaitHello,
        inflight: 0,
        closed: False,
      )
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(self),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Start reading. Call after handing the socket to the connection's
/// process.
pub fn begin(conn: Subject(Msg)) -> Nil {
  process.send(conn, Begin)
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Begin -> {
      activate(state.socket)
      actor.continue(state)
    }
    SocketMsg(payload) ->
      case decode_socket_event(payload) {
        SocketData(data) -> handle_data(state, data)
        SocketClosed -> handle_closed(state)
        SocketOther -> actor.continue(state)
      }
    Write(json) -> {
      let _ = send_line(state.socket, json)
      actor.continue(state)
    }
    WorkerComplete -> actor.continue(state)
    WorkerExited -> {
      let state = State(..state, inflight: state.inflight - 1)
      case state.closed, state.inflight {
        True, 0 -> finish(state)
        _, _ -> actor.continue(state)
      }
    }
    DrainTimeout -> finish(state)
  }
}

fn handle_data(state: State, data: BitArray) -> actor.Next(State, Msg) {
  let #(lines, pending) = split_lines(state.pending, data)
  let limit = case state.phase {
    AwaitHello -> max_hello_bytes
    Serving(_) -> max_line_bytes
  }
  case pending.1 > limit {
    True -> {
      log.fields_at(
        "pharos/daemon",
        log_entry.Warn,
        "connection sent an over-long line; dropping it",
        [#("limit_bytes", int.to_string(limit))],
      )
      finish(state)
    }
    False -> {
      let state = State(..state, pending: pending)
      case handle_lines(state, lines) {
        Ok(state) -> {
          activate(state.socket)
          actor.continue(state)
        }
        Error(state) -> finish(state)
      }
    }
  }
}

/// `Error` means the connection is done (a refused hello or a
/// one-shot op).
fn handle_lines(state: State, lines: List(String)) -> Result(State, State) {
  case lines {
    [] -> Ok(state)
    [line, ..rest] ->
      case state.phase {
        AwaitHello ->
          case handle_hello(state, line) {
            Ok(state) -> handle_lines(state, rest)
            Error(state) -> Error(state)
          }
        Serving(session) ->
          case line {
            "" -> handle_lines(state, rest)
            body -> {
              let pid = dispatch.spawn(state.pool, session, state.writer, body)
              let _monitor = process.monitor(pid)
              handle_lines(State(..state, inflight: state.inflight + 1), rest)
            }
          }
      }
  }
}

type Hello {
  Hello(
    op: String,
    build: String,
    cwd: String,
    env: Dict(String, String),
    client_pid: Int,
    shim_pid: Int,
  )
}

fn hello_decoder() -> decode.Decoder(Hello) {
  use version <- decode.field("pharos_hello", decode.int)
  use op <- decode.optional_field("op", "mcp", decode.string)
  use build <- decode.optional_field("build", "", decode.string)
  use cwd <- decode.optional_field("cwd", "", decode.string)
  use env <- decode.optional_field(
    "env",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use client_pid <- decode.optional_field("client_pid", 0, decode.int)
  use shim_pid <- decode.optional_field("shim_pid", 0, decode.int)
  case version {
    1 -> decode.success(Hello(op:, build:, cwd:, env:, client_pid:, shim_pid:))
    _ ->
      decode.failure(
        Hello(op:, build:, cwd:, env:, client_pid:, shim_pid:),
        "pharos_hello version 1",
      )
  }
}

fn handle_hello(state: State, line: String) -> Result(State, State) {
  case json.parse(line, hello_decoder()) {
    Error(_) -> refuse(state, "malformed hello")
    Ok(hello) ->
      case hello.op {
        "status" -> {
          let _ = send_line(state.socket, state.hooks.status())
          Error(state)
        }
        "stop" -> {
          let _ =
            send_line(
              state.socket,
              json.to_string(json.object([#("pharos_stop", json.int(1))])),
            )
          state.hooks.stop()
          Error(state)
        }
        "mcp" -> start_session(state, hello)
        // Test-only (PHAROS_DAEMON_TEST_OPS=1): kill the daemon actor,
        // to prove live sessions survive its restart.
        "test_crash_daemon" ->
          case test_ops_enabled() {
            True -> {
              kill_daemon_actor()
              let _ =
                send_line(
                  state.socket,
                  json.to_string(json.object([#("pharos_test", json.int(1))])),
                )
              Error(state)
            }
            False -> refuse(state, "unknown op: test_crash_daemon")
          }
        other -> refuse(state, "unknown op: " <> other)
      }
  }
}

fn start_session(state: State, hello: Hello) -> Result(State, State) {
  case hello.build == state.hooks.build, string.starts_with(hello.cwd, "/") {
    False, _ ->
      refuse(
        state,
        "build mismatch: daemon is "
          <> state.hooks.build
          <> ", shim is "
          <> hello.build,
      )
    _, False -> refuse(state, "cwd must be an absolute path")
    True, True -> {
      let id = state.hooks.register(hello.cwd, hello.client_pid, hello.shim_pid)
      let session = session_ctx.new(id, hello.cwd, hello.env)
      // Bind here too, not only in dispatchers: anything this process
      // resolves for the session must see the session's values, never
      // the daemon's own.
      session_ctx.bind(session)
      log.fields_at("pharos/daemon", log_entry.Info, "session connected", [
        #("cwd", hello.cwd),
        #("client_pid", int.to_string(hello.client_pid)),
        #("shim_pid", int.to_string(hello.shim_pid)),
      ])
      let ack =
        json.object([
          #("pharos_hello_ok", json.int(1)),
          #("session", json.string(id)),
          #("daemon_pid", json.int(os_pid())),
        ])
      let _ = send_line(state.socket, json.to_string(ack))
      Ok(State(..state, phase: Serving(session)))
    }
  }
}

fn refuse(state: State, reason: String) -> Result(State, State) {
  log.fields_at("pharos/daemon", log_entry.Warn, "hello refused", [
    #("reason", reason),
  ])
  let _ =
    send_line(
      state.socket,
      json.to_string(
        json.object([#("pharos_hello_error", json.string(reason))]),
      ),
    )
  Error(state)
}

fn handle_closed(state: State) -> actor.Next(State, Msg) {
  case state.inflight {
    0 -> finish(state)
    n -> {
      log.fields_at(
        "pharos/daemon",
        log_entry.Info,
        "session closed; draining in-flight requests",
        [#("count", int.to_string(n))],
      )
      process.send_after(state.self, drain_ms(), DrainTimeout)
      actor.continue(State(..state, closed: True))
    }
  }
}

/// End the connection: cancel what the session left running, forget
/// its overrides, and tell the daemon.
fn finish(state: State) -> actor.Next(State, Msg) {
  case state.phase {
    AwaitHello -> Nil
    Serving(session) -> {
      cancel_leftovers(session.id)
      session_overrides.drop(session.id)
      state.hooks.unregister(session.id)
      log.info_at("pharos/daemon", "session disconnected")
    }
  }
  close(state.socket)
  actor.stop()
}

fn cancel_leftovers(session_id: String) -> Nil {
  inflight.for_session(session_id)
  |> list.each(fn(row) {
    let #(key, subject, lsp_id) = row
    proc.cancel_by_dynamic_subject(subject, lsp_id)
    inflight.delete(key)
  })
  request_workers.for_session(session_id)
  |> list.each(fn(row) {
    let #(key, pid) = row
    process.kill(pid)
    request_workers.delete(key)
  })
}

fn drain_ms() -> Int {
  case env.get("PHAROS_SHUTDOWN_DRAIN_MS") {
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(n) if n >= 0 -> n
        _ -> 2000
      }
    None -> 2000
  }
}

type SocketEvent {
  SocketData(BitArray)
  SocketClosed
  SocketOther
}

@external(erlang, "pharos_daemon_ffi", "decode_socket_event")
fn decode_socket_event(payload: Dynamic) -> SocketEvent

@external(erlang, "pharos_daemon_ffi", "activate")
fn activate(socket: Socket) -> Nil

@external(erlang, "pharos_daemon_ffi", "send_line")
fn send_line(socket: Socket, body: String) -> Result(Nil, Nil)

@external(erlang, "pharos_daemon_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "pharos_daemon_ffi", "split_lines")
fn split_lines(
  pending: #(List(BitArray), Int),
  data: BitArray,
) -> #(List(String), #(List(BitArray), Int))

@external(erlang, "pharos_daemon_ffi", "test_ops_enabled")
fn test_ops_enabled() -> Bool

@external(erlang, "pharos_daemon_ffi", "kill_daemon_actor")
fn kill_daemon_actor() -> Nil

@external(erlang, "pharos_daemon_ffi", "os_pid")
fn os_pid() -> Int
