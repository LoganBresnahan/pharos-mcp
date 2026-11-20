//// Notes a tool's answer carries about how far to trust it (ADR-043).
////
//// Work done before a question (the watched-files scan) adds a note when
//// the server may not have the whole picture; the reply takes the notes
//// and shows them: get_diagnostics in its `pharos` member, find_symbol
//// in its note, every other tool as a second text content block (the
//// payload stays block one, as for ADR-032's root attribution). A
//// complete answer has none, and its reply is unchanged. Notes live in
//// the request process's dictionary, so they never cross requests. The
//// question's deadline is kept there too, for the work before it.

import gleam/int
import gleam/option.{type Option, None, Some}

/// Adds a note for the answer this process is building; a repeat of one
/// already added is dropped.
@external(erlang, "pharos_watch_ffi", "notes_add")
pub fn add(note: String) -> Nil

/// Takes this process's notes, leaving none, and forgets its deadline:
/// the answer is done.
@external(erlang, "pharos_watch_ffi", "notes_take")
pub fn take() -> List(String)

/// Records when the question this process is answering times out (a
/// monotonic time in ms), so work before it (the watched-files scan)
/// never runs past it.
@external(erlang, "pharos_watch_ffi", "deadline_set")
pub fn set_deadline(deadline_ms: Int) -> Nil

/// Records the question's timeout, from now.
pub fn set_timeout(timeout_ms: Int) -> Nil {
  set_deadline(now_ms() + timeout_ms)
}

/// Milliseconds left before the question's deadline (0 once past), or
/// None when no deadline was recorded.
pub fn time_left_ms() -> Option(Int) {
  case deadline() {
    Ok(at) -> Some(int.max(at - now_ms(), 0))
    Error(Nil) -> None
  }
}

@external(erlang, "pharos_watch_ffi", "deadline_get")
fn deadline() -> Result(Int, Nil)

@external(erlang, "pharos_watch_ffi", "now_ms")
fn now_ms() -> Int
