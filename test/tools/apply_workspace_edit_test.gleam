//// Tests for `pharos/tools/apply_workspace_edit`.
////
//// Cover three layers:
////   1. Pure FFI splice (`apply_text_edits/2`): single, multi, overlap,
////      deletion, append-at-EOF, multi-line replacement.
////   2. End-to-end `handle/2` driving disk writes through the tool's
////      WorkspaceEdit decoder. Uses a temp dir per test.
////   3. Dry-run / safety: dry_run defaults to true; non-file URIs
////      rejected; bad WorkspaceEdit shape decoded with a clear error.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import pharos/tools/apply_workspace_edit

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_fs_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "pharos_apply_edit_ffi", "apply_text_edits")
fn apply_text_edits(
  bytes: BitArray,
  edits: List(#(Int, Int, Int, Int, String)),
) -> Result(BitArray, Dynamic)

// -- pure transform layer ------------------------------------------------

pub fn splice_single_word_test() {
  let assert Ok(out) =
    apply_text_edits(<<"hello world\n":utf8>>, [#(0, 6, 0, 11, "WORLD")])
  out
  |> should.equal(<<"hello WORLD\n":utf8>>)
}

pub fn splice_multi_descending_test() {
  // Two non-overlapping edits on same line. FFI sorts descending so
  // splice order does not matter for the caller.
  let assert Ok(out) =
    apply_text_edits(
      <<"foo bar baz\n":utf8>>,
      [#(0, 4, 0, 7, "BAR"), #(0, 8, 0, 11, "BAZ")],
    )
  out
  |> should.equal(<<"foo BAR BAZ\n":utf8>>)
}

pub fn splice_deletion_test() {
  // Delete 'bar ' from middle of line.
  let assert Ok(out) =
    apply_text_edits(<<"foo bar baz\n":utf8>>, [#(0, 4, 0, 8, "")])
  out
  |> should.equal(<<"foo baz\n":utf8>>)
}

pub fn splice_multi_line_replacement_test() {
  // Replace lines 1-2 with single "X".
  let assert Ok(out) =
    apply_text_edits(<<"a\nb\nc\nd\n":utf8>>, [#(1, 0, 3, 0, "X\n")])
  out
  |> should.equal(<<"a\nX\nd\n":utf8>>)
}

pub fn splice_append_at_eof_test() {
  // LSP allows pointing one past the last line for inserts at EOF.
  // line=2 in a 2-line file.
  let assert Ok(out) =
    apply_text_edits(<<"a\nb\n":utf8>>, [#(2, 0, 2, 0, "c\n")])
  out
  |> should.equal(<<"a\nb\nc\n":utf8>>)
}

pub fn splice_overlap_rejected_test() {
  let assert Error(_) =
    apply_text_edits(
      <<"hello world\n":utf8>>,
      [#(0, 0, 0, 5, "X"), #(0, 3, 0, 8, "Y")],
    )
}

// -- end-to-end handle/2 over disk ---------------------------------------

const tmp_root: String = "/tmp/pharos-apply-edit-test"

fn setup() -> String {
  let _ = shell("rm -rf " <> tmp_root)
  let _ = shell("mkdir -p " <> tmp_root)
  tmp_root
}

fn teardown() {
  let _ = shell("rm -rf " <> tmp_root)
  Nil
}

fn parse_dynamic(raw: String) -> Dynamic {
  let assert Ok(value) = json.parse(raw, decode.dynamic)
  value
}

pub fn handle_dry_run_does_not_write_test() {
  let _ = setup()
  let path = tmp_root <> "/a.txt"
  let _ = shell("printf 'hello world' > " <> path)

  let edit =
    parse_dynamic(
      "{\"changes\":{\"file://"
      <> path
      <> "\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}},\"newText\":\"WORLD\"}]}}",
    )
  let assert Ok(summary) = apply_workspace_edit.handle(edit, True)

  // Dry run header present.
  case summary {
    "Dry run" <> _ -> Nil
    _ -> panic as { "expected dry run header, got: " <> summary }
  }

  // Bytes on disk unchanged.
  let assert Ok(bits) = read_file(path)
  bits
  |> should.equal(<<"hello world":utf8>>)

  teardown()
}

pub fn handle_apply_writes_to_disk_test() {
  let _ = setup()
  let path = tmp_root <> "/b.txt"
  let _ = shell("printf 'hello world' > " <> path)

  let edit =
    parse_dynamic(
      "{\"changes\":{\"file://"
      <> path
      <> "\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}},\"newText\":\"WORLD\"}]}}",
    )
  let assert Ok(_summary) = apply_workspace_edit.handle(edit, False)

  let assert Ok(bits) = read_file(path)
  bits
  |> should.equal(<<"hello WORLD":utf8>>)

  teardown()
}

pub fn handle_rejects_non_file_uri_test() {
  let edit =
    parse_dynamic(
      "{\"changes\":{\"untitled:///scratch\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"x\"}]}}",
    )
  let assert Error(apply_workspace_edit.InvalidUris(reason)) =
    apply_workspace_edit.handle(edit, True)
  case reason {
    "non-file://" <> _ -> Nil
    _ -> panic as { "unexpected reason: " <> reason }
  }
}

pub fn handle_decodes_document_changes_form_test() {
  let _ = setup()
  let path = tmp_root <> "/c.txt"
  let _ = shell("printf 'foo\\n' > " <> path)

  let edit =
    parse_dynamic(
      "{\"documentChanges\":[{\"textDocument\":{\"uri\":\"file://"
      <> path
      <> "\",\"version\":1},\"edits\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"newText\":\"BAR\"}]}]}",
    )
  let assert Ok(_summary) = apply_workspace_edit.handle(edit, False)

  let assert Ok(bits) = read_file(path)
  bits
  |> should.equal(<<"BAR\n":utf8>>)

  teardown()
}
