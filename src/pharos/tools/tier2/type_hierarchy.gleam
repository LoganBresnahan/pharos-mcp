//// MCP tools: type hierarchy (prepare, supertypes, subtypes).
////
//// LSP's type-hierarchy is a two-step protocol identical in shape
//// to call-hierarchy:
////   1. `textDocument/prepareTypeHierarchy` at a position →
////      `TypeHierarchyItem[]`
////   2. `typeHierarchy/supertypes` or `typeHierarchy/subtypes`
////      takes one of those items, returns the type relationship list
////
//// All three tools live in this module. `supertypes` / `subtypes`
//// round-trip a previously-returned item; they extract the item's
//// `uri` to pick the LSP and forward the entire item back via
//// `proc.request_raw/4`, which accepts pre-encoded JSON params.
////
//// Server support is sparse at the time of writing: rust-analyzer,
//// pyright, gopls, and typescript-language-server all return
//// `-32601 Method not found` for `prepareTypeHierarchy`. Pharos
//// surfaces the LSP error verbatim. The tool plumbing ships ahead
//// of LSP support; verify your server's release notes before
//// relying on it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

pub type TypeHierarchyError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
  /// The supplied type hierarchy item could not be decoded — the
  /// `uri` field (required for LSP routing) was missing or not a
  /// string.
  InvalidItem(reason: String)
}

pub fn prepare(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
) -> Result(String, TypeHierarchyError) {
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
        proc.request(
          lsp,
          "textDocument/prepareTypeHierarchy",
          params,
          default_timeout_ms,
        )
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

pub fn supertypes(
  pool: Pool,
  item: Dynamic,
) -> Result(String, TypeHierarchyError) {
  call_with_item(pool, "typeHierarchy/supertypes", item)
}

pub fn subtypes(
  pool: Pool,
  item: Dynamic,
) -> Result(String, TypeHierarchyError) {
  call_with_item(pool, "typeHierarchy/subtypes", item)
}

fn call_with_item(
  pool: Pool,
  method: String,
  item: Dynamic,
) -> Result(String, TypeHierarchyError) {
  case decode.run(item, item_uri_decoder()) {
    Error(_) ->
      Error(InvalidItem(
        "type hierarchy item missing or non-string `uri` field",
      ))

    Ok(file_uri) -> {
      let params_text =
        "{\"item\":" <> tool_helpers.json_encode(item) <> "}"

      case
        session.with_session_and_retry(pool, file_uri, fn(lsp) {
          proc.request_raw(lsp, method, params_text, default_timeout_ms)
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
  }
}
