//// MCP tool: `workspace_symbols`.
////
//// Wraps LSP `workspace/symbol`. Returns symbols across the entire
//// workspace matching a query string. Server returns
//// `SymbolInformation[]` or `WorkspaceSymbol[]` (LSP 3.17+).
//// Pass-through verbatim as JSON.
////
//// Unlike per-file tools, this needs a workspace path hint to know
//// which LSP to query. Caller passes a URI of any file inside the
//// workspace, or the workspace root itself as a `file://` URI.

import gleam/json
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 10_000

pub type WorkspaceSymbolsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  workspace_uri_hint: String,
  query: String,
) -> Result(String, WorkspaceSymbolsError) {
  case session.prepare_workspace(pool, workspace_uri_hint) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(lsp) -> {
      let params = json.object([#("query", json.string(query))])

      case
        lifecycle.request(
          lsp,
          "workspace/symbol",
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
