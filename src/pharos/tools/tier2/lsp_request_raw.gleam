//// MCP tool: `lsp_request_raw`.
////
//// Escape hatch for LSP methods pharos does not expose as a typed
//// tool. Takes any `(uri, method, params)` triple, routes to the
//// LSP for the file's language, and returns the verbatim result as
//// JSON. The `uri` is required for routing — pharos picks the LSP
//// by file extension just like every other tool.
////
//// Use cases:
////   - `callHierarchy/incomingCalls` / `outgoingCalls` (round-trip
////     a previously-returned CallHierarchyItem)
////   - `textDocument/inlayHint` and other Tier 3 read methods
////     before they get a typed wrapper
////   - Server-specific extensions (rust-analyzer's
////     `experimental/serverStatus`, etc.)
////
//// The LLM is responsible for sending well-formed params. Errors
//// from the LSP surface as `RequestFailed("server error <code>:
//// <message>")` per the standard tool error mapping.

import gleam/dynamic.{type Dynamic}
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 30_000

pub type LspRequestRawError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  method: String,
  params: Dynamic,
) -> Result(String, LspRequestRawError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(lsp) -> {
      let params_json = tool_helpers.json_encode(params)

      case
        lifecycle.request_raw_params(
          lsp,
          method,
          params_json,
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
