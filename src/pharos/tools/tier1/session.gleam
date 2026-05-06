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
import gleam/erlang/process
import gleam/json
import gleam/result
import pharos/log
import pharos/lsp/languages.{
  type LanguageConfig, CargoWorkspacePromotion, NoPromotion,
}
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc.{type Proc}
import pharos/lsp/registry
import pharos/workspace_root

const content_modified_code: Int = -32_801

const content_modified_retry_delay_ms: Int = 1000

pub type SessionError {
  NotAFileUri(uri: String)
  WorkspaceNotFound(uri: String)
  UnsupportedFileType(uri: String)
  SpawnFailed(reason: String)
  HandshakeFailed(reason: String)
}

pub type RetryError {
  RetrySessionError(SessionError)
  RetryRequestError(lifecycle.RequestError)
}

/// Wrap a single LSP `proc.request` call with a retry-once-on-
/// content-modified policy. rust-analyzer emits `ServerError(-32801,
/// "content modified")` mid-indexing; gopls / pyright /
/// typescript-language-server do not, so the retry is a no-op for
/// them. Sleeps `content_modified_retry_delay_ms` between attempts
/// so the analyzer reaches a steady state before the second try.
///
/// Tools call this from inside `with_session_and_retry`'s body so
/// the cold-start race that surfaced as `null` / `-32801` user-facing
/// errors during the M9 dogfood becomes invisible after one retry.
pub fn request_with_content_modified_retry(
  request: fn() -> Result(a, lifecycle.RequestError),
) -> Result(a, lifecycle.RequestError) {
  case request() {
    Error(lifecycle.ServerError(code, _))
      if code == content_modified_code
    -> {
      process.sleep(content_modified_retry_delay_ms)
      request()
    }
    other -> other
  }
}

/// Run `body` against a freshly-prepared Proc, and on a transport-
/// error result evict the pool cache entry and retry once with a
/// brand-new Proc. Other error shapes (session prep failure,
/// server-error response, decode failure) propagate immediately.
///
/// This is the M9 transparent-retry surface: a transient LSP crash
/// that surfaces as `lifecycle.ClientFailure` (Port closed, send
/// failed) becomes invisible to the LLM after one auto-respawn.
/// Repeated transport errors after retry surface so the LLM can
/// route around the broken language.
pub fn with_session_and_retry(
  pool: Pool,
  file_uri: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case prepare(pool, file_uri) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(lsp) ->
      case body(lsp) {
        Ok(value) -> Ok(value)
        Error(lifecycle.ClientFailure(reason)) -> {
          log.warn_at(
            "pharos/tools/tier1/session",
            "transport error; evicting and retrying once",
          )
          let _ = reason
          retry_after_evict(pool, file_uri, body)
        }
        Error(other) -> Error(RetryRequestError(other))
      }
  }
}

fn retry_after_evict(
  pool: Pool,
  file_uri: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case lookup_config(file_uri) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(config) ->
      case discover_workspace(file_uri, config.root_markers) {
        Error(err) -> Error(RetrySessionError(err))
        Ok(raw_workspace) -> {
          let workspace = promote_root(raw_workspace, config)
          pool.evict(pool, config.id, workspace)
          case prepare(pool, file_uri) {
            Error(err) -> Error(RetrySessionError(err))
            Ok(lsp) ->
              case body(lsp) {
                Ok(value) -> Ok(value)
                Error(other) -> Error(RetryRequestError(other))
              }
          }
        }
      }
  }
}

/// Render a `RetryError` as a string the tool layer can pass to
/// `tool_text_result(_, isError=True)`. Callers that need the
/// underlying variants (e.g. to fold into their own error enum)
/// can pattern-match the `RetryError` directly.
pub fn describe_retry_error(
  err: RetryError,
  describe_session: fn(SessionError) -> String,
  describe_request: fn(lifecycle.RequestError) -> String,
) -> String {
  case err {
    RetrySessionError(s) -> describe_session(s)
    RetryRequestError(r) -> describe_request(r)
  }
}

/// Workspace-wide variant of `with_session_and_retry`: uses
/// `prepare_workspace` instead of `prepare` (no didOpen state) and
/// otherwise behaves identically — one transparent retry on
/// `lifecycle.ClientFailure`.
pub fn with_workspace_session_and_retry(
  pool: Pool,
  workspace_uri_hint: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case prepare_workspace(pool, workspace_uri_hint) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(lsp) ->
      case body(lsp) {
        Ok(value) -> Ok(value)
        Error(lifecycle.ClientFailure(_)) -> {
          log.warn_at(
            "pharos/tools/tier1/session",
            "workspace transport error; evicting and retrying once",
          )
          retry_workspace_after_evict(pool, workspace_uri_hint, body)
        }
        Error(other) -> Error(RetryRequestError(other))
      }
  }
}

/// Like `with_workspace_session_and_retry/3` but routes by an
/// explicit language id rather than parsing the URI's extension.
/// Used when the caller wants to operate on a workspace without
/// knowing or supplying a representative file (`workspace_symbols`
/// with a directory hint).
pub fn with_workspace_session_and_retry_by_language(
  pool: Pool,
  language: String,
  workspace_uri_hint: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case prepare_workspace_for_language(pool, language, workspace_uri_hint) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(lsp) ->
      case body(lsp) {
        Ok(value) -> Ok(value)
        Error(lifecycle.ClientFailure(_)) -> {
          log.warn_at(
            "pharos/tools/tier1/session",
            "workspace transport error (by-language); evicting and retrying once",
          )
          retry_workspace_for_language_after_evict(
            pool,
            language,
            workspace_uri_hint,
            body,
          )
        }
        Error(other) -> Error(RetryRequestError(other))
      }
  }
}

fn retry_workspace_for_language_after_evict(
  pool: Pool,
  language: String,
  workspace_uri_hint: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case lookup_config_by_language(language) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(config) ->
      case discover_workspace_or_dir(workspace_uri_hint, config.root_markers) {
        Error(err) -> Error(RetrySessionError(err))
        Ok(raw_workspace) -> {
          let workspace = promote_root(raw_workspace, config)
          pool.evict(pool, config.id, workspace)
          case prepare_workspace_for_language(pool, language, workspace_uri_hint) {
            Error(err) -> Error(RetrySessionError(err))
            Ok(lsp) ->
              case body(lsp) {
                Ok(value) -> Ok(value)
                Error(other) -> Error(RetryRequestError(other))
              }
          }
        }
      }
  }
}

fn retry_workspace_after_evict(
  pool: Pool,
  workspace_uri_hint: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case lookup_config(workspace_uri_hint) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(config) ->
      case discover_workspace(workspace_uri_hint, config.root_markers) {
        Error(err) -> Error(RetrySessionError(err))
        Ok(raw_workspace) -> {
          let workspace = promote_root(raw_workspace, config)
          pool.evict(pool, config.id, workspace)
          case prepare_workspace(pool, workspace_uri_hint) {
            Error(err) -> Error(RetrySessionError(err))
            Ok(lsp) ->
              case body(lsp) {
                Ok(value) -> Ok(value)
                Error(other) -> Error(RetryRequestError(other))
              }
          }
        }
      }
  }
}

/// Prepare a Proc for tools that operate on a single file. Looks
/// up the language by extension, finds the workspace root, fetches
/// the cached LSP from the pool (or spawns a fresh one), and asks
/// the pool to send `didOpen` if it has not already done so this
/// session for this (language, workspace, uri) triple.
pub fn prepare(pool: Pool, file_uri: String) -> Result(Proc, SessionError) {
  use config <- result.try(lookup_config(file_uri))
  use raw_workspace <- result.try(discover_workspace(
    file_uri,
    config.root_markers,
  ))
  let workspace = promote_root(raw_workspace, config)
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
) -> Result(Proc, SessionError) {
  use config <- result.try(lookup_config(workspace_uri_hint))
  use raw_workspace <- result.try(discover_workspace_or_dir(
    workspace_uri_hint,
    config.root_markers,
  ))
  let workspace = promote_root(raw_workspace, config)
  get_lsp(pool, config, workspace)
}

/// Like `prepare_workspace/2` but the language id is supplied
/// explicitly instead of inferred from the URI's extension. Used
/// when the natural URI is a directory (no extension to parse).
/// Workspace discovery is dir-tolerant — see
/// `workspace_root.discover_from_uri_or_dir/2`.
pub fn prepare_workspace_for_language(
  pool: Pool,
  language: String,
  workspace_uri_hint: String,
) -> Result(Proc, SessionError) {
  use config <- result.try(lookup_config_by_language(language))
  use raw_workspace <- result.try(discover_workspace_or_dir(
    workspace_uri_hint,
    config.root_markers,
  ))
  let workspace = promote_root(raw_workspace, config)
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
  registry.for_uri(uri)
  |> result.map_error(fn(err) {
    case err {
      languages.NotAFileUri(u) -> NotAFileUri(u)
      languages.UnknownLanguage(u) -> UnsupportedFileType(u)
    }
  })
}

fn lookup_config_by_language(
  language: String,
) -> Result(LanguageConfig, SessionError) {
  registry.for_language(language)
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

fn discover_workspace_or_dir(
  uri: String,
  markers: List(String),
) -> Result(String, SessionError) {
  workspace_root.discover_from_uri_or_dir(uri, markers)
  |> result.map_error(fn(err) {
    case err {
      workspace_root.NotAFileUri(u) -> NotAFileUri(u)
      workspace_root.NoMarkerFound -> WorkspaceNotFound(uri)
    }
  })
}

/// Apply the language's `root_promotion` strategy to a discovered
/// workspace root. Per ADR-015. Pure function; no IO when the
/// strategy is `NoPromotion`.
fn promote_root(raw: String, config: LanguageConfig) -> String {
  case config.root_promotion {
    NoPromotion -> raw
    CargoWorkspacePromotion -> workspace_root.promote_to_cargo_workspace(raw)
  }
}

fn get_lsp(
  pool: Pool,
  config: LanguageConfig,
  workspace: String,
) -> Result(Proc, SessionError) {
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
      pool.ProcStartFailed(reason) -> SpawnFailed(reason)
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
    #("capabilities", build_client_capabilities()),
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

/// LSP `ClientCapabilities` advertised at handshake. Until M8 Stage 2
/// pharos sent `{}` here, which is spec-legal but caused several
/// servers (rust-analyzer in particular) to silently degrade for
/// methods the client did not opt into. Empirically:
///   - signature_help, format_document, code_actions all timed out
///     against rust-analyzer with empty capabilities; declaring the
///     matching textDocument.* capabilities made them respond.
///   - tsserver still gates publishDiagnostics on
///     workspace/didChangeConfiguration regardless of declared
///     capabilities (Stage 0C handles that separately).
///
/// Capabilities below cover everything pharos's Tier 1 + Tier 2
/// surface exercises. New tools added later may need to extend this
/// payload. Marked `pub` so unit tests can introspect the JSON shape.
pub fn build_client_capabilities() -> json.Json {
  json.object([
    #("workspace", workspace_capabilities()),
    #("textDocument", text_document_capabilities()),
  ])
}

fn workspace_capabilities() -> json.Json {
  json.object([
    #("applyEdit", json.bool(True)),
    #(
      "workspaceEdit",
      json.object([
        #("documentChanges", json.bool(True)),
        #(
          "resourceOperations",
          json.preprocessed_array([
            json.string("create"),
            json.string("rename"),
            json.string("delete"),
          ]),
        ),
        #("failureHandling", json.string("abort")),
      ]),
    ),
    #(
      "didChangeConfiguration",
      json.object([#("dynamicRegistration", json.bool(False))]),
    ),
    #("configuration", json.bool(True)),
    #(
      "symbol",
      json.object([#("dynamicRegistration", json.bool(False))]),
    ),
  ])
}

fn text_document_capabilities() -> json.Json {
  json.object([
    #(
      "synchronization",
      json.object([
        #("dynamicRegistration", json.bool(False)),
        #("willSave", json.bool(False)),
        #("didSave", json.bool(False)),
      ]),
    ),
    #(
      "hover",
      json.object([
        #(
          "contentFormat",
          json.preprocessed_array([
            json.string("markdown"),
            json.string("plaintext"),
          ]),
        ),
      ]),
    ),
    #(
      "signatureHelp",
      json.object([
        #(
          "signatureInformation",
          json.object([
            #(
              "documentationFormat",
              json.preprocessed_array([
                json.string("markdown"),
                json.string("plaintext"),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "definition",
      json.object([#("linkSupport", json.bool(True))]),
    ),
    #(
      "typeDefinition",
      json.object([#("linkSupport", json.bool(True))]),
    ),
    #(
      "implementation",
      json.object([#("linkSupport", json.bool(True))]),
    ),
    #("references", json.object([])),
    #(
      "documentSymbol",
      json.object([
        #("hierarchicalDocumentSymbolSupport", json.bool(True)),
      ]),
    ),
    #(
      "formatting",
      json.object([#("dynamicRegistration", json.bool(False))]),
    ),
    #(
      "rename",
      json.object([#("prepareSupport", json.bool(False))]),
    ),
    #(
      "codeAction",
      json.object([
        #(
          "codeActionLiteralSupport",
          json.object([
            #(
              "codeActionKind",
              json.object([
                #(
                  "valueSet",
                  json.preprocessed_array([
                    json.string(""),
                    json.string("quickfix"),
                    json.string("refactor"),
                    json.string("refactor.extract"),
                    json.string("refactor.inline"),
                    json.string("refactor.rewrite"),
                    json.string("source"),
                    json.string("source.organizeImports"),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "callHierarchy",
      json.object([#("dynamicRegistration", json.bool(False))]),
    ),
    #(
      "publishDiagnostics",
      json.object([#("versionSupport", json.bool(False))]),
    ),
    #(
      "diagnostic",
      json.object([#("dynamicRegistration", json.bool(False))]),
    ),
    #(
      "inlayHint",
      json.object([#("dynamicRegistration", json.bool(False))]),
    ),
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
