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
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers

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
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      session.request_with_content_modified_retry(fn() {
        proc.request(lsp, "textDocument/signatureHelp", params, default_timeout_ms)
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
  }
}
