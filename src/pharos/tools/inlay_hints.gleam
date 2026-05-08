//// MCP tool: `inlay_hints`.
////
//// Wraps LSP `textDocument/inlayHint`. Inlay hints are inline
//// annotations the editor renders next to source text — parameter
//// names at call sites, inferred types after `let` bindings, etc.
//// pharos returns the verbatim LSP `InlayHint[]` JSON so the LLM
//// can read the hints exactly as an editor would render them.
////
//// Each `InlayHint` (LSP 3.17+) contains:
////
////   - `position`: where the hint would render (line/character)
////   - `label`: string OR `InlayHintLabelPart[]`
////   - `kind?`: 1=Type, 2=Parameter
////   - `tooltip?`: extra hover text
////   - `paddingLeft?` / `paddingRight?`: render padding
////   - `textEdits?`: edits to apply if the user accepts the hint
////
//// Returns `null` or `[]` when the server has no hints for the
//// range. rust-analyzer / pyright / typescript-language-server all
//// implement this; gopls implements it under a different feature
//// flag the user must enable in their server config.

import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers

pub const default_timeout_ms: Int = 30_000

pub type InlayHintsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  start_line: Int,
  start_character: Int,
  end_line: Int,
  end_character: Int,
  timeout_ms: Int,
) -> Result(String, InlayHintsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
      #(
        "range",
        json.object([
          #(
            "start",
            json.object([
              #("line", json.int(start_line)),
              #("character", json.int(start_character)),
            ]),
          ),
          #(
            "end",
            json.object([
              #("line", json.int(end_line)),
              #("character", json.int(end_character)),
            ]),
          ),
        ]),
      ),
    ])

  case
    session.with_session_and_retry_for_method(
      pool,
      file_uri,
      "textDocument/inlayHint",
      fn(lsp) {
        session.request_with_content_modified_retry(fn() {
          proc.request(lsp, "textDocument/inlayHint", params, timeout_ms)
        })
      },
    )
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
