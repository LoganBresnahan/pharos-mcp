//// MCP tool: `find_references`.
////
//// Wraps LSP `textDocument/references`. Returns all usages of the
//// symbol at the given position across the workspace as a list of
//// `Location` objects. The `include_declaration` flag (LSP
//// `context.includeDeclaration`) controls whether the symbol's
//// definition site is in the result; defaults to true so the LLM
//// gets a complete picture.

import gleam/json
import llm_lsp_mcp/lsp/lifecycle
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/tools/tier1/session
import llm_lsp_mcp/tools/tier1/tool_helpers

const default_timeout_ms: Int = 10_000

pub type FindReferencesError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
  include_declaration: Bool,
) -> Result(String, FindReferencesError) {
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
          #(
            "context",
            json.object([
              #("includeDeclaration", json.bool(include_declaration)),
            ]),
          ),
        ])

      case
        lifecycle.request(
          lsp,
          "textDocument/references",
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
