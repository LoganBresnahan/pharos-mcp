//// MCP tool: `format_document`.
////
//// Wraps LSP `textDocument/formatting`. Returns the formatter's
//// proposed edits as a rendered summary via
//// `pharos/tools/workspace_edit`. Never writes to disk; the LLM
//// reviews the edit and applies via its own Edit tool (or, in a
//// future milestone, an `apply_workspace_edit` MCP tool).
////
//// Formatting options are LSP-spec defaults: `tabSize: 4`,
//// `insertSpaces: true`. Per-language overrides land alongside
//// the language-config polish in M9.

import gleam/dynamic.{type Dynamic}
import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers
import pharos/tools/workspace_edit

pub const default_timeout_ms: Int = 30_000

pub type FormatDocumentError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
  RenderFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(String, FormatDocumentError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
      #(
        "options",
        json.object([
          #("tabSize", json.int(4)),
          #("insertSpaces", json.bool(True)),
        ]),
      ),
    ])

  case
    session.with_session_and_retry_for_method(
      pool,
      file_uri,
      "textDocument/formatting",
      fn(lsp) {
        session.request_with_content_modified_retry(fn() {
          proc.request(lsp, "textDocument/formatting", params, timeout_ms)
        })
      },
    )
  {
    Ok(result_value) -> render(file_uri, result_value)
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

/// Wrap the LSP-returned `TextEdit[]` (single-file edits) into a
/// synthetic WorkspaceEdit `{changes: {<uri>: [...]}}` and render
/// via the shared workspace_edit summary renderer.
///
/// LSP `textDocument/formatting` may return `null` when the
/// formatter has no edits to make (already-formatted file) or
/// `[]` when the formatter ran but produced an empty edit list.
/// Both shapes mean "no changes needed" — callers want a friendly
/// message, not a decoder error from the WorkspaceEdit renderer.
fn render(
  file_uri: String,
  edits_value: Dynamic,
) -> Result(String, FormatDocumentError) {
  let edits_text = tool_helpers.json_encode(edits_value)
  case is_no_edit_response(edits_text) {
    True -> Ok("File is already formatted — no edits proposed by the LSP.")
    False -> render_workspace_edit(file_uri, edits_text)
  }
}

fn is_no_edit_response(edits_text: String) -> Bool {
  case edits_text {
    "null" -> True
    "[]" -> True
    _ -> False
  }
}

fn render_workspace_edit(
  file_uri: String,
  edits_text: String,
) -> Result(String, FormatDocumentError) {
  let synthetic =
    "{\"changes\":{\""
    <> file_uri
    <> "\":"
    <> edits_text
    <> "}}"

  case json_parse_dynamic(synthetic) {
    Error(reason) -> Error(RenderFailed(reason))
    Ok(parsed) ->
      case workspace_edit.render(parsed) {
        Ok(rendered) -> Ok(rendered)
        Error(workspace_edit.DecodeError(reason)) ->
          Error(RenderFailed(reason))
      }
  }
}

@external(erlang, "json", "decode")
fn raw_json_decode(text: BitArray) -> Dynamic

fn json_parse_dynamic(text: String) -> Result(Dynamic, String) {
  // Erlang's OTP 27+ `json` module exposes a decode/1 that yields a
  // term we can hand back to Gleam as Dynamic. Wrapped so the rest
  // of pharos stays on `gleam/json` for the typed encode path.
  Ok(raw_json_decode(<<text:utf8>>))
}

fn describe_session_error(err: session.SessionError) -> String {
  case err {
    session.NotAFileUri(uri) -> "not a file:// URI: " <> uri
    session.WorkspaceNotFound(uri) ->
      "no workspace root marker found ascending from " <> uri
    session.UnsupportedFileType(uri) -> "unsupported file type: " <> uri
    session.SpawnFailed(reason) -> "LSP spawn failed: " <> reason
    session.HandshakeFailed(reason) ->
      "LSP initialize handshake failed: " <> reason
  }
}
