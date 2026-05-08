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

import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/clip
import pharos/tools/session
import pharos/tools/tool_helpers

const default_timeout_ms: Int = 10_000

pub const default_limit: Int = 20

pub type WorkspaceSymbolsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  workspace_uri_hint: String,
  query: String,
  limit: Int,
  language: Option(String),
) -> Result(String, WorkspaceSymbolsError) {
  let params = json.object([#("query", json.string(query))])

  let body = fn(lsp) {
    session.request_with_content_modified_retry(fn() {
      proc.request(lsp, "workspace/symbol", params, default_timeout_ms)
    })
  }

  let request_result = case language {
    Some(lang) ->
      session.with_workspace_session_and_retry_by_language(
        pool,
        lang,
        workspace_uri_hint,
        body,
      )
    None ->
      session.with_workspace_session_and_retry(pool, workspace_uri_hint, body)
  }

  case request_result {
    Ok(result_value) -> {
      let clipped = clip.clip_array(result_value, limit)
      case clipped.truncated_by {
        0 -> Ok(clipped.json_text)
        n ->
          Ok(
            clipped.json_text
            <> "\n\n(truncated "
            <> int.to_string(n)
            <> " more symbol(s); pass `limit` to raise. gopls "
            <> "in particular fuzzy-matches across the Go stdlib "
            <> "and can flood the result.)",
          )
      }
    }
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
