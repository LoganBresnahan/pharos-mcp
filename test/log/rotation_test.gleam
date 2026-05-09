//// Test for the file-sink log rotation added in M13 Phase 3
//// (ADR 022). Writes enough log entries to trigger several
//// rotations, then asserts the rename-ladder kept the configured
//// number of rotated files and dropped anything beyond.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/option.{Some}
import pharos/log
import pharos/log/entry
import pharos/log/filter.{Filter}
import pharos/log/writer

pub fn rotates_at_max_bytes_and_keeps_n_test() {
  // Unique per-test path so concurrent test runs don't collide.
  let path =
    "/tmp/pharos-rotation-test-" <> int_str(unique_int()) <> ".log"
  let _ = file_delete(path)
  let _ = file_delete(numbered(path, 1))
  let _ = file_delete(numbered(path, 2))
  let _ = file_delete(numbered(path, 3))

  let f = Filter(default: entry.Info, overrides: [])
  // file_max_bytes = 200 bytes is small enough that ~5 lines of a
  // structured log message overflow it. keep_rotated = 2 means we
  // expect path.1 + path.2 to exist after enough emits and path.3
  // to have been dropped.
  let assert Ok(w) =
    writer.start(f, False, False, Some(path), Some(200), 2)

  burst_emit("rotation-test", 30)

  // Stop closes the active handle, which flushes delayed_write.
  writer.stop(w)
  process.sleep(100)

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
      panic as
        "path.3 still exists — keep_rotated=2 should have dropped it"
  }

  let _ = file_delete(path)
  let _ = file_delete(numbered(path, 1))
  let _ = file_delete(numbered(path, 2))
}

fn burst_emit(target: String, n: Int) -> Nil {
  case n <= 0 {
    True -> Nil
    False -> {
      log.fields_at(target, entry.Info, "rotation burst line", [
        #("seq", int_str(n)),
        #("payload", "padding-padding-padding-padding"),
      ])
      // Brief sleep so the writer actor processes Emit before we
      // queue another — keeps the test from hitting the writer's
      // mailbox-depth backpressure path.
      process.sleep(2)
      burst_emit(target, n - 1)
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
