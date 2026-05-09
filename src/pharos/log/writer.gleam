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

const trace_target: String = "pharos/lsp/trace"

/// Atom-tag passed to the trace-filter cache FFI. Two-state on / off
/// mirrors the only thing the trace producer needs to know.
pub type TraceCache {
  TraceCacheOn
  TraceCacheOff
}

const trace_cache_on: TraceCache = TraceCacheOn

const trace_cache_off: TraceCache = TraceCacheOff

@external(erlang, "pharos_runtime_ffi", "trace_filter_cache_set")
fn trace_filter_cache_set(state: TraceCache) -> Nil

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
  SetTargetSync(
    target_prefix: String,
    level: Option(Level),
    reply: Subject(Nil),
  )
  Stop
}

type State {
  State(
    filter: Filter,
    ring_enabled: Bool,
    stderr_enabled: Bool,
    file_handle: Option(FileHandle),
    /// Path the active file sink writes to. Held alongside the
    /// handle so rotation can rename the file in-place when the
    /// active file's byte count exceeds `file_max_bytes`.
    file_path: Option(String),
    /// Cap on active-file size; `None` disables rotation.
    file_max_bytes: Option(Int),
    /// Number of rotated files to keep (`pharos.log.1` ... `.N`).
    file_keep_rotated: Int,
    /// Running byte count of the active file. Initialised to the
    /// file's current size on open (so a long-lived file's first
    /// session-after-restart still rotates at the right point).
    file_bytes_written: Int,
    dropped: Int,
  )
}

/// Opaque file handle from `pharos_log_ffi:file_sink_open/1`. Erlang
/// IO device; never inspected on the Gleam side.
pub type FileHandle

/// Spawn the writer. Stores its Subject in persistent_term so
/// producers can locate it. Re-registering replaces any prior pid.
///
/// `file_path = Some(path)` opens an append-only file sink at
/// `path`. Parent directories are created if missing. Open failure
/// is logged via direct stderr and the writer continues without
/// the file sink — startup is never blocked by a logging
/// configuration error.
pub fn start(
  filter: Filter,
  ring_enabled: Bool,
  stderr_enabled: Bool,
  file_path: Option(String),
  file_max_bytes: Option(Int),
  file_keep_rotated: Int,
) -> Result(Writer, StartError) {
  case ring_enabled {
    True -> ring.init(ring.default_capacity)
    False -> Nil
  }

  seed_trace_cache_from_filter(filter)

  // Open the file inside the initialiser so the actor process owns
  // the delayed_write proxy's controlling-process slot. Opening on
  // the caller and passing the handle into the actor's state fails
  // at the first write with NotOnControllingProcess.
  actor.new_with_initialiser(2000, fn(subject) {
    let state =
      build_initial_state(
        filter,
        ring_enabled,
        stderr_enabled,
        file_path,
        file_max_bytes,
        file_keep_rotated,
      )
    Ok(actor.initialised(state) |> actor.returning(subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) {
    let subject = started.data
    register_subject(subject)
    sentinel_set()
    Writer(subject: subject)
  })
  |> result.map_error(StartFailedActor)
}

/// Mirror the initial filter's `pharos/lsp/trace` allowed-state into
/// the persistent_term cache at writer boot. Picks up the case where
/// `PHAROS_TRACE_LSP=1` was honoured by `pharos.gleam`'s boot-time
/// filter assembly — without this seed, producers would short-circuit
/// to "off" at boot even when the override exists, until the first
/// runtime_log_level call updates the cache.
fn seed_trace_cache_from_filter(f: Filter) -> Nil {
  let allowed = filter.allows(f, trace_target, entry.Debug)
  trace_filter_cache_set(case allowed {
    True -> trace_cache_on
    False -> trace_cache_off
  })
}

/// Supervised entry point — spawns the writer with the same config
/// as `start/4` but returns the `actor.Started` shape that the
/// supervisor's child spec expects (ADR-017). Performs prior-
/// incarnation crash detection: if a sentinel from a previous
/// writer is present in the ring meta table when this init runs,
/// the previous writer died abnormally; tail the ring and dump it
/// to `~/.cache/pharos/log/crash-<timestamp>.log` before resuming
/// normal operation.
pub fn start_supervised(
  filter: Filter,
  ring_enabled: Bool,
  stderr_enabled: Bool,
  file_path: Option(String),
  file_max_bytes: Option(Int),
  file_keep_rotated: Int,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  case ring_enabled {
    True -> {
      ring.init(ring.default_capacity)
      maybe_write_crash_dump()
    }
    False -> Nil
  }

  // Same controlling-process consideration as `start/6` — open the
  // file inside the initialiser on the actor process.
  actor.new_with_initialiser(2000, fn(subject) {
    let state =
      build_initial_state(
        filter,
        ring_enabled,
        stderr_enabled,
        file_path,
        file_max_bytes,
        file_keep_rotated,
      )
    Ok(actor.initialised(state) |> actor.returning(subject))
  })
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) {
    let subject = started.data
    register_subject(subject)
    sentinel_set()
    started
  })
}

fn build_initial_state(
  filter: Filter,
  ring_enabled: Bool,
  stderr_enabled: Bool,
  file_path: Option(String),
  file_max_bytes: Option(Int),
  file_keep_rotated: Int,
) -> State {
  let file_handle = case file_path {
    None -> None
    Some(path) ->
      case file_sink_open(path) {
        Ok(handle) -> Some(handle)
        Error(reason) -> {
          direct_stderr(
            "[pharos/log] file sink open failed for "
            <> path
            <> ": "
            <> reason
            <> " (continuing without file sink)",
          )
          None
        }
      }
  }
  // Init the byte counter to the file's current size so a long-
  // lived log file rotates at the right point even after a restart.
  let initial_bytes = case file_path {
    None -> 0
    Some(path) -> file_size_or_zero(path)
  }
  State(
    filter: filter,
    ring_enabled: ring_enabled,
    stderr_enabled: stderr_enabled,
    file_handle: file_handle,
    file_path: file_path,
    file_max_bytes: file_max_bytes,
    file_keep_rotated: file_keep_rotated,
    file_bytes_written: initial_bytes,
    dropped: 0,
  )
}

/// Detect a prior-incarnation crash via the ring sentinel and
/// dump the current ring tail to a crash file. No-op when the
/// sentinel is absent (clean prior shutdown or first boot).
fn maybe_write_crash_dump() -> Nil {
  case sentinel_present() {
    False -> Nil
    True -> {
      let tail = ring.tail(2000, "")
      case tail {
        [] -> Nil
        rows -> {
          let path = crash_dump_path()
          let lines = rows_to_binaries(rows)
          case crash_dump_write(path, lines) {
            Ok(written_path) ->
              direct_stderr(
                "[pharos/log] previous writer crashed; ring tail dumped to "
                <> written_path,
              )
            Error(reason) ->
              direct_stderr(
                "[pharos/log] previous writer crashed; crash-dump write failed: "
                <> reason,
              )
          }
        }
      }
      // Clear the stale sentinel; the new writer's start path will
      // set a fresh one after subject registration succeeds.
      sentinel_clear()
    }
  }
}

fn rows_to_binaries(
  rows: List(#(entry.Level, String)),
) -> List(String) {
  list.map(rows, fn(row) {
    let #(_level, line) = row
    line
  })
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

/// Globally-addressable target override. Looks up the writer via
/// the persistent_term registration and synchronously updates the
/// filter. Synchronous (process.call) on purpose: a cast lets the
/// caller race ahead of the actor's mailbox, so any in-flight Emit
/// messages from other producers can be processed under the OLD
/// filter before this one applies — runtime_trace_lsp captured
/// empty results that way. Returns `Error(Nil)` when the writer is
/// not running or the call times out.
pub fn set_target_global(
  target_prefix: String,
  level: Option(Level),
) -> Result(Nil, Nil) {
  case lookup_subject() {
    Error(_) -> Error(Nil)
    Ok(subject) ->
      case
        process.call(subject, 1000, fn(reply) {
          SetTargetSync(target_prefix, level, reply)
        })
      {
        Nil -> Ok(Nil)
      }
  }
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
          let after_fan =
            fan_out(state, line, log_entry.level, log_entry.target)
          case after_fan.dropped {
            0 -> actor.continue(after_fan)
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
              let after_drop =
                fan_out(after_fan, drop_line, Warn, "pharos/log/writer")
              actor.continue(State(..after_drop, dropped: 0))
            }
          }
        }
      }

    NoteDrop ->
      actor.continue(State(..state, dropped: state.dropped + 1))

    SetFilter(new_filter) ->
      actor.continue(State(..state, filter: new_filter))

    SetTargetSync(target_prefix, level, reply) -> {
      let new_filter = update_overrides(state.filter, target_prefix, level)
      let next = State(..state, filter: new_filter)
      // Mirror the trace-target's allowed-state into a persistent_term
      // cache so the high-volume `pharos/lsp/trace` emitter can
      // short-circuit BEFORE casting an Emit to this actor — that
      // eliminates the residual race where a parallel-issued
      // runtime_trace_lsp + producer would still miss the producer's
      // first emit (sync filter alone closed the in-actor race; this
      // closes the at-emitter race for high-volume paths). M10 fix.
      case target_prefix == trace_target {
        True -> trace_filter_cache_set(case level {
          Some(_) -> trace_cache_on
          None -> trace_cache_off
        })
        False -> Nil
      }
      // Reply BEFORE actor.continue so the caller's `process.call` is
      // unblocked. Writer's mailbox order guarantees any subsequent
      // Emit messages will see the new filter — that's the whole point
      // of the sync variant (avoids the cast race that left
      // runtime_trace_lsp captures empty under load).
      process.send(reply, Nil)
      actor.continue(next)
    }

    Stop -> {
      // Graceful shutdown — clear the sentinel so the next
      // writer's init does not mistake this for a crash.
      sentinel_clear()
      actor.stop()
    }
  }
}

fn fan_out(
  state: State,
  line: String,
  level: Level,
  target: String,
) -> State {
  case state.stderr_enabled {
    True -> direct_stderr(line)
    False -> Nil
  }
  // The trace producer (`pharos/lsp/trace.emit`) writes its own
  // entries directly into the ring via `ring.insert/2` so they
  // survive the writer's mailbox-depth cap under load (the original
  // motivation for runtime_trace_lsp's "missing entries" symptom).
  // Skip the ring fan-out here for that target to avoid double-
  // inserting whenever the writer's mailbox does manage to keep up.
  case state.ring_enabled && target != trace_target {
    True -> ring.insert(line, level)
    False -> Nil
  }
  case state.file_handle {
    None -> state
    Some(handle) -> {
      file_sink_write(handle, line)
      // Account for the line + newline in the rotation counter.
      // file_sink_write appends `\n`; mirror that math here.
      let advance = byte_size(line) + 1
      let new_bytes = state.file_bytes_written + advance
      maybe_rotate(
        State(..state, file_bytes_written: new_bytes),
        handle,
      )
    }
  }
}

/// If the active file's running byte count has exceeded the
/// configured cap, rename the file (shifting `path.N` rotations)
/// and reopen fresh. Failures log a single warning to stderr and
/// keep the existing handle so the writer never falls silent on a
/// rotation error.
fn maybe_rotate(state: State, handle: FileHandle) -> State {
  case state.file_max_bytes, state.file_path {
    Some(cap), Some(path) if state.file_bytes_written >= cap ->
      case file_sink_rotate(handle, path, state.file_keep_rotated) {
        Ok(new_handle) ->
          State(
            ..state,
            file_handle: Some(new_handle),
            file_bytes_written: 0,
          )
        Error(reason) -> {
          direct_stderr(
            "[pharos/log] file sink rotation failed for "
            <> path
            <> ": "
            <> reason
            <> " (continuing on the unrotated file)",
          )
          // Reset the counter so we don't spin retrying every line.
          State(..state, file_bytes_written: 0)
        }
      }
    _, _ -> state
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

@external(erlang, "pharos_log_ffi", "file_sink_open")
fn file_sink_open(path: String) -> Result(FileHandle, String)

@external(erlang, "pharos_log_ffi", "file_sink_write")
fn file_sink_write(handle: FileHandle, line: String) -> Nil

/// Close the active handle, rename `path` -> `path.1` (shifting
/// existing rotations up to `keep_rotated`, dropping anything
/// beyond), and reopen `path` fresh. On failure (rename collision,
/// permission denied, etc.) leaves the existing handle alone and
/// returns Error so the writer can keep appending unrotated.
@external(erlang, "pharos_log_ffi", "file_sink_rotate")
fn file_sink_rotate(
  handle: FileHandle,
  path: String,
  keep_rotated: Int,
) -> Result(FileHandle, String)

/// Current byte size of `path` if it exists; 0 otherwise. Used to
/// init the rotation counter so a long-lived log file picks up
/// where the previous session left off.
@external(erlang, "pharos_log_ffi", "file_size_or_zero")
fn file_size_or_zero(path: String) -> Int

@external(erlang, "erlang", "byte_size")
fn byte_size(s: String) -> Int

@external(erlang, "pharos_log_ffi", "sentinel_set")
fn sentinel_set() -> Nil

@external(erlang, "pharos_log_ffi", "sentinel_clear")
fn sentinel_clear() -> Nil

@external(erlang, "pharos_log_ffi", "sentinel_present")
fn sentinel_present() -> Bool

@external(erlang, "pharos_log_ffi", "crash_dump_path")
fn crash_dump_path() -> String

@external(erlang, "pharos_log_ffi", "crash_dump_write")
fn crash_dump_write(path: String, lines: List(String)) -> Result(String, String)
