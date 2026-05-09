//// MCP tool: `rename_preview`.
////
//// Wraps LSP `textDocument/rename`. Returns the proposed
//// `WorkspaceEdit` as a rendered summary via
//// `pharos/tools/workspace_edit`. Never writes to disk —
//// "preview" is the operative word: the LLM reviews the edit and
//// applies via its own Edit tool (or, future, an
//// `apply_workspace_edit` MCP tool).
////
//// Some servers (notably typescript-language-server, pyright)
//// return the WorkspaceEdit as the request result. Others may emit
//// `workspace/applyEdit` as a server-initiated request mid-flight,
//// expecting the client to apply and report back. To handle both
//// routes uniformly, this tool installs a per-call
//// `workspace/applyEdit` capture handler via `lifecycle.with_handler`
//// (ADR-012 decision 5 / stage 0E). The capture stashes the edit
//// payload, replies `{applied: true}` so the server proceeds, and
//// the tool prefers the captured edit over the request result when
//// both are present.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/lsp/server_request_handlers
import pharos/tools/session
import pharos/tools/tool_helpers
import pharos/tools/workspace_edit

pub const default_timeout_ms: Int = 30_000

pub type RenamePreviewError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
  RenderFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  file_uri: String,
  line: Int,
  character: Int,
  new_name: String,
  timeout_ms: Int,
) -> Result(String, RenamePreviewError) {
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
      #("newName", json.string(new_name)),
    ])

  let captured = process.new_subject()
  let capture_handler = fn(_id, applied_params) {
    process.send(captured, applied_params)
    server_request_handlers.Reply(applied_ok_json())
  }

  let request_result =
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      proc.with_handler(
        lsp,
        "workspace/applyEdit",
        capture_handler,
        fn() {
          session.request_with_content_modified_retry(fn() {
            proc.request(lsp, "textDocument/rename", params, timeout_ms)
          })
        },
      )
    })

  // Prefer the applyEdit-captured edit over the request result.
  // If neither route produced anything decodable, surface the
  // request error or an empty-edit summary.
  case process.receive(captured, 0) {
    Ok(applied_params) -> render_apply_edit_params(applied_params)
    Error(_) ->
      case request_result {
        Ok(result_value) -> render_workspace_edit(result_value)
        Error(session.RetrySessionError(err)) ->
          Error(SessionFailed(describe_session_error(err)))
        Error(session.RetryRequestError(err)) ->
          Error(RequestFailed(tool_helpers.describe_request_error(err)))
      }
  }
}

fn applied_ok_json() -> json.Json {
  json.object([#("applied", json.bool(True))])
}

fn render_apply_edit_params(
  applied_params: Dynamic,
) -> Result(String, RenamePreviewError) {
  // workspace/applyEdit params shape: {label?: string, edit:
  // WorkspaceEdit}. Extract `edit` and render.
  case decode.run(applied_params, edit_field_decoder()) {
    Error(_) ->
      Error(RenderFailed(
        "workspace/applyEdit params missing or non-object `edit` field",
      ))
    Ok(edit_value) -> render_workspace_edit(edit_value)
  }
}

fn edit_field_decoder() -> decode.Decoder(Dynamic) {
  decode.field("edit", decode.dynamic, decode.success)
}

fn render_workspace_edit(
  value: Dynamic,
) -> Result(String, RenamePreviewError) {
  case workspace_edit.render(value) {
    Ok(rendered) -> Ok(rendered)
    Error(workspace_edit.DecodeError(reason)) -> Error(RenderFailed(reason))
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
