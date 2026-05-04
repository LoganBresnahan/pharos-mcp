//// MCP tool: `call_hierarchy_prepare`.
////
//// Wraps LSP `textDocument/prepareCallHierarchy`. Returns one or
//// more `CallHierarchyItem` objects identifying the callable at the
//// given position. Each item is opaque from the client side — it is
//// whatever the server needs to identify the symbol when asked for
//// `incomingCalls` / `outgoingCalls` later.
////
//// The follow-on `callHierarchy/incomingCalls` and
//// `callHierarchy/outgoingCalls` requests round-trip a previously-
//// returned item. Until pharos exposes a passthrough that can carry
//// a pre-encoded JSON value into LSP request params, those two
//// methods are reachable via the `lsp_request_raw` escape hatch
//// (Stage 1C). The prepare step lands first because it has the
//// standard `(uri, line, character)` shape.

import gleam/json
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

pub type CallHierarchyError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn prepare(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
) -> Result(String, CallHierarchyError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(lsp) -> {
      let params =
        json.object([
          #("textDocument", json.object([#("uri", json.string(file_uri))])),
          #(
            "position",
            json.object([
              #("line", json.int(line)),
              #("character", json.int(character)),
            ]),
          ),
        ])

      case
        lifecycle.request(
          lsp,
          "textDocument/prepareCallHierarchy",
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
