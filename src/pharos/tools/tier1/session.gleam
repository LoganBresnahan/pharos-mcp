//// Common prelude for tier-1 tools.
////
//// Every tier-1 LSP-backed tool needs the same boilerplate:
////   1. Look up the LSP config for the file's language (via
////      `lsp/languages`).
////   2. Discover the workspace root by walking up to that language's
////      configured root markers.
////   3. Fetch a Client from the kept-warm pool (spawn + initialize
////      on cache miss, return cached on hit).
////   4. Send `textDocument/didOpen` so the LSP knows about the file
////      (idempotent thanks to the pool's didOpen-once tracking).
////
//// `prepare/2` does all of that and returns a Client ready for the
//// tool's specific LSP method to call. Tool implementations
//// (`hover`, `goto_definition`, etc.) stay focused on building
//// params and rendering the response.

import gleam/bit_array
import gleam/json
import gleam/result
import pharos/lsp/client.{type Client}
import pharos/lsp/languages.{type LanguageConfig}
import pharos/lsp/pool.{type Pool}
import pharos/workspace_root

pub type SessionError {
  NotAFileUri(uri: String)
  WorkspaceNotFound(uri: String)
  UnsupportedFileType(uri: String)
  SpawnFailed(reason: String)
  HandshakeFailed(reason: String)
}

/// Prepare a Client for tools that operate on a single file. Looks
/// up the language by extension, finds the workspace root, fetches
/// the cached LSP from the pool (or spawns a fresh one), and asks
/// the pool to send `didOpen` if it has not already done so this
/// session for this (language, workspace, uri) triple.
pub fn prepare(pool: Pool, file_uri: String) -> Result(Client, SessionError) {
  use config <- result.try(lookup_config(file_uri))
  use workspace <- result.try(discover_workspace(file_uri, config.root_markers))
  use lsp <- result.try(get_lsp(pool, config, workspace))
  let _ = ensure_doc_opened(pool, config, workspace, file_uri)
  Ok(lsp)
}

/// Variant for tools that operate workspace-wide
/// (`workspace_symbols`) rather than on a specific file. Looks up
/// the language by the URI hint, discovers the workspace root,
/// fetches the LSP. Skips didOpen since no file is being focused.
pub fn prepare_workspace(
  pool: Pool,
  workspace_uri_hint: String,
) -> Result(Client, SessionError) {
  use config <- result.try(lookup_config(workspace_uri_hint))
  use workspace <- result.try(discover_workspace(
    workspace_uri_hint,
    config.root_markers,
  ))
  get_lsp(pool, config, workspace)
}

/// Public form of the internal config lookup. Tools that need to
/// branch on per-language behavior (e.g. push vs pull diagnostics)
/// call this with the file URI; everything else stays inside
/// `prepare/2`.
pub fn config_for_uri(uri: String) -> Result(LanguageConfig, SessionError) {
  lookup_config(uri)
}

// -- Internals ----------------------------------------------------------

fn lookup_config(uri: String) -> Result(LanguageConfig, SessionError) {
  languages.for_uri(languages.default_registry(), uri)
  |> result.map_error(fn(err) {
    case err {
      languages.NotAFileUri(u) -> NotAFileUri(u)
      languages.UnknownLanguage(u) -> UnsupportedFileType(u)
    }
  })
}

fn discover_workspace(
  file_uri: String,
  markers: List(String),
) -> Result(String, SessionError) {
  workspace_root.discover_from_uri(file_uri, markers)
  |> result.map_error(fn(err) {
    case err {
      workspace_root.NotAFileUri(uri) -> NotAFileUri(uri)
      workspace_root.NoMarkerFound -> WorkspaceNotFound(file_uri)
    }
  })
}

fn get_lsp(
  pool: Pool,
  config: LanguageConfig,
  workspace: String,
) -> Result(Client, SessionError) {
  let spec =
    pool.SpawnSpec(
      command: config.command,
      args: config.args,
      init_params: build_initialize_params(workspace, config),
      workspace_configuration: config.workspace_configuration,
    )
  pool.get(pool, config.id, workspace, spec)
  |> result.map_error(fn(err) {
    case err {
      pool.StartFailed(_) ->
        SpawnFailed(
          "LSP failed to spawn (command: " <> config.command <> ")",
        )
      pool.HandshakeFailed(_) ->
        HandshakeFailed("LSP initialize handshake failed")
    }
  })
}

fn build_initialize_params(
  workspace_path: String,
  config: LanguageConfig,
) -> json.Json {
  let root_uri = workspace_root.path_to_uri(workspace_path)
  json.object([
    #("processId", json.null()),
    #("rootUri", json.string(root_uri)),
    #("rootPath", json.string(workspace_path)),
    #("capabilities", json.object([])),
    #(
      "clientInfo",
      json.object([
        #("name", json.string("pharos")),
        #("version", json.string("0.0.1")),
      ]),
    ),
    #("initializationOptions", config.initialization_options),
  ])
}

/// Read file content from disk and ask the pool to send didOpen if
/// it has not already done so for this triple. Best-effort —
/// failures (file gone, content not utf-8, pool busy) are swallowed
/// since the subsequent LSP request will surface a real error if
/// the document state is genuinely missing.
fn ensure_doc_opened(
  pool: Pool,
  config: LanguageConfig,
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
                pool.ensure_open(
                  pool,
                  config.id,
                  workspace,
                  file_uri,
                  config.id,
                  text,
                )
              Nil
            }
          }
      }
  }
}
