//// Tests for the per-(uri, server_id) diagnostics cache (M11).
////
//// Before the rekey, the cache key was bare `uri`, so two LSPs
//// emitting publishDiagnostics for the same file (python = pyright +
//// ruff) would clobber each other and the merge path would surface
//// only one server's items. These tests lock down the new shape.

import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import pharos/lsp/diagnostics_cache

pub fn put_then_get_for_one_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///x.py")

  diagnostics_cache.put("file:///x.py", "pyright", dynamic.string("PY-1"))
  let assert Ok(v) = diagnostics_cache.get("file:///x.py", "pyright")
  v |> should.equal(dynamic.string("PY-1"))
}

pub fn two_servers_same_uri_do_not_clobber_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///x.py")

  diagnostics_cache.put("file:///x.py", "pyright", dynamic.string("PY-A"))
  diagnostics_cache.put("file:///x.py", "ruff", dynamic.string("RUFF-A"))

  let assert Ok(py) = diagnostics_cache.get("file:///x.py", "pyright")
  py |> should.equal(dynamic.string("PY-A"))

  let assert Ok(rf) = diagnostics_cache.get("file:///x.py", "ruff")
  rf |> should.equal(dynamic.string("RUFF-A"))
}

pub fn get_all_for_uri_returns_every_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///y.py")

  diagnostics_cache.put("file:///y.py", "pyright", dynamic.string("a"))
  diagnostics_cache.put("file:///y.py", "ruff", dynamic.string("b"))

  let rows = diagnostics_cache.get_all_for_uri("file:///y.py")
  list.length(rows) |> should.equal(2)
}

pub fn drop_one_server_leaves_other_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///z.py")

  diagnostics_cache.put("file:///z.py", "pyright", dynamic.string("P"))
  diagnostics_cache.put("file:///z.py", "ruff", dynamic.string("R"))

  diagnostics_cache.drop("file:///z.py", "pyright")

  case diagnostics_cache.get("file:///z.py", "pyright") {
    Ok(_) -> panic as { "pyright entry should be dropped" }
    Error(_) -> Nil
  }
  let assert Ok(_) = diagnostics_cache.get("file:///z.py", "ruff")
}

pub fn drop_uri_nukes_every_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///w.py")

  diagnostics_cache.put("file:///w.py", "pyright", dynamic.string("P"))
  diagnostics_cache.put("file:///w.py", "ruff", dynamic.string("R"))

  diagnostics_cache.drop_uri("file:///w.py")

  diagnostics_cache.get_all_for_uri("file:///w.py")
  |> list.length
  |> should.equal(0)
}

// -- ADR-038: freshness against the last sync ---------------------------
//
// The test process stands in for the proc: `put`, `put_publish`,
// `mark_synced` and `mark_closed` key rows by the caller's pid.

pub fn entry_without_a_sync_stamp_is_fresh_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f1.rs")
  let me = process.self()

  diagnostics_cache.put("file:///f1.rs", "ra", dynamic.string("own view"))
  diagnostics_cache.lookup("file:///f1.rs", "ra", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("own view")))
}

pub fn missing_entry_is_missing_even_when_synced_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f2.rs")
  let me = process.self()

  diagnostics_cache.expect("file:///f2.rs", "ra", 1, me)
  diagnostics_cache.mark_synced("file:///f2.rs", "ra", 1)
  diagnostics_cache.lookup("file:///f2.rs", "ra", me)
  |> should.equal(diagnostics_cache.Missing)
}

/// The rust-analyzer shape: a publish for v1, then the file changes and
/// the server publishes nothing (its diagnostics didn't change). The old
/// entry is still there, marked as carried over, not wiped.
pub fn entry_written_before_the_last_sync_is_carried_over_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f3.rs")
  let me = process.self()

  diagnostics_cache.expect("file:///f3.rs", "ra", 1, me)
  diagnostics_cache.mark_synced("file:///f3.rs", "ra", 1)
  diagnostics_cache.put("file:///f3.rs", "ra", dynamic.string("v1"))
  diagnostics_cache.lookup("file:///f3.rs", "ra", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("v1")))

  diagnostics_cache.expect("file:///f3.rs", "ra", 2, me)
  diagnostics_cache.mark_synced("file:///f3.rs", "ra", 2)
  diagnostics_cache.lookup("file:///f3.rs", "ra", me)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("v1")))
}

/// The pool has recorded v2 but the proc hasn't written it yet (it is
/// busy): an entry published after the v1 sync is not fresh for v2.
pub fn a_stamp_behind_the_expected_version_is_not_fresh_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f9.rs")
  let me = process.self()

  diagnostics_cache.expect("file:///f9.rs", "ra", 1, me)
  diagnostics_cache.mark_synced("file:///f9.rs", "ra", 1)
  diagnostics_cache.put("file:///f9.rs", "ra", dynamic.string("v1"))
  diagnostics_cache.expect("file:///f9.rs", "ra", 2, me)
  diagnostics_cache.lookup("file:///f9.rs", "ra", me)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("v1")))
  diagnostics_cache.stamp_status("file:///f9.rs", "ra", 2, me)
  |> should.equal(diagnostics_cache.Pending)
}

pub fn entry_written_after_the_last_sync_is_fresh_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f4.rs")
  let me = process.self()

  diagnostics_cache.put("file:///f4.rs", "ra", dynamic.string("v1"))
  diagnostics_cache.expect("file:///f4.rs", "ra", 2, me)
  diagnostics_cache.mark_synced("file:///f4.rs", "ra", 2)
  diagnostics_cache.put("file:///f4.rs", "ra", dynamic.string("v2"))

  diagnostics_cache.lookup("file:///f4.rs", "ra", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("v2")))
  diagnostics_cache.stamp_status("file:///f4.rs", "ra", 2, me)
  |> should.equal(diagnostics_cache.Reached)
}

/// Syncing one server's copy leaves another server's entry fresh (the
/// python pyright + ruff pair).
pub fn sync_stamps_are_per_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f5.py")
  let me = process.self()

  diagnostics_cache.put("file:///f5.py", "pyright", dynamic.string("P"))
  diagnostics_cache.put("file:///f5.py", "ruff", dynamic.string("R"))
  diagnostics_cache.expect("file:///f5.py", "pyright", 2, me)
  diagnostics_cache.mark_synced("file:///f5.py", "pyright", 2)

  diagnostics_cache.lookup("file:///f5.py", "pyright", me)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("P")))
  diagnostics_cache.lookup("file:///f5.py", "ruff", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("R")))
}

/// Two procs with the same server id holding the same URI (a dependency
/// file opened from two workspaces): their rows don't collide.
pub fn rows_are_per_proc_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///dep.rs")
  let me = process.self()
  let other = process.spawn_unlinked(fn() { process.sleep(5000) })

  diagnostics_cache.expect("file:///dep.rs", "ra", 1, me)
  diagnostics_cache.mark_synced("file:///dep.rs", "ra", 1)
  diagnostics_cache.put("file:///dep.rs", "ra", dynamic.string("mine"))
  diagnostics_cache.expect("file:///dep.rs", "ra", 4, other)

  diagnostics_cache.lookup("file:///dep.rs", "ra", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("mine")))
  diagnostics_cache.lookup("file:///dep.rs", "ra", other)
  |> should.equal(diagnostics_cache.Missing)
  diagnostics_cache.stamp_status("file:///dep.rs", "ra", 1, other)
  |> should.equal(diagnostics_cache.Pending)
  process.kill(other)
}

pub fn publish_older_than_the_synced_version_is_not_stored_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f6.py")
  let me = process.self()

  diagnostics_cache.mark_synced("file:///f6.py", "pyright", 1)
  diagnostics_cache.put_publish(
    "file:///f6.py",
    "pyright",
    Some(1),
    dynamic.string("v1"),
  )
  diagnostics_cache.expect("file:///f6.py", "pyright", 2, me)
  diagnostics_cache.mark_synced("file:///f6.py", "pyright", 2)
  // A late publish that admits to being about v1, read after the v2
  // sync was written.
  diagnostics_cache.put_publish(
    "file:///f6.py",
    "pyright",
    Some(1),
    dynamic.string("late v1"),
  )

  diagnostics_cache.lookup("file:///f6.py", "pyright", me)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("v1")))
}

pub fn publish_at_the_synced_version_or_without_one_is_stored_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f7.py")
  let me = process.self()

  diagnostics_cache.expect("file:///f7.py", "pyright", 3, me)
  diagnostics_cache.mark_synced("file:///f7.py", "pyright", 3)
  diagnostics_cache.put_publish(
    "file:///f7.py",
    "pyright",
    Some(3),
    dynamic.string("v3"),
  )
  diagnostics_cache.lookup("file:///f7.py", "pyright", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("v3")))

  diagnostics_cache.put_publish(
    "file:///f7.py",
    "pyright",
    None,
    dynamic.string("unversioned"),
  )
  diagnostics_cache.lookup("file:///f7.py", "pyright", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("unversioned")))
}

pub fn a_failed_write_is_visible_to_waiters_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f10.rs")
  let me = process.self()

  diagnostics_cache.expect("file:///f10.rs", "ra", 3, me)
  diagnostics_cache.mark_failed("file:///f10.rs", "ra")
  diagnostics_cache.stamp_status("file:///f10.rs", "ra", 3, me)
  |> should.equal(diagnostics_cache.Failed)
}

/// Another session's LRU closed the document while this caller waited
/// on an earlier sync of it: the close counts as reached.
pub fn a_close_ends_the_wait_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f11.rs")
  let me = process.self()

  diagnostics_cache.expect("file:///f11.rs", "ra", 5, me)
  diagnostics_cache.stamp_status("file:///f11.rs", "ra", 5, me)
  |> should.equal(diagnostics_cache.Pending)
  diagnostics_cache.mark_closed("file:///f11.rs", "ra")
  diagnostics_cache.stamp_status("file:///f11.rs", "ra", 5, me)
  |> should.equal(diagnostics_cache.Reached)
}

pub fn forget_proc_drops_its_rows_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///f8.rs")
  let me = process.self()

  diagnostics_cache.expect("file:///f8.rs", "ra", 4, me)
  diagnostics_cache.mark_synced("file:///f8.rs", "ra", 4)
  diagnostics_cache.put("file:///f8.rs", "ra", dynamic.string("x"))
  diagnostics_cache.forget_proc(me)
  diagnostics_cache.lookup("file:///f8.rs", "ra", me)
  |> should.equal(diagnostics_cache.Missing)
  diagnostics_cache.stamp_status("file:///f8.rs", "ra", 4, me)
  |> should.equal(diagnostics_cache.Pending)
}

/// a.ts didn't change, but b.ts (which it imports) did: a.ts's entry
/// from before the batch is carried over too.
pub fn any_batch_on_the_proc_carries_every_earlier_entry_over_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///a.ts")
  diagnostics_cache.drop_uri("file:///b.ts")
  let me = process.self()

  diagnostics_cache.expect_batch(me, 1)
  diagnostics_cache.mark_batch(1)
  diagnostics_cache.expect("file:///a.ts", "tsls", 1, me)
  diagnostics_cache.mark_synced("file:///a.ts", "tsls", 1)
  diagnostics_cache.put("file:///a.ts", "tsls", dynamic.string("a@1"))
  diagnostics_cache.lookup("file:///a.ts", "tsls", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("a@1")))

  // Batch 2 re-syncs only b.ts; the pool has sent it, the proc not yet.
  diagnostics_cache.expect_batch(me, 2)
  diagnostics_cache.expect("file:///b.ts", "tsls", 2, me)
  diagnostics_cache.lookup("file:///a.ts", "tsls", me)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("a@1")))

  // Written: inside the batch's settle window, still carried over until
  // the server republishes a.ts.
  diagnostics_cache.mark_batch(2)
  diagnostics_cache.mark_synced("file:///b.ts", "tsls", 2)
  diagnostics_cache.lookup("file:///a.ts", "tsls", me)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("a@1")))

  diagnostics_cache.put("file:///a.ts", "tsls", dynamic.string("a after b@2"))
  diagnostics_cache.lookup("file:///a.ts", "tsls", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("a after b@2")))
  diagnostics_cache.forget_proc(me)
}

/// F2 (gopls): the server never republishes a file whose diagnostics
/// didn't change, so an entry from before another document's change
/// would stay carried over for good. Past the batch's settle window it
/// is fresh, and a later question does not wait again.
pub fn past_the_settle_window_an_unchanged_document_is_fresh_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///a.go")
  let me = process.self()

  diagnostics_cache.expect("file:///a.go", "gopls", 1, me)
  diagnostics_cache.mark_synced("file:///a.go", "gopls", 1)
  diagnostics_cache.put("file:///a.go", "gopls", dynamic.string("a@1"))
  // Another document opened or changed: batch 7, written.
  diagnostics_cache.expect_batch(me, 7)
  diagnostics_cache.mark_batch(7)

  diagnostics_cache.lookup_within("file:///a.go", "gopls", me, 60_000)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("a@1")))
  let left = diagnostics_cache.settle_left_within(me, 60_000)
  { left > 0 && left <= 60_000 } |> should.be_true

  diagnostics_cache.lookup_within("file:///a.go", "gopls", me, 0)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("a@1")))
  diagnostics_cache.settle_left_within(me, 0) |> should.equal(0)
  diagnostics_cache.forget_proc(me)
}

/// The window settles other documents' changes only: an entry from
/// before the document's own latest sync stays carried over (the server
/// has said nothing about the text it has now).
pub fn a_documents_own_change_stays_carried_over_past_the_window_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///own.go")
  let me = process.self()

  diagnostics_cache.put("file:///own.go", "gopls", dynamic.string("v1"))
  diagnostics_cache.expect_batch(me, 8)
  diagnostics_cache.expect("file:///own.go", "gopls", 2, me)
  diagnostics_cache.mark_batch(8)
  diagnostics_cache.mark_synced("file:///own.go", "gopls", 2)
  diagnostics_cache.lookup_within("file:///own.go", "gopls", me, 0)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("v1")))
  diagnostics_cache.forget_proc(me)
}

/// A batch the proc has not written yet never settles: the server has
/// not seen it. Its window is a full one from now.
pub fn an_unwritten_batch_never_settles_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///w.go")
  let me = process.self()

  diagnostics_cache.put("file:///w.go", "gopls", dynamic.string("w"))
  diagnostics_cache.expect_batch(me, 9)
  diagnostics_cache.lookup_within("file:///w.go", "gopls", me, 0)
  |> should.equal(diagnostics_cache.CarriedOver(dynamic.string("w")))
  diagnostics_cache.settle_left_within(me, 500) |> should.equal(500)
  diagnostics_cache.forget_proc(me)
}

/// F1: the file asked about was deleted, so pharos closes it. What the
/// server said about the old text is never served again; a publish
/// after the close is.
pub fn entries_from_before_a_close_are_not_served_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///gone.ts")
  let me = process.self()

  diagnostics_cache.expect("file:///gone.ts", "tsls", 3, me)
  diagnostics_cache.mark_synced("file:///gone.ts", "tsls", 3)
  diagnostics_cache.put("file:///gone.ts", "tsls", dynamic.string("old text"))
  diagnostics_cache.lookup("file:///gone.ts", "tsls", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("old text")))

  // Close recorded by the pool, not yet written by the proc.
  diagnostics_cache.expect_closed("file:///gone.ts", "tsls", me)
  diagnostics_cache.lookup("file:///gone.ts", "tsls", me)
  |> should.equal(diagnostics_cache.Missing)
  diagnostics_cache.close_status("file:///gone.ts", "tsls", 3, me)
  |> should.equal(diagnostics_cache.Pending)

  diagnostics_cache.mark_closed("file:///gone.ts", "tsls")
  diagnostics_cache.close_status("file:///gone.ts", "tsls", 3, me)
  |> should.equal(diagnostics_cache.Reached)
  diagnostics_cache.lookup("file:///gone.ts", "tsls", me)
  |> should.equal(diagnostics_cache.Missing)

  diagnostics_cache.put("file:///gone.ts", "tsls", dynamic.string("[]"))
  diagnostics_cache.lookup("file:///gone.ts", "tsls", me)
  |> should.equal(diagnostics_cache.Fresh(dynamic.string("[]")))
  diagnostics_cache.forget_proc(me)
}

/// A close that another session's question overtook with a reopen
/// still ends the wait: the reopen is written after the close.
pub fn a_reopen_after_the_close_ends_the_close_wait_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///re.ts")
  let me = process.self()

  diagnostics_cache.mark_synced("file:///re.ts", "tsls", 3)
  diagnostics_cache.close_status("file:///re.ts", "tsls", 3, me)
  |> should.equal(diagnostics_cache.Pending)
  diagnostics_cache.mark_synced("file:///re.ts", "tsls", 4)
  diagnostics_cache.close_status("file:///re.ts", "tsls", 3, me)
  |> should.equal(diagnostics_cache.Reached)
  diagnostics_cache.forget_proc(me)
}
