//// MCP tool: `document_symbols`.
////
//// Wraps LSP `textDocument/documentSymbol`. Returns the outline of
//// a single file — functions, types, modules, etc. — as a
//// hierarchical tree (LSP `DocumentSymbol[]`) or flat list
//// (`SymbolInformation[]`, deprecated but some servers still emit).
//// Pass-through verbatim as JSON.

import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers
import gleam/string

// Same headroom as hover/find_references — 5s is too tight when the
// proc actor is mid-drain on cold start (M11 polish B1).
pub const default_timeout_ms: Int = 30_000

pub type DocumentSymbolsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(String, DocumentSymbolsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])

  case
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      session.request_with_content_modified_retry(fn() {
        proc.request(lsp, "textDocument/documentSymbol", params, timeout_ms)
      })
    })
  {
    Ok(result_value) -> Ok(tool_helpers.json_encode(result_value))
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
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
    session.UnknownCustomUriScheme(uri) ->
      "custom URI scheme not registered for any language: " <> uri
    session.NoActiveSessionForLanguage(uri, language) ->
      "no active "
      <> language
      <> " session for custom URI "
      <> uri
      <> "; open a file:// from the same workspace first"
    session.AmbiguousSessionForLanguage(uri, language, workspaces) ->
      "ambiguous "
      <> language
      <> " session for custom URI "
      <> uri
      <> "; multiple workspaces active: "
      <> string.join(workspaces, ", ")
  }
}
