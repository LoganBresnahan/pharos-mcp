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

import gleam/erlang/process
import gleam/json
import pharos/lsp/proc.{type Proc}
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

pub const default_timeout_ms: Int = 60_000

const content_modified_retry_delay_ms: Int = 1000

const content_modified_code: Int = -32_801

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
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(lsp) -> {
      let params = build_params(file_uri, line, character, include_declaration)
      attempt(lsp, params, timeout_ms, retries_left: 1)
    }
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

fn attempt(
  lsp: Proc,
  params: json.Json,
  timeout_ms: Int,
  retries_left retries_left: Int,
) -> Result(String, FindReferencesError) {
  case proc.request(lsp, "textDocument/references", params, timeout_ms) {
    Ok(result_value) -> Ok(tool_helpers.json_encode(result_value))

    Error(lifecycle.ServerError(code, _message))
      if code == content_modified_code && retries_left > 0
    -> {
      // Content state changed during the request — usually
      // rust-analyzer doing background indexing. Sleep briefly so
      // the server reaches a steady state, then try again.
      process.sleep(content_modified_retry_delay_ms)
      attempt(lsp, params, timeout_ms, retries_left: retries_left - 1)
    }

    Error(err) ->
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
