//// Common prelude for tier-1 tools.
////
//// Every tier-1 LSP-backed tool needs the same boilerplate:
////   1. Validate the file URI (must be `file://` and `.rs`)
////   2. Discover the workspace root by walking up to Cargo.toml
////   3. Fetch a Client from the kept-warm pool (spawn + initialize
////      on cache miss, return cached on hit)
////   4. Send `textDocument/didOpen` so the LSP knows about the file
////
//// `prepare/2` does all of that and returns a Client ready for the
//// tool's specific LSP method to call. Tool implementations
//// (`hover`, `goto_definition`, etc.) stay focused on building
//// params and rendering the response.
////
//// At Milestone 4 the language is hardcoded as Rust. The language
//// registry at stage 3 will replace `rust_analyzer_command` and the
//// `["Cargo.toml"]` markers with config-driven values.

import gleam/bit_array
import gleam/json
import gleam/result
import gleam/string
import llm_lsp_mcp/lsp/client.{type Client}
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/workspace_root

const rust_analyzer_command: String = "/home/oof/.cargo/bin/rust-analyzer"

pub type SessionError {
  NotAFileUri(uri: String)
  WorkspaceNotFound(uri: String)
  UnsupportedFileType(uri: String)
  SpawnFailed(reason: String)
  HandshakeFailed(reason: String)
}

/// Prepare a Client for tools that operate on a single file. Runs
/// the per-call boilerplate and asks the pool to send `didOpen` if
/// it has not already done so this session for this (language,
/// workspace, uri) triple. The pool's didOpen-once tracking avoids
/// rust-analyzer's "content modified" cancellation that fires when
/// duplicate didOpens land mid-request.
pub fn prepare(pool: Pool, file_uri: String) -> Result(Client, SessionError) {
  use Nil <- result.try(check_extension(file_uri))
  use workspace <- result.try(discover_workspace(file_uri))
  use lsp <- result.try(get_lsp(pool, workspace))
  let _ = ensure_doc_opened(pool, workspace, file_uri)
  Ok(lsp)
}

/// Variant for tools that operate workspace-wide (workspace_symbols)
/// rather than on a specific file. Skips the URI check and didOpen.
pub fn prepare_workspace(
  pool: Pool,
  workspace_uri_hint: String,
) -> Result(Client, SessionError) {
  use workspace <- result.try(discover_workspace(workspace_uri_hint))
  get_lsp(pool, workspace)
}

// -- Internals ----------------------------------------------------------

fn check_extension(uri: String) -> Result(Nil, SessionError) {
  case string.ends_with(uri, ".rs") {
    True -> Ok(Nil)
    False -> Error(UnsupportedFileType(uri))
  }
}

fn discover_workspace(file_uri: String) -> Result(String, SessionError) {
  workspace_root.discover_from_uri(file_uri, ["Cargo.toml"])
  |> result.map_error(fn(err) {
    case err {
      workspace_root.NotAFileUri(uri) -> NotAFileUri(uri)
      workspace_root.NoMarkerFound -> WorkspaceNotFound(file_uri)
    }
  })
}

fn get_lsp(pool: Pool, workspace: String) -> Result(Client, SessionError) {
  let spec =
    pool.SpawnSpec(
      command: rust_analyzer_command,
      args: [],
      init_params: build_initialize_params(workspace),
    )
  pool.get(pool, "rust", workspace, spec)
  |> result.map_error(fn(err) {
    case err {
      pool.StartFailed(_) -> SpawnFailed("LSP failed to spawn")
      pool.HandshakeFailed(_) ->
        HandshakeFailed("LSP initialize handshake failed")
    }
  })
}

fn build_initialize_params(workspace_path: String) -> json.Json {
  let root_uri = workspace_root.path_to_uri(workspace_path)
  json.object([
    #("processId", json.null()),
    #("rootUri", json.string(root_uri)),
    #("rootPath", json.string(workspace_path)),
    #("capabilities", json.object([])),
    #(
      "clientInfo",
      json.object([
        #("name", json.string("llm_lsp_mcp")),
        #("version", json.string("0.0.1")),
      ]),
    ),
    #("initializationOptions", json.object([])),
  ])
}

/// Read file content from disk and ask the pool to send didOpen if
/// it has not already done so for this triple. Best-effort —
/// failures (file gone, content not utf-8, pool busy) are swallowed
/// since the subsequent LSP request will surface a real error if
/// the document state is genuinely missing.
fn ensure_doc_opened(
  pool: Pool,
  workspace: String,
  file_uri: String,
) -> Nil {
  case workspace_root.uri_to_path(file_uri) {
    Error(_) -> Nil
    Ok(path) ->
      case workspace_root.read_file(path) {
        Error(_) -> Nil
        Ok(content_bytes) ->
          case bit_array.to_string(content_bytes) {
            Error(_) -> Nil
            Ok(text) -> {
              let _ =
                pool.ensure_open(pool, "rust", workspace, file_uri, "rust", text)
              Nil
            }
          }
      }
  }
}
