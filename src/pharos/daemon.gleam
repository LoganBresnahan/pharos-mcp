//// The shared daemon (ADR-034): `pharos daemon --socket <path>
//// --build <id> --key <key>`.
////
//// One actor owns the listening Unix socket and the idle clock. An
//// acceptor process hands each accepted socket to its own `daemon/conn`
//// actor. Every session shares the one LSP pool.
////
//// Which sessions are live is not this actor's state: it is the
//// `pharos_daemon_sessions` ETS table, created at boot by
//// `init_registry/0`, so it outlives the actor. Connections register
//// and unregister there themselves. If the actor is restarted (a
//// listener crash), the connections it accepted keep serving, they
//// stay counted, and the restarted daemon will not idle-exit under
//// them.
////
//// The daemon exits on its own once no session has been live for
//// `PHAROS_DAEMON_IDLE_SECS` (default 1800), through the same orderly
//// application stop as SIGTERM, which also removes its socket and pid
//// file (`pharos_daemon_ffi:cleanup/0`, called from the app's stop).

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
import pharos/lsp/pool

pub type Args {
  Args(socket: String, build: String, key: String)
}

pub opaque type Msg {
  IdleCheck
}

type State {
  State(self: Subject(Msg), idle_ms: Int)
}

/// Create the session registry. Call at boot, from the process that
/// owns the other pharos tables, before the supervisor starts.
@external(erlang, "pharos_daemon_ffi", "sessions_init")
pub fn init_registry() -> Nil

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
    case listen(args.socket) {
      Error(reason) -> Error("cannot listen on the socket: " <> reason)
      Ok(listener) -> {
        register_daemon_actor()
        let pid_path = pid_path(args.socket)
        write_pid_file(pid_path)
        register_cleanup(args.socket, pid_path)
        let hooks = hooks(args)
        let _acceptor = process.spawn(fn() { accept_loop(listener, hooks, 0) })
        let state = State(self: self, idle_ms: idle_secs() * 1000)
        log.fields_at("pharos/daemon", log_entry.Info, "daemon listening", [
          #("socket", args.socket),
          #("build", args.build),
          #("key", args.key),
          #("idle_secs", int.to_string(idle_secs())),
          #("live_sessions", int.to_string(list.length(sessions_live()))),
        ])
        schedule_idle_check(state)
        Ok(
          actor.initialised(state)
          |> actor.returning(self),
        )
      }
    }
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// What a connection calls back into. None of it goes through this
/// actor, so it keeps working across a restart of the actor.
fn hooks(args: Args) -> conn.Hooks {
  conn.Hooks(
    build: args.build,
    register: fn(cwd, client_pid, _shim_pid) {
      session_register(cwd, client_pid)
    },
    unregister: session_unregister,
    status: fn() { status_json(args) },
    stop: fn() {
      log.info_at("pharos/daemon", "stop requested; daemon exiting")
      stop_daemon()
    },
  )
}

/// Accept connections forever, one `conn` actor each. Transient errors
/// (fd exhaustion, an aborted connect) back off and retry; anything
/// else means the listener is gone, and the acceptor dies with it,
/// taking the linked daemon actor down for the supervisor to rebuild.
/// Connections are unlinked: one crashing must not take the acceptor
/// (and every other session) with it.
fn accept_loop(listener: Listener, hooks: conn.Hooks, failures: Int) -> Nil {
  case accept(listener) {
    Error(reason) ->
      case transient_accept_error(reason) {
        True -> {
          let backoff = int.min(1000, 50 * { failures + 1 })
          log.fields_at(
            "pharos/daemon",
            log_entry.Warn,
            "accept failed; retrying",
            [#("reason", reason), #("backoff_ms", int.to_string(backoff))],
          )
          process.sleep(backoff)
          accept_loop(listener, hooks, failures + 1)
        }
        False -> panic as { "daemon accept failed: " <> reason }
      }
    Ok(socket) -> {
      case pool.global() {
        Error(_) -> {
          log.warn_at("pharos/daemon", "no pool; dropping connection")
          close(socket)
        }
        Ok(pool_handle) ->
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
      }
      accept_loop(listener, hooks, 0)
    }
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    IdleCheck ->
      // sessions_live/0 also prunes sessions whose connection died
      // without unregistering.
      case sessions_live() {
        [_, ..] -> {
          sessions_touch()
          schedule_idle_check(state)
          actor.continue(state)
        }
        [] ->
          case now_ms() - sessions_last_active() >= state.idle_ms {
            True -> {
              log.fields_at(
                "pharos/daemon",
                log_entry.Info,
                "no sessions for the idle timeout; daemon exiting",
                [#("idle_secs", int.to_string(state.idle_ms / 1000))],
              )
              stop_daemon()
              actor.continue(state)
            }
            False -> {
              schedule_idle_check(state)
              actor.continue(state)
            }
          }
      }
  }
}

/// Poll a few times per idle period, at least every 30 s.
fn schedule_idle_check(state: State) -> Nil {
  let every = int.clamp(state.idle_ms / 4, min: 250, max: 30_000)
  let _ = process.send_after(state.self, every, IdleCheck)
  Nil
}

/// The `status` op's reply. Sessions by id, cwd and client pid; never
/// their env.
fn status_json(args: Args) -> String {
  let now = now_ms()
  let sessions =
    sessions_live()
    |> list.map(fn(s) {
      let #(id, cwd, client_pid, since) = s
      json.object([
        #("id", json.string(id)),
        #("cwd", json.string(cwd)),
        #("client_pid", json.int(client_pid)),
        #("connected_secs", json.int({ now - since } / 1000)),
      ])
    })
  let lsps = case pool.global() {
    Error(_) -> []
    Ok(pool_handle) ->
      pool.snapshot(pool_handle).entries
      |> list.map(fn(e) {
        json.object([
          #("language", json.string(e.language)),
          #("workspace", json.string(e.workspace)),
          #("server", json.string(e.server_id)),
          #("state", json.string(state_label(e.state))),
        ])
      })
  }
  json.object([
    #("pharos_status", json.int(1)),
    #("build", json.string(args.build)),
    #("key", json.string(args.key)),
    #("daemon_pid", json.int(os_pid())),
    #("uptime_secs", json.int({ now - sessions_started() } / 1000)),
    #("idle_secs", json.int(idle_secs())),
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

@external(erlang, "pharos_daemon_ffi", "transient_accept_error")
fn transient_accept_error(reason: String) -> Bool

@external(erlang, "pharos_daemon_ffi", "hand_over")
fn hand_over(socket: Socket, pid: process.Pid) -> Nil

@external(erlang, "pharos_daemon_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "pharos_daemon_ffi", "write_pid_file")
fn write_pid_file(path: String) -> Nil

@external(erlang, "pharos_daemon_ffi", "register_cleanup")
fn register_cleanup(socket: String, pid_path: String) -> Nil

@external(erlang, "pharos_daemon_ffi", "session_register")
fn session_register(cwd: String, client_pid: Int) -> String

@external(erlang, "pharos_daemon_ffi", "session_unregister")
fn session_unregister(id: String) -> Nil

@external(erlang, "pharos_daemon_ffi", "sessions_live")
fn sessions_live() -> List(#(String, String, Int, Int))

@external(erlang, "pharos_daemon_ffi", "sessions_touch")
fn sessions_touch() -> Nil

@external(erlang, "pharos_daemon_ffi", "sessions_last_active")
fn sessions_last_active() -> Int

@external(erlang, "pharos_daemon_ffi", "sessions_started")
fn sessions_started() -> Int

@external(erlang, "pharos_daemon_ffi", "register_daemon_actor")
fn register_daemon_actor() -> Nil

@external(erlang, "pharos_daemon_ffi", "os_pid")
fn os_pid() -> Int

@external(erlang, "pharos_daemon_ffi", "now_ms")
fn now_ms() -> Int

/// Unlink the socket and pid file first, then stop the application.
/// The orderly stop takes seconds (in-flight drain, LSP teardown); a
/// shim arriving meanwhile must find no socket and start a fresh
/// daemon, not join this one as it goes.
fn stop_daemon() -> Nil {
  cleanup()
  init_stop()
}

@external(erlang, "pharos_daemon_ffi", "cleanup")
fn cleanup() -> Nil

@external(erlang, "pharos_runtime_ffi", "init_stop")
fn init_stop() -> Nil
