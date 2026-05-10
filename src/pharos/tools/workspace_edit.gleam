//// `WorkspaceEdit` rendering helpers.
////
//// Tools that return LSP `WorkspaceEdit` results (`rename_preview`,
//// `format_document`, `code_actions` — Stage 1B) format the edit
//// for the LLM via this module. Output is a human-readable summary
//// listing every edit grouped by URI, with each edit's range and
//// the replacement text. Never writes to disk — see the edit-as-
//// data philosophy in `doc/init.md` § Tool surface.
////
//// Handles both `changes` (Dict<URI, TextEdit[]>) and
//// `documentChanges` (TextDocumentEdit[]) forms of WorkspaceEdit;
//// callers can pass either shape and the renderer normalises.
////
//// True unified-diff output (with surrounding-context lines from
//// the on-disk file) is M8 Stage 2 follow-up. The summary form
//// lands first because it is sufficient for LLM review of the
//// proposed edit and does not require reading file contents off
//// disk inside the tool path.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type TextEdit {
  TextEdit(
    start_line: Int,
    start_character: Int,
    end_line: Int,
    end_character: Int,
    new_text: String,
  )
}

pub type FileEdits {
  FileEdits(uri: String, edits: List(TextEdit))
}

pub type RenderError {
  DecodeError(reason: String)
}

/// Decode a `WorkspaceEdit` Dynamic (typically the `result` field
/// of an LSP rename / formatting / code-action response) into a
/// list of `FileEdits` ready for rendering. Returns an empty list
/// when the WorkspaceEdit has neither `changes` nor `documentChanges`
/// (rust-analyzer in particular sometimes returns `{}` for a no-op
/// rename), AND when the value is JSON `null` — metals + several
/// other LSPs signal "no rename here" with a `null` response per
/// LSP spec ("the request is sent from the client to the server to
/// rename a symbol [...] response: WorkspaceEdit | null"). Surfaced
/// by the M13 23-lang dogfood: `rename_preview` against bash, scala,
/// lua, gleam targets where the position has no rename target.
///
/// Strict mode is used by `apply_workspace_edit` which receives a
/// user-supplied edit body; silently dropping a malformed request
/// would write nothing while telling the LLM we wrote nothing,
/// which is misleading. Read-side renderers (`render/1` below) use
/// the lenient form because their caller is the LSP server, not
/// untrusted input.
pub fn decode(value: Dynamic) -> Result(List(FileEdits), RenderError) {
  case decode.run(value, workspace_edit_decoder()) {
    Ok(edits) -> Ok(edits)
    Error(_) ->
      Error(DecodeError(
        "expected WorkspaceEdit shape (changes or documentChanges)",
      ))
  }
}

/// Lenient variant of `decode/1` used by read-side renderers that
/// consume LSP-server replies. Treats JSON `null` and any
/// non-conforming shape as "no edits proposed" and returns `Ok([])`.
/// Use this when the caller is `rename_preview` / `format_document`
/// (server-as-source); `apply_workspace_edit` keeps the strict
/// `decode/1` because its input is user-supplied JSON.
pub fn decode_lenient(value: Dynamic) -> Result(List(FileEdits), RenderError) {
  case decode.run(value, workspace_edit_decoder()) {
    Ok(edits) -> Ok(edits)
    Error(_) -> Ok([])
  }
}

/// Render a `WorkspaceEdit` Dynamic as a human-readable summary
/// string. Convenience wrapper around `decode/1` + `render_edits/1`.
pub fn render(value: Dynamic) -> Result(String, RenderError) {
  use edits <- result.try(decode(value))
  Ok(render_edits(edits))
}

/// Lenient render — pairs with `decode_lenient/1`. Use when the
/// `value` is an LSP-server reply where `null` / `{}` should be
/// rendered as the empty-edit summary rather than surfaced as a
/// decode error.
pub fn render_lenient(value: Dynamic) -> String {
  let assert Ok(edits) = decode_lenient(value)
  render_edits(edits)
}

/// Render a list of `FileEdits` (already decoded) as the summary
/// text. Exposed separately so tools that want to inspect or
/// transform the structured form before rendering can do so.
pub fn render_edits(edits: List(FileEdits)) -> String {
  case edits {
    [] -> "(empty WorkspaceEdit — no changes proposed)"
    _ ->
      edits
      |> list.map(render_file_edits)
      |> string.join("\n\n")
  }
}

fn render_file_edits(file: FileEdits) -> String {
  let header = "=== " <> file.uri <> " ==="
  let rendered_edits =
    file.edits
    |> list.map(render_text_edit)
    |> string.join("\n\n")

  header <> "\n" <> rendered_edits
}

fn render_text_edit(edit: TextEdit) -> String {
  let range_label =
    "@@ "
    <> int.to_string(edit.start_line)
    <> ":"
    <> int.to_string(edit.start_character)
    <> "-"
    <> int.to_string(edit.end_line)
    <> ":"
    <> int.to_string(edit.end_character)
    <> " @@"

  let replacement_lines =
    edit.new_text
    |> string.split("\n")
    |> list.map(fn(line) { "+ " <> line })
    |> string.join("\n")

  case edit.new_text {
    "" -> range_label <> "\n(deletion — no replacement text)"
    _ -> range_label <> "\n" <> replacement_lines
  }
}

// -- Decoders -----------------------------------------------------------

fn workspace_edit_decoder() -> decode.Decoder(List(FileEdits)) {
  use changes <- decode.optional_field(
    "changes",
    [],
    changes_decoder(),
  )
  use document_changes <- decode.optional_field(
    "documentChanges",
    [],
    document_changes_decoder(),
  )

  decode.success(list.append(changes, document_changes))
}

fn changes_decoder() -> decode.Decoder(List(FileEdits)) {
  decode.dict(decode.string, decode.list(text_edit_decoder()))
  |> decode.map(dict_to_file_edits)
}

fn dict_to_file_edits(d: Dict(String, List(TextEdit))) -> List(FileEdits) {
  d
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(uri, edits) = pair
    FileEdits(uri: uri, edits: edits)
  })
}

fn document_changes_decoder() -> decode.Decoder(List(FileEdits)) {
  decode.list({
    use uri <- decode.subfield(["textDocument", "uri"], decode.string)
    use edits <- decode.field("edits", decode.list(text_edit_decoder()))
    decode.success(FileEdits(uri: uri, edits: edits))
  })
}

fn text_edit_decoder() -> decode.Decoder(TextEdit) {
  use start_line <- decode.subfield(["range", "start", "line"], decode.int)
  use start_character <- decode.subfield(
    ["range", "start", "character"],
    decode.int,
  )
  use end_line <- decode.subfield(["range", "end", "line"], decode.int)
  use end_character <- decode.subfield(
    ["range", "end", "character"],
    decode.int,
  )
  use new_text <- decode.field("newText", decode.string)
  decode.success(TextEdit(
    start_line: start_line,
    start_character: start_character,
    end_line: end_line,
    end_character: end_character,
    new_text: new_text,
  ))
}
