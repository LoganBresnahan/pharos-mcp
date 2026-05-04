//// Tests for `pharos/tools/workspace_edit` — the WorkspaceEdit
//// renderer used by Tier 2 edit-as-data tools.

import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import pharos/tools/workspace_edit

// -- changes form (Dict<URI, TextEdit[]>) ---------------------------------

pub fn render_single_changes_edit_test() {
  let raw =
    "{\"changes\":{\"file:///foo.rs\":[{\"range\":{\"start\":{\"line\":10,\"character\":4},\"end\":{\"line\":10,\"character\":7}},\"newText\":\"bar\"}]}}"

  let assert Ok(value) = json.parse(raw, decode.dynamic)
  let assert Ok(rendered) = workspace_edit.render(value)

  rendered
  |> should.equal(
    "=== file:///foo.rs ===\n@@ 10:4-10:7 @@\n+ bar",
  )
}

// -- documentChanges form -------------------------------------------------

pub fn render_document_changes_form_test() {
  let raw =
    "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file:///bar.rs\",\"version\":1},\"edits\":[{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":0}},\"newText\":\"// added\\n\"}]}]}"

  let assert Ok(value) = json.parse(raw, decode.dynamic)
  let assert Ok(rendered) = workspace_edit.render(value)

  rendered
  |> should.equal(
    "=== file:///bar.rs ===\n@@ 2:0-2:0 @@\n+ // added\n+ ",
  )
}

// -- empty WorkspaceEdit (rust-analyzer no-op rename) --------------------

pub fn render_empty_workspace_edit_test() {
  let assert Ok(value) = json.parse("{}", decode.dynamic)
  let assert Ok(rendered) = workspace_edit.render(value)

  rendered
  |> should.equal("(empty WorkspaceEdit — no changes proposed)")
}

// -- deletion (empty newText) --------------------------------------------

pub fn render_deletion_test() {
  let raw =
    "{\"changes\":{\"file:///x.rs\":[{\"range\":{\"start\":{\"line\":5,\"character\":0},\"end\":{\"line\":6,\"character\":0}},\"newText\":\"\"}]}}"

  let assert Ok(value) = json.parse(raw, decode.dynamic)
  let assert Ok(rendered) = workspace_edit.render(value)

  rendered
  |> should.equal(
    "=== file:///x.rs ===\n@@ 5:0-6:0 @@\n(deletion — no replacement text)",
  )
}

// -- malformed input -----------------------------------------------------

pub fn render_non_workspace_edit_returns_error_test() {
  let assert Ok(value) = json.parse("[1, 2, 3]", decode.dynamic)
  let result = workspace_edit.render(value)

  case result {
    Error(workspace_edit.DecodeError(_)) -> Nil
    _ -> should.fail()
  }
}
