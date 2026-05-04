//// MCP tool: `signature_help`.
////
//// Wraps LSP `textDocument/signatureHelp`. At a given position
//// (typically inside a function call's parentheses), returns the
//// callee's signature(s) plus an indication of which parameter the
//// cursor is currently on. Returns the verbatim LSP `SignatureHelp`
//// JSON: `{signatures: [...], activeSignature?: int,
//// activeParameter?: int}`. May be null if the server has no
//// signature for the position.

import gleam/json
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

pub type SignatureHelpError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
) -> Result(String, SignatureHelpError) {
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
          "textDocument/signatureHelp",
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
