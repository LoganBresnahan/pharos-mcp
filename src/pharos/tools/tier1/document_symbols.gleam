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
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

pub type DocumentSymbolsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
) -> Result(String, DocumentSymbolsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])

  case
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      proc.request(lsp, "textDocument/documentSymbol", params, default_timeout_ms)
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
  }
}
