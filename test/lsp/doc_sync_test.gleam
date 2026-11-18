//// ADR-038: what a question about a file sends its server first, and
//// how the server's `textDocumentSync` capability shapes it.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleeunit/should
import pharos/lsp/doc_sync.{
  Change, Close, DocState, Gone, NoSave, OnDisk, OpChange, OpClose, OpOpen, Open,
  Save, SaveWithText, SyncCaps, Unchanged,
}

fn caps(capabilities_json: String) -> doc_sync.SyncCaps {
  let assert Ok(value) = json.parse(capabilities_json, decode.dynamic)
  doc_sync.caps_from_capabilities(value)
}

fn methods(bodies: List(String)) -> List(String) {
  list.map(bodies, fn(body) {
    let assert Ok(method) =
      json.parse(body, decode.field("method", decode.string, decode.success))
    method
  })
}

// -- plan --------------------------------------------------------------

fn on_disk(text: String) -> doc_sync.DiskState {
  OnDisk(text, doc_sync.content_hash(text))
}

pub fn a_document_never_sent_is_opened_at_1_test() {
  doc_sync.plan_subject(Error(Nil), on_disk("a"))
  |> should.equal(Open(1))
}

pub fn the_same_text_sends_nothing_test() {
  let hash = doc_sync.content_hash("fn main() {}")
  doc_sync.plan_subject(
    Ok(DocState(version: 3, hash:, open: True)),
    on_disk("fn main() {}"),
  )
  |> should.equal(Unchanged)
}

pub fn changed_text_resyncs_at_the_next_version_test() {
  let sent = doc_sync.content_hash("v1")
  doc_sync.plan_subject(
    Ok(DocState(version: 3, hash: sent, open: True)),
    on_disk("v2"),
  )
  |> should.equal(Change(4))
}

/// A closed document reopens at the next version, never back at 1, so
/// a late publish about the old text can't pass the version filter.
pub fn a_closed_document_reopens_at_the_next_version_test() {
  let hash = doc_sync.content_hash("same")
  doc_sync.plan_subject(
    Ok(DocState(version: 7, hash:, open: False)),
    on_disk("same"),
  )
  |> should.equal(Open(8))
}

/// The file asked about was deleted while open: close it, so the server
/// goes back to the disk and answers as for a file that never existed.
pub fn a_subject_whose_file_is_gone_is_closed_test() {
  doc_sync.plan_subject(
    Ok(DocState(version: 4, hash: doc_sync.content_hash("old"), open: True)),
    Gone,
  )
  |> should.equal(Close)
}

/// A gone file that pharos does not hold open is never opened.
pub fn a_subject_whose_file_is_gone_and_not_open_sends_nothing_test() {
  doc_sync.plan_subject(Error(Nil), Gone)
  |> should.equal(Unchanged)
  doc_sync.plan_subject(
    Ok(DocState(version: 4, hash: doc_sync.content_hash("old"), open: False)),
    Gone,
  )
  |> should.equal(Unchanged)
}

pub fn another_open_document_that_changed_is_resynced_test() {
  let state =
    DocState(version: 2, hash: doc_sync.content_hash("old"), open: True)
  doc_sync.plan_open(state, OnDisk("new", doc_sync.content_hash("new")))
  |> should.equal(Change(3))
  doc_sync.plan_open(state, OnDisk("old", doc_sync.content_hash("old")))
  |> should.equal(Unchanged)
}

pub fn another_open_document_whose_file_is_gone_is_closed_test() {
  DocState(version: 2, hash: doc_sync.content_hash("old"), open: True)
  |> doc_sync.plan_open(Gone)
  |> should.equal(Close)
}

pub fn lru_closes_the_least_recently_used_but_never_the_subject_test() {
  doc_sync.lru_victims(
    [#("a", 5), #("subject", 1), #("b", 2), #("c", 9)],
    "subject",
    2,
  )
  |> should.equal(["b", "a"])
  doc_sync.lru_victims([#("a", 1), #("b", 2)], "a", 2)
  |> should.equal([])
}

// -- capabilities ------------------------------------------------------

pub fn sync_left_out_is_none_test() {
  caps("{\"hoverProvider\":true}")
  |> should.equal(SyncCaps(change: 0, save: NoSave, open_close: False))
}

pub fn number_form_full_also_saves_test() {
  caps("{\"textDocumentSync\":1}")
  |> should.equal(SyncCaps(change: 1, save: Save, open_close: True))
}

pub fn number_form_none_does_not_save_test() {
  caps("{\"textDocumentSync\":0}")
  |> should.equal(SyncCaps(change: 0, save: NoSave, open_close: False))
}

pub fn options_form_reads_change_and_save_test() {
  caps("{\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":{}}}")
  |> should.equal(SyncCaps(change: 2, save: Save, open_close: True))
}

pub fn options_form_include_text_test() {
  caps("{\"textDocumentSync\":{\"change\":1,\"save\":{\"includeText\":true}}}")
  |> should.equal(SyncCaps(change: 1, save: SaveWithText, open_close: False))
}

pub fn options_form_save_false_or_absent_test() {
  caps("{\"textDocumentSync\":{\"change\":2,\"save\":false}}")
  |> should.equal(SyncCaps(change: 2, save: NoSave, open_close: False))
  caps("{\"textDocumentSync\":{\"change\":2}}")
  |> should.equal(SyncCaps(change: 2, save: NoSave, open_close: False))
}

pub fn options_form_without_change_is_none_test() {
  caps("{\"textDocumentSync\":{\"openClose\":true}}")
  |> should.equal(SyncCaps(change: 0, save: NoSave, open_close: True))
}

// -- notifications -----------------------------------------------------

const full_save = SyncCaps(change: 2, save: Save, open_close: True)

pub fn opening_sends_did_open_at_the_given_version_test() {
  let bodies =
    doc_sync.notifications(
      full_save,
      OpOpen("file:///a.rs", "rust", 1, "fn a() {}"),
    )
  methods(bodies) |> should.equal(["textDocument/didOpen"])
  let assert [body] = bodies
  let assert Ok(#(version, text)) =
    json.parse(body, {
      use version <- decode.subfield(
        ["params", "textDocument", "version"],
        decode.int,
      )
      use text <- decode.subfield(
        ["params", "textDocument", "text"],
        decode.string,
      )
      decode.success(#(version, text))
    })
  #(version, text) |> should.equal(#(1, "fn a() {}"))
}

/// pharos opens what it asks about even when the server says it wants
/// no open/close (today's behaviour, kept until the capability survey).
pub fn opening_ignores_open_close_false_test() {
  doc_sync.notifications(
    SyncCaps(change: 0, save: NoSave, open_close: False),
    OpOpen("file:///a.x", "x", 1, "t"),
  )
  |> methods
  |> should.equal(["textDocument/didOpen"])
}

/// One full-text change: exactly one content change, carrying only
/// `text` (no `range`, no `rangeLength`), even for an Incremental server.
pub fn a_change_is_one_full_text_event_then_save_test() {
  let bodies =
    doc_sync.notifications(
      full_save,
      OpChange("file:///a.rs", "rust", 5, "line \"quoted\"\n"),
    )
  methods(bodies)
  |> should.equal(["textDocument/didChange", "textDocument/didSave"])
  let assert [change, save] = bodies
  let assert Ok(#(version, changes)) =
    json.parse(change, {
      use version <- decode.subfield(
        ["params", "textDocument", "version"],
        decode.int,
      )
      use changes <- decode.subfield(
        ["params", "contentChanges"],
        decode.list(decode.dict(decode.string, decode.string)),
      )
      decode.success(#(version, changes))
    })
  version |> should.equal(5)
  let assert [only] = changes
  only
  |> should.equal(
    json.parse(
      "{\"text\":\"line \\\"quoted\\\"\\n\"}",
      decode.dict(decode.string, decode.string),
    )
    |> unwrap,
  )
  // A plain save carries no text.
  json.parse(
    save,
    decode.subfield(["params", "text"], decode.string, decode.success),
  )
  |> should.be_error
}

pub fn save_with_text_carries_the_text_test() {
  let assert [_, save] =
    doc_sync.notifications(
      SyncCaps(change: 1, save: SaveWithText, open_close: True),
      OpChange("file:///a.py", "python", 2, "x = 1\n"),
    )
  json.parse(
    save,
    decode.subfield(["params", "text"], decode.string, decode.success),
  )
  |> should.equal(Ok("x = 1\n"))
}

pub fn no_save_means_change_only_test() {
  doc_sync.notifications(
    SyncCaps(change: 1, save: NoSave, open_close: True),
    OpChange("file:///a.go", "go", 2, "package a\n"),
  )
  |> methods
  |> should.equal(["textDocument/didChange"])
}

/// Sync kind None with openClose: close, then open at the new version.
pub fn sync_kind_none_with_open_close_closes_and_reopens_test() {
  let bodies =
    doc_sync.notifications(
      SyncCaps(change: 0, save: NoSave, open_close: True),
      OpChange("file:///a.x", "x", 4, "new"),
    )
  methods(bodies)
  |> should.equal(["textDocument/didClose", "textDocument/didOpen"])
  let assert [_, reopen] = bodies
  json.parse(
    reopen,
    decode.subfield(
      ["params", "textDocument", "version"],
      decode.int,
      decode.success,
    ),
  )
  |> should.equal(Ok(4))
}

/// Sync kind None without openClose: pharos opened it anyway, so it
/// mirrors that with a balanced close + reopen.
pub fn sync_kind_none_without_open_close_still_closes_and_reopens_test() {
  doc_sync.notifications(
    SyncCaps(change: 0, save: NoSave, open_close: False),
    OpChange("file:///a.x", "x", 2, "new"),
  )
  |> methods
  |> should.equal(["textDocument/didClose", "textDocument/didOpen"])
}

pub fn options_form_save_true_is_a_plain_save_test() {
  caps("{\"textDocumentSync\":{\"change\":1,\"save\":true}}")
  |> should.equal(SyncCaps(change: 1, save: Save, open_close: False))
}

pub fn close_sends_did_close_test() {
  doc_sync.notifications(full_save, OpClose("file:///a.rs"))
  |> methods
  |> should.equal(["textDocument/didClose"])
}

fn unwrap(r: Result(a, e)) -> a {
  let assert Ok(v) = r
  v
}
