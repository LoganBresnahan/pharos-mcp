//// MCP tool: `fetch_uri_contents`.
////
//// ADR-029. Read raw textual content from a custom-scheme URI by
//// dispatching the per-scheme LSP method declared in the language
//// registry. Pharos's other tools (hover, find_references, etc.)
//// also accept custom URIs after the session-gate relaxation, but
//// none of them return a file's whole text — Claude Code's `Read`
//// is filesystem-only, and there's no equivalent for virtual URIs
//// like `jdt://contents/...`. This tool fills that gap.
////
//// For `jdt://`, the registry maps the scheme to jdtls's
//// `java/classFileContents` extension method. The LSP returns the
//// decompiled source as a plain string; pharos wraps it in
//// `{uri, content, language_id}` so the LLM gets the same envelope
//// shape regardless of which scheme it asked for.
////
//// Errors:
////   - `SessionFailed` — scheme isn't registered, no Ready session
////     for the scheme's language, or multiple Ready workspaces (the
////     three ADR-029 session error variants).
////   - `RequestFailed` — the LSP method itself failed (server
////     error, timeout, transport).
////   - `DecodeFailed` — the LSP returned something that wasn't a
////     string (the `fetch_response_field` was empty so we expect
////     the response IS the content, but it wasn't).

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/string
import pharos/lsp/languages.{type CustomUriScheme}
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers

pub const default_timeout_ms: Int = 30_000

pub type FetchUriContentsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
  DecodeFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  uri: String,
  timeout_ms: Int,
) -> Result(String, FetchUriContentsError) {
  case session.prepare_for_custom_uri_with_meta(pool, uri) {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok(#(lsp, scheme)) -> {
      let params = json.object([#("uri", json.string(uri))])
      case proc.request(lsp, scheme.fetch_method, params, timeout_ms) {
        Error(err) ->
          Error(RequestFailed(tool_helpers.describe_request_error(err)))
        Ok(value) ->
          case extract_content(value, scheme) {
            Error(reason) -> Error(DecodeFailed(reason))
            Ok(content) -> Ok(render_response(uri, content))
          }
      }
    }
  }
}

/// Pull the content string out of the LSP response. When
/// `fetch_response_field` is empty the response IS the content
/// (jdtls's `java/classFileContents` shape); otherwise it's an
/// object with the content under the named key.
fn extract_content(
  value: Dynamic,
  scheme: CustomUriScheme,
) -> Result(String, String) {
  case scheme.fetch_response_field {
    "" ->
      decode.run(value, decode.string)
      |> result_map_error_string(
        "response was not a string (expected raw content)",
      )
    field ->
      decode.run(value, {
        use s <- decode.field(field, decode.string)
        decode.success(s)
      })
      |> result_map_error_string(
        "response did not carry string field `" <> field <> "`",
      )
  }
}

fn result_map_error_string(
  res: Result(a, b),
  message: String,
) -> Result(a, String) {
  case res {
    Ok(v) -> Ok(v)
    Error(_) -> Error(message)
  }
}

fn render_response(uri: String, content: String) -> String {
  json.to_string(
    json.object([
      #("uri", json.string(uri)),
      #("content", json.string(content)),
    ]),
  )
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
