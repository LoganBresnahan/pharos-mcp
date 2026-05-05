//// Logger writer actor.
////
//// One process owns the formatting + sink fan-out. Producers cast
//// `Emit(LogEntry)` and never block. The actor's Subject is stored
//// in `persistent_term` under `pharos_log_writer_subject` so any
//// process can locate it without threading a handle through every
//// call site.
////
//// Mailbox is bounded cooperatively: producers consult mailbox
//// depth before sending and drop on overflow. Drops surface as a
//// single `dropped=N` warn line on the writer's next successful
//// emission rather than per-drop noise.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import pharos/log/entry.{
  type Level, type LogEntry, LogEntry, Warn,
}
import pharos/log/filter.{type Filter, Filter, Override}
import pharos/log/ring

const max_mailbox_depth: Int = 1000

pub type Writer {
  Writer(subject: Subject(Msg))
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Emit(LogEntry)
  NoteDrop
  SetFilter(Filter)
  SetTarget(target_prefix: String, level: Option(Level))
  Stop
}

type State {
  State(
    filter: Filter,
    ring_enabled: Bool,
    stderr_enabled: Bool,
    dropped: Int,
  )
}

/// Spawn the writer. Stores its Subject in persistent_term so
/// producers can locate it. Re-registering replaces any prior pid.
pub fn start(
  filter: Filter,
  ring_enabled: Bool,
  stderr_enabled: Bool,
) -> Result(Writer, StartError) {
  case ring_enabled {
    True -> ring.init(ring.default_capacity)
    False -> Nil
  }

  actor.new(State(
    filter: filter,
    ring_enabled: ring_enabled,
    stderr_enabled: stderr_enabled,
    dropped: 0,
  ))
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) {
    let subject = started.data
    register_subject(subject)
    Writer(subject: subject)
  })
  |> result.map_error(StartFailedActor)
}

/// Cast an entry to the writer. Performs the mailbox-depth guard
/// and falls back to direct stderr output when the writer is not
/// registered (early boot, post-shutdown) or when the mailbox is
/// at capacity.
pub fn emit(log_entry: LogEntry) -> Nil {
  case lookup_subject() {
    Error(_) -> direct_stderr(entry.render(log_entry))
    Ok(subject) ->
      case process.subject_owner(subject) {
        Error(_) -> direct_stderr(entry.render(log_entry))
        Ok(pid) ->
          case mailbox_len(pid) > max_mailbox_depth {
            True -> {
              process.send(subject, NoteDrop)
              Nil
            }
            False -> process.send(subject, Emit(log_entry))
          }
      }
  }
}

/// Replace the writer's filter at runtime. Used by
/// `runtime_log_level` (Part C).
pub fn set_filter(writer: Writer, new_filter: Filter) -> Nil {
  process.send(writer.subject, SetFilter(new_filter))
}

/// Override one target's level at runtime. `level = None` silences
/// the target.
pub fn set_target(
  writer: Writer,
  target_prefix: String,
  level: Option(Level),
) -> Nil {
  process.send(writer.subject, SetTarget(target_prefix, level))
}

pub fn stop(writer: Writer) -> Nil {
  process.send(writer.subject, Stop)
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Emit(log_entry) ->
      case filter.allows(state.filter, log_entry.target, log_entry.level) {
        False -> actor.continue(state)
        True -> {
          let line = entry.render(log_entry)
          fan_out(state, line, log_entry.level)
          case state.dropped {
            0 -> actor.continue(state)
            n -> {
              let drop_line =
                entry.render(LogEntry(
                  timestamp_ms: now_ms(),
                  level: Warn,
                  target: "pharos/log/writer",
                  correlation_id: "",
                  message: "log entries dropped due to backpressure",
                  fields: [#("dropped", int_to_string(n))],
                ))
              fan_out(state, drop_line, Warn)
              actor.continue(State(..state, dropped: 0))
            }
          }
        }
      }

    NoteDrop ->
      actor.continue(State(..state, dropped: state.dropped + 1))

    SetFilter(new_filter) ->
      actor.continue(State(..state, filter: new_filter))

    SetTarget(target_prefix, level) ->
      actor.continue(State(
        ..state,
        filter: update_overrides(state.filter, target_prefix, level),
      ))

    Stop -> actor.stop()
  }
}

fn fan_out(state: State, line: String, level: Level) -> Nil {
  case state.stderr_enabled {
    True -> direct_stderr(line)
    False -> Nil
  }
  case state.ring_enabled {
    True -> ring.insert(line, level)
    False -> Nil
  }
}

fn update_overrides(
  current: Filter,
  target_prefix: String,
  level: Option(Level),
) -> Filter {
  let kept =
    list.filter(current.overrides, fn(ovr) {
      ovr.target_prefix != target_prefix
    })
  let next = case level {
    None -> [Override(target_prefix, None), ..kept]
    Some(_) -> [Override(target_prefix, level), ..kept]
  }
  Filter(default: current.default, overrides: next)
}

@external(erlang, "pharos_log_ffi", "writer_register_subject")
fn register_subject(subject: Subject(Msg)) -> Nil

@external(erlang, "pharos_log_ffi", "writer_subject")
fn lookup_subject() -> Result(Subject(Msg), Nil)

@external(erlang, "pharos_log_ffi", "mailbox_len")
fn mailbox_len(pid: Pid) -> Int

@external(erlang, "pharos_log_ffi", "direct_stderr")
fn direct_stderr(line: String) -> Nil

@external(erlang, "pharos_log_ffi", "iso_timestamp_ms")
fn now_ms() -> String

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
