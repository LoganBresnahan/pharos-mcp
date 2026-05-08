//// MCP tool: `hover`.
////
//// Wraps LSP `textDocument/hover`. Returns the server's hover
//// payload — type signature, doc comments, etc. — verbatim as JSON.
//// LSP's response shape:
////   { contents: MarkupContent | string | MarkedString[],
////     range?: Range }
//// We pass the entire `result` value through; the LLM reads
//// whichever shape the server sends.

import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers

// Cold rust-analyzer + concurrent worker queueing through the proc
// actor (post-didOpen drain serialization, M11 polish B1) makes the
// previous 5s default too tight when multiple tools fan out at once.
// 30s matches `find_references`. `request_with_content_modified_retry`
// still catches the rare mid-call indexing reset.
const default_timeout_ms: Int = 30_000

pub type HoverError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
) -> Result(String, HoverError) {
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
        proc.request(lsp, "textDocument/hover", params, default_timeout_ms)
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
