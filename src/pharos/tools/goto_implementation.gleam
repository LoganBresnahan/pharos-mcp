//// MCP tool: `goto_implementation`.
////
//// Wraps LSP `textDocument/implementation`. For an interface or
//// abstract method, returns the concrete implementation site(s).
//// Useful in trait-heavy languages: calling this on a Rust trait
//// method returns each `impl` block that defines that method. Same
//// response shape as `goto_definition`: Location, list of Location,
//// list of LocationLink, or null.

import gleam/int
import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/clip
import pharos/tools/session
import pharos/tools/tool_helpers
import gleam/string

// Bumped from 5s to 30s for parity with hover/document_symbols.
// The proc actor serializes concurrent requests; tighter timeouts
// expire under heavy multi-tool dispatch (M13 testing surfaced).
pub const default_timeout_ms: Int = 30_000

pub const default_limit: Int = 50

pub type GotoImplementationError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
  limit: Int,
  timeout_ms: Int,
) -> Result(String, GotoImplementationError) {
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
        proc.request(lsp, "textDocument/implementation", params, timeout_ms)
      })
    })
  {
    Ok(result_value) -> {
      let clipped = clip.clip_array(result_value, limit)
      case clipped.truncated_by {
        0 -> Ok(clipped.json_text)
        n ->
          Ok(
            clipped.json_text
            <> "\n\n(truncated "
            <> int.to_string(n)
            <> " more implementation site(s); pass `limit` to raise)",
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
