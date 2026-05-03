//// MCP tool: `document_symbols`.
////
//// Wraps LSP `textDocument/documentSymbol`. Returns the outline of
//// a single file — functions, types, modules, etc. — as a
//// hierarchical tree (LSP `DocumentSymbol[]`) or flat list
//// (`SymbolInformation[]`, deprecated but some servers still emit).
//// Pass-through verbatim as JSON.

import gleam/json
import llm_lsp_mcp/lsp/lifecycle
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/tools/tier1/session
import llm_lsp_mcp/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

pub type DocumentSymbolsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
) -> Result(String, DocumentSymbolsError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(lsp) -> {
      let params =
        json.object([
          #(
            "textDocument",
            json.object([#("uri", json.string(file_uri))]),
          ),
        ])

      case
        lifecycle.request(
          lsp,
          "textDocument/documentSymbol",
          params,
          tool_helpers.next_id(),
          default_timeout_ms,
        )
      {
        Error(err) ->
          Error(RequestFailed(tool_helpers.describe_request_error(err)))
        Ok(#(_lsp, result_value)) -> Ok(tool_helpers.json_encode(result_value))
      }
    }
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
