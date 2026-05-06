//// MCP tool: `code_actions`.
////
//// Wraps LSP `textDocument/codeAction`. Returns the verbatim list
//// of `Command | CodeAction` (LSP 3.16+) for the given range, as
//// JSON. Each action has a `title` describing what it would do;
//// `CodeAction` entries may carry an `edit` (WorkspaceEdit) and/or
//// a `command` to execute.
////
//// Pharos does not execute commands or apply edits automatically.
//// The LLM reviews the action list and either:
////   - Calls `apply_workspace_edit` (future M9 tool) with one
////     action's `edit`, or
////   - Applies the edit by hand via its own Edit tool.
////
//// Returning raw JSON (rather than rendering each action) keeps the
//// surface predictable; per-action `WorkspaceEdit` rendering is a
//// follow-up alongside the LLM-side ergonomic improvements.

import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers

const default_timeout_ms: Int = 5000

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
      // Empty `context.diagnostics` is the safe default — servers
      // return all available actions for the range. Tools that
      // want quick-fix-only behavior can pass diagnostics later.
      #(
        "context",
        json.object([
          #("diagnostics", json.preprocessed_array([])),
        ]),
      ),
    ])

  case
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      session.request_with_content_modified_retry(fn() {
        proc.request(lsp, "textDocument/codeAction", params, default_timeout_ms)
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
