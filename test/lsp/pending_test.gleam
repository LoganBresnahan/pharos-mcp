//// Tests for `pharos/lsp/pending`.
////
//// Pure data structure — no processes spawned in tests. Subjects are
//// constructed via `process.new_subject/0` because the tracker holds
//// them by value.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit/should
import pharos/lsp/pending

pub fn new_is_empty_test() {
  pending.new()
  |> pending.is_empty
  |> should.be_true
}

pub fn new_size_is_zero_test() {
  pending.new()
  |> pending.size
  |> should.equal(0)
}

pub fn register_increments_size_test() {
  pending.new()
  |> pending.register(1, process.new_subject())
  |> pending.register(2, process.new_subject())
  |> pending.size
  |> should.equal(2)
}

pub fn take_returns_registered_subject_test() {
  let subject = process.new_subject()
  let p =
    pending.new()
    |> pending.register(42, subject)

  let #(result, _p) = pending.take(p, 42)
  result |> should.equal(Ok(subject))
}

pub fn take_removes_entry_test() {
  let p =
    pending.new()
    |> pending.register(1, process.new_subject())

  let #(_, p) = pending.take(p, 1)
  p |> pending.is_empty |> should.be_true
}

pub fn take_unknown_id_returns_error_test() {
  let p = pending.new()
  let #(result, _p) = pending.take(p, 99)
  result |> should.equal(Error(Nil))
}

pub fn take_unknown_id_does_not_modify_state_test() {
  let p =
    pending.new()
    |> pending.register(1, process.new_subject())

  let #(_, p_after) = pending.take(p, 99)
  p_after |> pending.size |> should.equal(1)
}

pub fn registering_same_id_twice_replaces_test() {
  let first = process.new_subject()
  let second = process.new_subject()
  let p =
    pending.new()
    |> pending.register(7, first)
    |> pending.register(7, second)

  let #(result, _p) = pending.take(p, 7)
  result |> should.equal(Ok(second))
}

pub fn ids_lists_registered_keys_test() {
  let p =
    pending.new()
    |> pending.register(1, process.new_subject())
    |> pending.register(2, process.new_subject())
    |> pending.register(3, process.new_subject())

  let ids = pending.ids(p) |> list.sort(by: int.compare)
  ids |> should.equal([1, 2, 3])
}
