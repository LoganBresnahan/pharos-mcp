//// MCP tool: `semantic_tokens`.
////
//// Wraps LSP `textDocument/semanticTokens/full` and
//// `textDocument/semanticTokens/range`. Returns the verbatim LSP
//// `SemanticTokens` result: `{resultId?: string, data: number[]}`.
////
//// `data` is the LSP-spec integer array encoding — 5 ints per
//// token: `[deltaLine, deltaStartChar, length, tokenType,
//// tokenModifiers]`. `tokenType` is an index into the server's
//// legend (returned in the server's `initialize` capabilities under
//// `semanticTokensProvider.legend`); pharos does not yet stash the
//// legend, so callers wanting names instead of indices need to fetch
//// the legend themselves via `lsp_request_raw` against the
//// `initialize` response, or rely on the well-known LSP defaults.
////
//// When `start_line` / `start_character` / `end_line` /
//// `end_character` are all `0` the tool dispatches to `/full`;
//// otherwise it dispatches to `/range`. Empty range is a sentinel
//// for "no range, return tokens for the whole document" — passing
//// a real zero-length range as a `/range` request is not a use
//// case any caller has surfaced.

import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers

pub const default_timeout_ms: Int = 30_000

pub type SemanticTokensError {
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
) -> Result(String, SemanticTokensError) {
  let #(method, params) = case
    start_line == 0
    && start_character == 0
    && end_line == 0
    && end_character == 0
  {
    True -> #(
      "textDocument/semanticTokens/full",
      json.object([
        #("textDocument", json.object([#("uri", json.string(file_uri))])),
      ]),
    )
    False -> #(
      "textDocument/semanticTokens/range",
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
      ]),
    )
  }

  case
    session.with_session_and_retry_for_method(
      pool,
      file_uri,
      method,
      fn(lsp) {
        tool_helpers.with_capability_gate(lsp, method, fn() {
          session.request_with_content_modified_retry(fn() {
            proc.request(lsp, method, params, timeout_ms)
          })
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
