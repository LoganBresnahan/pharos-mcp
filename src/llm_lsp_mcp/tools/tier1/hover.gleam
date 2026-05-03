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
import llm_lsp_mcp/lsp/lifecycle
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/tools/tier1/session
import llm_lsp_mcp/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

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
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(lsp) -> {
      let params =
        json.object([
          #(
            "textDocument",
            json.object([#("uri", json.string(file_uri))]),
          ),
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
          "textDocument/hover",
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
      "no Cargo.toml found ascending from " <> uri
    session.UnsupportedFileType(uri) -> "unsupported file type: " <> uri
    session.SpawnFailed(reason) -> "LSP spawn failed: " <> reason
    session.HandshakeFailed(reason) ->
      "LSP initialize handshake failed: " <> reason
  }
}
