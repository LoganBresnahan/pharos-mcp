//// MCP tool: `code_actions`.
////
//// Wraps LSP `textDocument/codeAction`. Per ADR-019 routing this is
//// a `FanOut` method: every server whose `MethodScope` covers
//// `textDocument/codeAction` is consulted, and their result arrays
//// are concatenated. Today this matters for python — pyright +
//// ruff both contribute fixes, where pyright surfaces type-related
//// quick-fixes and ruff surfaces lint autofixes + import-sort. Most
//// other languages still resolve to a single primary server.
////
//// Pharos does not execute commands or apply edits automatically.
//// The LLM reviews the action list and either:
////   - Calls `apply_workspace_edit` (future M11 tool) with one
////     action's `edit`, or
////   - Applies the edit by hand via its own Edit tool.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/lifecycle
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers
import gleam/string

pub const default_timeout_ms: Int = 30_000

pub type CodeActionsError {
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
) -> Result(String, CodeActionsError) {
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
      #(
        "context",
        json.object([
          #("diagnostics", json.preprocessed_array([])),
        ]),
      ),
    ])

  case session.prepare_all_for_method(pool, file_uri, "textDocument/codeAction") {
    Error(err) -> Error(SessionFailed(describe_session_error(err)))
    Ok([]) ->
      Error(SessionFailed(
        "no LSP server in the language registry claims "
          <> "textDocument/codeAction for this file",
      ))
    Ok(servers) -> {
      let responses =
        list.map(servers, fn(entry) {
          let #(server_id, lsp) = entry
          let result = session.request_with_content_modified_retry(fn() {
            proc.request(lsp, "textDocument/codeAction", params, timeout_ms)
          })
          #(server_id, result)
        })
      Ok(merge_responses(responses))
    }
  }
}

/// Concatenate the action arrays returned by each server. Failed
/// responses are warn-logged and dropped so the LLM still gets the
/// surviving actions instead of an all-or-nothing error. Non-array
/// payloads (servers that returned `null` or a malformed shape) are
/// likewise dropped.
fn merge_responses(
  responses: List(#(String, Result(Dynamic, lifecycle.RequestError))),
) -> String {
  let merged_items =
    list.fold(responses, [], fn(acc, entry) {
      let #(server_id, result) = entry
      case result {
        Ok(value) ->
          case decode.run(value, decode.list(decode.dynamic)) {
            Ok(items) -> list.append(acc, items)
            Error(_) -> {
              log.fields_at(
                "pharos/tools/code_actions",
                log_entry.Warn,
                "server returned non-array codeAction response; skipping",
                [#("server", server_id)],
              )
              acc
            }
          }
        Error(err) -> {
          log.fields_at(
            "pharos/tools/code_actions",
            log_entry.Warn,
            "server codeAction request failed",
            [
              #("server", server_id),
              #("reason", tool_helpers.describe_request_error(err)),
            ],
          )
          acc
        }
      }
    })
  encode_dynamic_list(merged_items)
}

@external(erlang, "pharos_fs_ffi", "encode_json")
fn encode_dynamic_list(items: List(Dynamic)) -> String

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
