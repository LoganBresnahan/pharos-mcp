//// The shared daemon (ADR-034): `pharos daemon --socket <path>
//// --build <id> --key <key>`.
////
//// One actor owns the listening Unix socket, the registry of
//// connected sessions and the idle timer. An acceptor process hands
//// each accepted socket to its own `daemon/conn` actor. Every session
//// shares the one LSP pool.
////
//// The daemon exits on its own once no session has been connected for
//// `PHAROS_DAEMON_IDLE_SECS` (default 1800), through the same orderly
//// application stop as SIGTERM, which also removes its socket and pid
//// file (`pharos_daemon_ffi:cleanup/0`, called from the app's stop).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import pharos/daemon/conn.{type Socket}
import pharos/env
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/pool.{type Pool}

pub type Args {
  Args(socket: String, build: String, key: String)
}

pub opaque type Msg {
  Register(cwd: String, client_pid: Int, shim_pid: Int, reply: Subject(String))
  Unregister(id: String)
  IdleCheck(generation: Int)
  StatusReq(reply: Subject(String))
  StopReq
}

type Session {
  Session(id: String, cwd: String, client_pid: Int, since_ms: Int)
}

type State {
  State(
    self: Subject(Msg),
    args: Args,
    pool: Pool,
    sessions: Dict(String, Session),
    next_id: Int,
    /// Bumped on every connect and disconnect; an `IdleCheck` from an
    /// older generation is stale and ignored.
    generation: Int,
    idle_ms: Int,
    started_ms: Int,
  )
}

/// Parse `daemon --socket <path> --build <id> --key <key>` out of argv.
/// `None` when argv is not a daemon invocation.
pub fn parse_args(argv: List(String)) -> option.Option(Args) {
  case argv {
    ["daemon", ..rest] -> {
      let flag = fn(name) { flag_value(rest, name) }
      case flag("--socket"), flag("--build") {
        Some(socket), Some(build) ->
          Some(Args(socket:, build:, key: option.unwrap(flag("--key"), "0")))
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn flag_value(args: List(String), name: String) -> option.Option(String) {
  case args {
    [flag, value, ..] if flag == name -> Some(value)
    [_, ..rest] -> flag_value(rest, name)
    [] -> None
  }
}

pub fn start_supervised(
  args: Args,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(10_000, fn(self) {
    case pool.global() {
      Error(_) -> Error("pool.global() returned no subject")
      Ok(pool_handle) ->
        case listen(args.socket) {
          Error(reason) -> Error("cannot listen on the socket: " <> reason)
          Ok(listener) -> {
            let pid_path = pid_path(args.socket)
            write_pid_file(pid_path)
            register_cleanup(args.socket, pid_path)
            let hooks = hooks(self, args.build)
            let _acceptor =
              process.spawn(fn() { accept_loop(listener, pool_handle, hooks) })
            let state =
              State(
                self: self,
                args: args,
                pool: pool_handle,
                sessions: dict.new(),
                next_id: 1,
                generation: 0,
                idle_ms: idle_secs() * 1000,
                started_ms: now_ms(),
              )
            log.fields_at("pharos/daemon", log_entry.Info, "daemon listening", [
              #("socket", args.socket),
              #("build", args.build),
              #("key", args.key),
              #("idle_secs", int.to_string(idle_secs())),
            ])
            // Nothing is connected yet: start the idle clock now, so a
            // daemon whose shim died before connecting still exits.
            schedule_idle_check(state)
            Ok(
              actor.initialised(state)
              |> actor.returning(self),
            )
          }
        }
    }
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn hooks(daemon: Subject(Msg), build: String) -> conn.Hooks {
  conn.Hooks(
    build: build,
    register: fn(cwd, client_pid, shim_pid) {
      actor.call(daemon, 5000, fn(reply) {
        Register(cwd, client_pid, shim_pid, reply)
      })
    },
    unregister: fn(id) { process.send(daemon, Unregister(id)) },
    status: fn() { actor.call(daemon, 5000, StatusReq) },
    stop: fn() { process.send(daemon, StopReq) },
  )
}

/// Accept connections forever, one `conn` actor each. Linked to the
/// daemon actor, so a dead listener takes the daemon down and the
/// supervisor rebuilds both. Connections are unlinked: one crashing
/// must not take the acceptor (and every other session) with it.
fn accept_loop(
  listener: Listener,
  pool_handle: Pool,
  hooks: conn.Hooks,
) -> Nil {
  case accept(listener) {
    Error(reason) -> panic as { "daemon accept failed: " <> reason }
    Ok(socket) -> {
      case conn.start(socket, pool_handle, hooks) {
        Ok(started) -> {
          process.unlink(started.pid)
          hand_over(socket, started.pid)
          conn.begin(started.data)
        }
        Error(_) -> {
          log.warn_at("pharos/daemon", "connection actor failed to start")
          close(socket)
        }
      }
      accept_loop(listener, pool_handle, hooks)
    }
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Register(cwd, client_pid, _shim_pid, reply) -> {
      let id = "s" <> int.to_string(state.next_id)
      let session =
        Session(id: id, cwd: cwd, client_pid: client_pid, since_ms: now_ms())
      process.send(reply, id)
      actor.continue(
        State(
          ..state,
          sessions: dict.insert(state.sessions, id, session),
          next_id: state.next_id + 1,
          generation: state.generation + 1,
        ),
      )
    }
    Unregister(id) -> {
      let state =
        State(
          ..state,
          sessions: dict.delete(state.sessions, id),
          generation: state.generation + 1,
        )
      case dict.size(state.sessions) {
        0 -> schedule_idle_check(state)
        _ -> Nil
      }
      actor.continue(state)
    }
    IdleCheck(generation) ->
      case generation == state.generation && dict.size(state.sessions) == 0 {
        False -> actor.continue(state)
        True -> {
          log.fields_at(
            "pharos/daemon",
            log_entry.Info,
            "no sessions for the idle timeout; daemon exiting",
            [#("idle_secs", int.to_string(state.idle_ms / 1000))],
          )
          init_stop()
          actor.continue(state)
        }
      }
    StatusReq(reply) -> {
      process.send(reply, status_json(state))
      actor.continue(state)
    }
    StopReq -> {
      log.info_at("pharos/daemon", "stop requested; daemon exiting")
      init_stop()
      actor.continue(state)
    }
  }
}

fn schedule_idle_check(state: State) -> Nil {
  let _ =
    process.send_after(state.self, state.idle_ms, IdleCheck(state.generation))
  Nil
}

/// The `status` op's reply. Sessions by id, cwd and client pid; never
/// their env.
fn status_json(state: State) -> String {
  let now = now_ms()
  let sessions =
    state.sessions
    |> dict.values
    |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
    |> list.map(fn(s) {
      json.object([
        #("id", json.string(s.id)),
        #("cwd", json.string(s.cwd)),
        #("client_pid", json.int(s.client_pid)),
        #("connected_secs", json.int({ now - s.since_ms } / 1000)),
      ])
    })
  let lsps =
    pool.snapshot(state.pool).entries
    |> list.map(fn(e) {
      json.object([
        #("language", json.string(e.language)),
        #("workspace", json.string(e.workspace)),
        #("server", json.string(e.server_id)),
        #("state", json.string(state_label(e.state))),
      ])
    })
  json.object([
    #("pharos_status", json.int(1)),
    #("build", json.string(state.args.build)),
    #("key", json.string(state.args.key)),
    #("daemon_pid", json.int(os_pid())),
    #("uptime_secs", json.int({ now - state.started_ms } / 1000)),
    #("idle_secs", json.int(state.idle_ms / 1000)),
    #("sessions", json.preprocessed_array(sessions)),
    #("lsps", json.preprocessed_array(lsps)),
  ])
  |> json.to_string
}

fn state_label(state: pool.LspState) -> String {
  case state {
    pool.Spawning -> "spawning"
    pool.Probing -> "probing"
    pool.Ready -> "ready"
    pool.Failed(_) -> "failed"
  }
}

fn idle_secs() -> Int {
  case env.get("PHAROS_DAEMON_IDLE_SECS") {
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(n) if n >= 0 -> n
        _ -> 1800
      }
    None -> 1800
  }
}

/// `<dir>/<name>.sock` → `<dir>/<name>.pid`.
pub fn pid_path(socket: String) -> String {
  case string.ends_with(socket, ".sock") {
    True -> string.drop_end(socket, 5) <> ".pid"
    False -> socket <> ".pid"
  }
}

type Listener

@external(erlang, "pharos_daemon_ffi", "listen")
fn listen(path: String) -> Result(Listener, String)

@external(erlang, "pharos_daemon_ffi", "accept")
fn accept(listener: Listener) -> Result(Socket, String)

@external(erlang, "pharos_daemon_ffi", "hand_over")
fn hand_over(socket: Socket, pid: process.Pid) -> Nil

@external(erlang, "pharos_daemon_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "pharos_daemon_ffi", "write_pid_file")
fn write_pid_file(path: String) -> Nil

@external(erlang, "pharos_daemon_ffi", "register_cleanup")
fn register_cleanup(socket: String, pid_path: String) -> Nil

@external(erlang, "pharos_daemon_ffi", "os_pid")
fn os_pid() -> Int

@external(erlang, "pharos_daemon_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "pharos_runtime_ffi", "init_stop")
fn init_stop() -> Nil
