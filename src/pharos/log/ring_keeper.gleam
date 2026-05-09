//// Ring buffer owner — sidecar actor that holds the log-ring ETS
//// table independently of the writer (ADR-017).
////
//// Default ETS rule: when an owner process dies, the table is
//// deleted. If the writer owned the ring, every writer crash
//// would erase the post-mortem context users need. Splitting
//// ownership into this tiny sidecar keeps the ring intact across
//// any number of writer restarts.
////
//// The keeper does almost nothing — its `init` calls
//// `ring.init/0` (which is idempotent and creates the ETS table
//// owned by the keeper process), and its `handle_message` only
//// recognizes `Stop` for graceful shutdown. Producers continue to
//// call `ring.insert/2` directly via FFI; ETS public-table
//// permissions allow the writer to insert without owning the
//// table.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

import pharos/log/ring

pub type Keeper {
  Keeper(subject: Subject(Msg))
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Stop
}

type State {
  State
}

/// Spawn the ring keeper. Idempotent against the underlying ETS
/// table — `ring.init/0` no-ops if the table already exists.
pub fn start() -> Result(Keeper, StartError) {
  actor.new(State)
  |> actor.on_message(handle)
  |> actor.start()
  |> result_map(fn(started) {
    ring.init(ring.default_capacity)
    Keeper(subject: started.data)
  })
}

/// Child-spec-shaped variant for the supervisor. Returns
/// `actor.Started` so `static_supervisor.add(supervision.worker(...))`
/// can wire it.
pub fn start_supervised() -> Result(
  actor.Started(Subject(Msg)),
  actor.StartError,
) {
  actor.new(State)
  |> actor.on_message(handle)
  |> actor.start()
  |> with_init_side_effect()
}

fn with_init_side_effect(
  result: Result(actor.Started(Subject(Msg)), actor.StartError),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  case result {
    Ok(started) -> {
      ring.init(ring.default_capacity)
      Ok(started)
    }
    Error(e) -> Error(e)
  }
}

fn handle(_state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Stop -> actor.stop()
  }
}

pub fn stop(keeper: Keeper) -> Nil {
  process.send(keeper.subject, Stop)
}

fn result_map(
  r: Result(actor.Started(Subject(Msg)), actor.StartError),
  f: fn(actor.Started(Subject(Msg))) -> Keeper,
) -> Result(Keeper, StartError) {
  case r {
    Ok(s) -> Ok(f(s))
    Error(e) -> Error(StartFailedActor(e))
  }
}
