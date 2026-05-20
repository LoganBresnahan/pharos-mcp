//// MCP tools: call hierarchy (prepare, incoming, outgoing).
////
//// LSP's call-hierarchy is a two-step protocol:
////   1. `textDocument/prepareCallHierarchy` at a position →
////      `CallHierarchyItem[]`
////   2. `callHierarchy/incomingCalls` or `outgoingCalls` takes one
////      of those items, returns the call list
////
//// All three tools live in this module. `incoming_calls` and
//// `outgoing_calls` round-trip a previously-returned item; they
//// extract the item's `uri` to pick the LSP and forward the entire
//// item back via `lifecycle.request_raw_params/5` (Stage 1C),
//// which accepts pre-encoded JSON params.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers
import gleam/string

// Bumped from 5s to 30s for parity with hover/document_symbols.
// The proc actor serializes concurrent requests; tighter timeouts
// expire under heavy multi-tool dispatch (M13 testing surfaced).
pub const default_timeout_ms: Int = 30_000

pub type CallHierarchyError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
  /// The supplied call hierarchy item could not be decoded — the
  /// `uri` field (required for LSP routing) was missing or not a
  /// string.
  InvalidItem(reason: String)
}

pub fn prepare(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
  timeout_ms: Int,
) -> Result(String, CallHierarchyError) {
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
      tool_helpers.with_capability_gate(
        lsp,
        "textDocument/prepareCallHierarchy",
        fn() {
          session.request_with_content_modified_retry(fn() {
            proc.request(
              lsp,
              "textDocument/prepareCallHierarchy",
              params,
              timeout_ms,
            )
          })
        },
      )
    })
  {
    Ok(result_value) -> Ok(tool_helpers.json_encode(result_value))
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

pub fn incoming_calls(
  pool: Pool,
  item: Dynamic,
  timeout_ms: Int,
) -> Result(String, CallHierarchyError) {
  call_with_item(pool, "callHierarchy/incomingCalls", item, timeout_ms)
}

pub fn outgoing_calls(
  pool: Pool,
  item: Dynamic,
  timeout_ms: Int,
) -> Result(String, CallHierarchyError) {
  call_with_item(pool, "callHierarchy/outgoingCalls", item, timeout_ms)
}

fn call_with_item(
  pool: Pool,
  method: String,
  item: Dynamic,
  timeout_ms: Int,
) -> Result(String, CallHierarchyError) {
  case decode.run(item, item_uri_decoder()) {
    Error(_) ->
      Error(InvalidItem(
        "call hierarchy item missing or non-string `uri` field",
      ))

    Ok(file_uri) -> {
      // Build params text manually: {"item": <verbatim item>}.
      // tool_helpers.json_encode round-trips the Dynamic to JSON.
      let params_text =
        "{\"item\":" <> tool_helpers.json_encode(item) <> "}"

      case
        session.with_session_and_retry(pool, file_uri, fn(lsp) {
          proc.request_raw(lsp, method, params_text, timeout_ms)
        })
      {
        Ok(result_value) -> Ok(tool_helpers.json_encode(result_value))
        Error(session.RetrySessionError(err)) ->
          Error(SessionFailed(describe_session_error(err)))
        Error(session.RetryRequestError(err)) ->
          Error(RequestFailed(tool_helpers.describe_request_error(err)))
      }
    }
  }
}

fn item_uri_decoder() -> decode.Decoder(String) {
  decode.field("uri", decode.string, decode.success)
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
