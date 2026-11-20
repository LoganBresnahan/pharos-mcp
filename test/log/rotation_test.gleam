//// Test for the file-sink log rotation added in M13 Phase 3
//// (ADR 022). Writes enough log entries to trigger several
//// rotations, then asserts the rename-ladder kept the configured
//// number of rotated files and dropped anything beyond.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import pharos/log
import pharos/log/entry.{LogEntry}
import pharos/log/filter.{Filter}
import pharos/log/writer

pub fn rotates_at_max_bytes_and_keeps_n_test() {
  // Unique per-test path so concurrent test runs don't collide.
  let path = "/tmp/pharos-rotation-test-" <> int_str(unique_int()) <> ".log"
  let _ = file_delete(path)
  let _ = file_delete(numbered(path, 1))
  let _ = file_delete(numbered(path, 2))
  let _ = file_delete(numbered(path, 3))

  let f = Filter(default: entry.Info, overrides: [])
  // file_max_bytes = 200 bytes is small enough that ~5 lines of a
  // structured log message overflow it. keep_rotated = 2 means we
  // expect path.1 + path.2 to exist after enough emits and path.3
  // to have been dropped.
  let assert Ok(w) = writer.start(f, False, False, Some(path), Some(200), 2)
  let assert Ok(pid) = process.subject_owner(w.subject)
  let down = process.monitor(pid)

  // Straight to this writer: `log.*` goes to whichever writer
  // registered last, shared with anything else logging meanwhile (#18).
  burst_emit(w, "rotation-test", 30)

  // Wait for the writer to exit rather than sleeping: the mailbox is
  // in order, so once it has handled Stop it has handled every Emit
  // (and its exit closes the file). A fixed sleep failed under load
  // (#18).
  writer.stop(w)
  case
    process.new_selector()
    |> process.select_specific_monitor(down, fn(d) { d })
    |> process.selector_receive(10_000)
  {
    Ok(_) -> Nil
    Error(Nil) -> panic as "the writer didn't stop within 10 s"
  }

  // After 3+ rotations with keep_rotated=2:
  //   path     -> exists (active file post-final-rotation)
  //   path.1   -> exists (most recent rotation)
  //   path.2   -> exists (second-most-recent)
  //   path.3   -> MUST NOT exist (dropped by keep-rotated horizon)
  case file_exists(path) {
    True -> Nil
    False -> panic as "active log file missing after rotation"
  }
  case file_exists(numbered(path, 1)) {
    True -> Nil
    False -> panic as "path.1 missing — first rotation didn't happen"
  }
  case file_exists(numbered(path, 2)) {
    True -> Nil
    False -> panic as "path.2 missing — second rotation didn't happen"
  }
  case file_exists(numbered(path, 3)) {
    False -> Nil
    True ->
      panic as "path.3 still exists — keep_rotated=2 should have dropped it"
  }

  let _ = file_delete(path)
  let _ = file_delete(numbered(path, 1))
  let _ = file_delete(numbered(path, 2))
}

/// The path every caller takes: `log.*` → the registered writer → its
/// file. The rotation test above sends straight to its writer, so this
/// one keeps that path covered (#18 review).
pub fn log_calls_reach_the_registered_writers_file_test() {
  let path = "/tmp/pharos-log-path-test-" <> int_str(unique_int()) <> ".log"
  let _ = file_delete(path)
  let f = Filter(default: entry.Info, overrides: [])
  let assert Ok(w) = writer.start(f, False, False, Some(path), None, 0)
  let assert Ok(pid) = process.subject_owner(w.subject)
  let down = process.monitor(pid)

  log.fields_at("log-path-test", entry.Info, "through the registered writer", [
    #("marker", "lp-18"),
  ])
  writer.stop(w)
  case
    process.new_selector()
    |> process.select_specific_monitor(down, fn(d) { d })
    |> process.selector_receive(10_000)
  {
    Ok(_) -> Nil
    Error(Nil) -> panic as "the writer didn't stop within 10 s"
  }

  // Read, then remove the file before judging, so a failed run leaves
  // nothing behind.
  let text = read_text(path)
  let _ = file_delete(path)
  case text {
    Ok(text) ->
      case
        string.contains(text, "through the registered writer")
        && string.contains(text, "lp-18")
      {
        True -> Nil
        False ->
          panic as "the log line didn't reach the registered writer's file"
      }
    Error(_) -> panic as "the registered writer's file couldn't be read"
  }
}

fn burst_emit(w: writer.Writer, target: String, n: Int) -> Nil {
  case n <= 0 {
    True -> Nil
    False -> {
      writer.emit_to(
        w,
        LogEntry(
          timestamp_ms: "2026-11-19T00:00:00.000Z",
          level: entry.Info,
          target: target,
          correlation_id: "",
          message: "rotation burst line",
          fields: [
            #("seq", int_str(n)),
            #("payload", "padding-padding-padding-padding"),
          ],
        ),
      )
      burst_emit(w, target, n - 1)
    }
  }
}

fn numbered(path: String, n: Int) -> String {
  path <> "." <> int_str(n)
}

@external(erlang, "erlang", "integer_to_binary")
fn int_str(n: Int) -> String

@external(erlang, "filelib", "is_regular")
fn file_exists(path: String) -> Bool

@external(erlang, "file", "delete")
fn file_delete(path: String) -> Result(Nil, Dynamic)

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

@external(erlang, "file", "read_file")
fn read_text(path: String) -> Result(String, Dynamic)
