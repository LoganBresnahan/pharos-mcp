//// Stdio transport worker actor (ADR-017).
////
//// Wraps the read-line/dispatch/write-response loop in a supervised
//// actor with `transient` restart strategy: stdin EOF returns
//// `actor.stop()` so the supervisor does NOT restart (clean
//// program exit), but a crash inside dispatch returns abnormally
//// and the supervisor brings the worker back.
////
//// The actor drives itself: each iteration sends `Read` to its own
//// mailbox before returning, so subsequent stdio reads run as
//// regular handler invocations rather than a tail-recursive
//// blocking call. That preserves OTP supervision semantics and
//// gives a drop-in seam for the future async-tools/call dispatch
//// refactor (ADR-016 follow-up).

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

import pharos/log
import pharos/lsp/pool.{type Pool}
import pharos/mcp/server
import pharos/mcp/stdio

pub type Worker {
  Worker(subject: Subject(Msg))
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Read
  Stop
}

type State {
  State(pool: Pool, self: Subject(Msg))
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
      Ok(pool_handle) ->
        Ok(
          actor.initialised(State(pool: pool_handle, self: self))
          |> actor.returning(self),
        )
    }
  }

  actor.new_with_initialiser(5000, initialise)
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result_kick_loop()
}

fn result_kick_loop(
  result: Result(actor.Started(Subject(Msg)), actor.StartError),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  case result {
    Ok(started) -> {
      process.send(started.data, Read)
      Ok(started)
    }
    Error(e) -> Error(e)
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Read -> handle_read(state)
    Stop -> actor.stop()
  }
}

fn handle_read(state: State) -> actor.Next(State, Msg) {
  case stdio.read_line() {
    stdio.StdinEof -> {
      log.info("stdin closed; stdio_worker exiting")
      pool.close_all(state.pool)
      actor.stop()
    }

    stdio.StdinError(reason) -> {
      log.error("stdin read error: " <> reason)
      pool.close_all(state.pool)
      actor.stop()
    }

    stdio.StdinLine(line) -> {
      let trimmed = stdio.trim_trailing_newline(line)
      case trimmed {
        "" -> Nil
        body ->
          case server.handle_line(state.pool, body) {
            server.Reply(json) -> stdio.write(json)
            server.NoReply -> Nil
            server.ProtocolError(json) -> stdio.write(json)
          }
      }
      process.send(state.self, Read)
      actor.continue(state)
    }
  }
}
