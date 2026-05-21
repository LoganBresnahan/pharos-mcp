//// MCP tool: `find_references`.
////
//// Wraps LSP `textDocument/references`. Returns all usages of the
//// symbol at the given position across the workspace as a list of
//// `Location` objects. The `include_declaration` flag (LSP
//// `context.includeDeclaration`) controls whether the symbol's
//// definition site is in the result; defaults to true so the LLM
//// gets a complete picture.
////
//// Includes a retry-once-on-content-modified loop: rust-analyzer
//// in particular cancels references requests with
//// `ServerError(-32801, "content modified")` when its analysis
//// state evolves mid-request (background indexing or reanalysis).
//// gopls / pyright / typescript-language-server do not exhibit this
//// behavior, but the retry costs nothing in their case since they
//// never emit -32801. We retry once with a one-second sleep so
//// rust-analyzer has time to reach a stable state.
////
//// `lifecycle.wait_for_ready/3` exists from M8 stage 0F as a
//// progress-token-aware drain helper, but in dogfood it returned
//// before rust-analyzer had even started indexing (the post-didOpen
//// indexing burst arrives a few hundred milliseconds after didOpen,
//// past wait_for_ready's idle-bail threshold). Keep it available for
//// future use; rely on the retry path here.

import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers
import gleam/string

pub const default_timeout_ms: Int = 60_000

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
  timeout_ms: Int,
) -> Result(String, FindReferencesError) {
  let params = build_params(file_uri, line, character, include_declaration)
  case
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      session.request_with_content_modified_retry(fn() {
        proc.request(lsp, "textDocument/references", params, timeout_ms)
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

fn build_params(
  file_uri: String,
  line: Int,
  character: Int,
  include_declaration: Bool,
) -> json.Json {
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
    session.UnknownCustomUriScheme(uri) ->
      "custom URI scheme not registered for any language: " <> uri
    session.NoActiveSessionForLanguage(uri, language) ->
      "no active "
      <> language
      <> " session for custom URI "
      <> uri
      <> "; open a file:// from the same workspace first"
    session.AmbiguousSessionForLanguage(uri, language, workspaces) ->
      "ambiguous "
      <> language
      <> " session for custom URI "
      <> uri
      <> "; multiple workspaces active: "
      <> string.join(workspaces, ", ")
  }
}
