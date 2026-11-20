//// ADR-043: the note an unsure answer carries, and the changes sent.

import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import pharos/lsp/watch
import pharos/lsp/watch_scan.{Event, NewOrChanged}
import pharos/lsp/watchers.{Watcher}

pub fn notes_never_say_zero_or_still_scanning_test() {
  [
    watch.FirstPass(3),
    watch.Checked(120, 1400),
    watch.TooSoon,
    watch.NoTime,
    watch.NotChecked,
  ]
  |> list.each(fn(progress) {
    let note = watch.note("/w", progress)
    string.contains(note, "still scanning") |> should.be_false
    string.contains(note, " 0 of") |> should.be_false
    string.contains(note, "of about 0") |> should.be_false
    string.starts_with(
      note,
      "Files changed on disk under /w may not have reached the server yet: ",
    )
    |> should.be_true
  })
  watch.note("/w", watch.Checked(120, 1400))
  |> string.contains("checked 120 of about 1400 directories")
  |> should.be_true
}

pub fn a_first_pass_file_goes_as_created_where_creations_are_watched_test() {
  let events = [Event("/w/gleam.toml", NewOrChanged)]
  // All kinds watched: Created.
  watch.changes_notification([Watcher("**/gleam.toml", None, 7)], events, fn() {
    []
  })
  |> string.join("")
  |> string.contains("\"type\":1")
  |> should.be_true
  // Changes only (gleam-lsp's gleam.toml watcher): Changed.
  watch.changes_notification([Watcher("**/gleam.toml", None, 2)], events, fn() {
    []
  })
  |> string.join("")
  |> string.contains("\"type\":2")
  |> should.be_true
  // Open documents travel as didChange instead.
  watch.changes_notification([Watcher("**/gleam.toml", None, 7)], events, fn() {
    ["/w/gleam.toml"]
  })
  |> should.equal([])
}

@external(erlang, "pharos_watch_ffi", "safe_call")
fn safe_call(f: fn() -> a) -> Result(a, Nil)

pub fn a_call_that_times_out_is_caught_test() {
  // gleam_erlang's process.call raises an error, not an exit, on timeout:
  // it took the question with it (verifier, #10 revision).
  let nobody = process.new_subject()
  safe_call(fn() { process.call(nobody, 10, fn(reply) { reply }) })
  |> should.equal(Error(Nil))
}

fn server(budget_ms: Int, time_left_ms: Option(Int)) -> watch.Server {
  watch.Server(
    proc_pid: process.self(),
    mode: watch.IfRegistered,
    root: "/w",
    skip: [],
    extensions: [],
    budget_ms: budget_ms,
    time_left_ms: time_left_ms,
  )
}

pub fn the_reply_has_time_to_arrive_before_the_deadline_test() {
  // No deadline: the whole budget, and a second's grace for the reply.
  watch.scan_limits(server(200, None)) |> should.equal(#(200, 1200))
  // 50 ms left: the scan gets half, the wait all of it.
  watch.scan_limits(server(200, Some(50))) |> should.equal(#(25, 50))
  // Plenty left: the budget, and the grace.
  watch.scan_limits(server(200, Some(20_000))) |> should.equal(#(200, 1200))
  // Past the deadline: no scan, the shortest wait.
  watch.scan_limits(server(200, Some(0))) |> should.equal(#(0, 1))
}

@external(erlang, "pharos_watch_ffi", "new_alias")
fn new_alias() -> process.Pid

@external(erlang, "pharos_watch_ffi", "drop_alias")
fn drop_alias(alias: process.Pid) -> Nil

@external(erlang, "erlang", "make_ref")
fn new_tag() -> dynamic.Dynamic

pub fn a_reply_after_the_alias_is_dropped_never_arrives_test() {
  let tag = new_tag()
  let alias = new_alias()
  let to_alias: process.Subject(Int) =
    process.unsafely_create_subject(alias, tag)
  let inbox: process.Subject(Int) =
    process.unsafely_create_subject(process.self(), tag)
  process.send(to_alias, 1)
  process.receive(inbox, 100) |> should.equal(Ok(1))
  drop_alias(alias)
  process.send(to_alias, 2)
  process.receive(inbox, 50) |> should.equal(Error(Nil))
}
