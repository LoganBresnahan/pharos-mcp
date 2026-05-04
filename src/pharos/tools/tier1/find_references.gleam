//// MCP tool: `find_references`.
////
//// Wraps LSP `textDocument/references`. Returns all usages of the
//// symbol at the given position across the workspace as a list of
//// `Location` objects. The `include_declaration` flag (LSP
//// `context.includeDeclaration`) controls whether the symbol's
//// definition site is in the result; defaults to true so the LLM
//// gets a complete picture.
////
//// Calls `lifecycle.wait_for_ready/3` between session setup and the
//// actual request. Per ADR-012 stage 0F this drains in-flight
//// `$/progress` notifications so rust-analyzer's mid-indexing state
//// has settled before we send the request. Replaces the old
//// retry-on-`-32801`-ContentModified loop, which was rust-analyzer-
//// specific and brittle (a 1s sleep covers small workspaces but
//// times out on larger ones).

import gleam/json
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 10_000

const readiness_timeout_ms: Int = 30_000

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
  case session.config_for_uri(file_uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(config) ->
      case session.prepare(pool, file_uri) {
        Error(err) -> Error(SessionFailed(describe_session_error(err)))
        Ok(lsp) -> {
          let params =
            build_params(file_uri, line, character, include_declaration)

          case
            lifecycle.wait_for_ready(
              lsp,
              config.readiness_token,
              readiness_timeout_ms,
            )
          {
            Error(err) ->
              Error(RequestFailed(tool_helpers.describe_request_error(err)))

            Ok(lsp) ->
              case
                lifecycle.request(
                  lsp,
                  "textDocument/references",
                  params,
                  tool_helpers.next_id(),
                  default_timeout_ms,
                )
              {
                Ok(#(_lsp, result_value)) ->
                  Ok(tool_helpers.json_encode(result_value))
                Error(err) ->
                  Error(RequestFailed(
                    tool_helpers.describe_request_error(err),
                  ))
              }
          }
        }
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
