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
import gleam/list
import gleam/option
import gleam/result
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/languages.{
  type LanguageConfig, CargoWorkspacePromotion, NoPromotion,
}
import pharos/lsp/lifecycle
import pharos/lsp/pool.{type Pool}
import pharos/lsp/post_didopen_drained
import pharos/lsp/proc.{type Proc}
import pharos/lsp/registry
import pharos/workspace_root

const content_modified_code: Int = -32_801

/// Linear backoff between content-modified retries. Two retries
/// total: 1s after the first failure, 3s after the second. Total
/// extra wait worst-case is 4s — well within every tool's 30s+
/// per-call budget. Two retries (rather than one) cover ELP's
/// "still loading" semantic where the LSP uses -32801 to mean
/// "I'm indexing, try again later" rather than rust-analyzer's
/// stricter "content modified mid-request" — ELP cold-start can
/// take 5-30s and a single 1s retry is too tight.
///
/// Promotion to a TOML knob (`[tool_config.<name>] retry_delays_ms`
/// + per-lang variant) deferred until a real user case surfaces.
/// Per-call `timeout_ms` and `[tool_config.<name>.<lang>]
/// default_timeout_ms` already govern total wait; this constant is
/// internal cadence within that budget. If a custom LSP emits
/// -32801 with longer-than-4s clear time and the existing knobs
/// can't cover it, extend `ToolConfig` (config.gleam) with a
/// `retry_delays_ms: Option(List(Int))` field and read it here.
const content_modified_retry_delays_ms: List(Int) = [1000, 3000]

// Per-server `readiness_timeout_ms` lives on `ServerConfig` now. The
// global default is `languages.default_readiness_timeout_ms` (30s).
// `server_readiness_timeout_ms/1` resolves the two below.

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

/// Wrap a single LSP `proc.request` call with a retry-on-content-
/// modified policy. rust-analyzer emits `ServerError(-32801,
/// "content modified")` mid-indexing; ELP uses the same code with
/// `"still loading"` to mean "I'm indexing, try again later".
/// gopls / pyright / typescript-language-server don't emit -32801
/// so the retry is a no-op for them.
///
/// Two retries, with linear backoff: 1s after the first failure,
/// 3s after the second. Two (not one) covers ELP's slower cold-
/// start; the 4s worst-case extra wait stays within every tool's
/// 30s+ per-call budget.
pub fn request_with_content_modified_retry(
  request: fn() -> Result(a, lifecycle.RequestError),
) -> Result(a, lifecycle.RequestError) {
  retry_loop(request, content_modified_retry_delays_ms)
}

fn retry_loop(
  request: fn() -> Result(a, lifecycle.RequestError),
  remaining_delays: List(Int),
) -> Result(a, lifecycle.RequestError) {
  let result = request()
  case result {
    Error(lifecycle.ServerError(code, _))
      if code == content_modified_code
    ->
      case remaining_delays {
        // Out of retries — surface the last -32801.
        [] -> result
        [delay, ..rest] -> {
          process.sleep(delay)
          retry_loop(request, rest)
        }
      }
    _ -> result
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
            "pharos/tools/session",
            "transport error; evicting and retrying once",
          )
          let _ = reason
          retry_after_evict(pool, file_uri, body)
        }
        Error(other) -> Error(RetryRequestError(other))
      }
  }
}

/// Method-aware variant of `with_session_and_retry/3`. Picks the
/// server whose `MethodScope` covers `method` (per ADR-019 routing)
/// instead of the language's primary server. Used by tools whose
/// answer may live with a non-primary server — e.g. `format_document`
/// routes through ruff for python files because pyright returns
/// `-32601` for `textDocument/formatting`.
pub fn with_session_and_retry_for_method(
  pool: Pool,
  file_uri: String,
  method: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case prepare_for_method(pool, file_uri, method) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(lsp) ->
      case body(lsp) {
        Ok(value) -> Ok(value)
        Error(lifecycle.ClientFailure(reason)) -> {
          log.fields_at(
            "pharos/tools/session",
            log_entry.Warn,
            "transport error; evicting and retrying once",
            [#("method", method)],
          )
          let _ = reason
          retry_for_method_after_evict(pool, file_uri, method, body)
        }
        Error(other) -> Error(RetryRequestError(other))
      }
  }
}

fn retry_for_method_after_evict(
  pool: Pool,
  file_uri: String,
  method: String,
  body: fn(Proc) -> Result(a, lifecycle.RequestError),
) -> Result(a, RetryError) {
  case lookup_config(file_uri) {
    Error(err) -> Error(RetrySessionError(err))
    Ok(config) ->
      case discover_workspace(file_uri, config.root_markers) {
        Error(err) -> Error(RetrySessionError(err))
        Ok(raw_workspace) -> {
          let workspace = promote_root(raw_workspace, config)
          pool.evict_all_servers(pool, config.id, workspace)
          case prepare_for_method(pool, file_uri, method) {
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
          pool.evict_all_servers(pool, config.id, workspace)
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
            "pharos/tools/session",
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
          log.fields_at(
            "pharos/tools/session",
            log_entry.Warn,
            "workspace transport error (by-language); evicting and retrying once",
            [
              #("language", language),
              #("workspace_uri_hint", workspace_uri_hint),
            ],
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
          pool.evict_all_servers(pool, config.id, workspace)
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
          pool.evict_all_servers(pool, config.id, workspace)
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
  let _ = drain_post_didopen_if_needed_primary(lsp, config, workspace)
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

/// Prepare a single Proc for the server that owns `method` under
/// the `Primary` routing strategy. Per ADR-019: Only-scope wins
/// first, then All-scope. Used by tools that have one canonical
/// answer (hover, goto_*, formatting, references, …).
pub fn prepare_for_method(
  pool: Pool,
  file_uri: String,
  method: String,
) -> Result(Proc, SessionError) {
  use config <- result.try(lookup_config(file_uri))
  use raw_workspace <- result.try(discover_workspace(
    file_uri,
    config.root_markers,
  ))
  let workspace = promote_root(raw_workspace, config)
  case languages.primary_server_for_method(config, method) {
    Error(_) ->
      Error(SpawnFailed(
        "no server in language `"
          <> config.id
          <> "` claims method `"
          <> method
          <> "` (check pharos.toml [languages."
          <> config.id
          <> "])",
      ))
    Ok(server) ->
      // Mirror the M11 merge-path order fix (c001c4d): pool.ensure_open
      // returns NoCachedClient when the proc has not been spawned yet,
      // and the result is silently dropped. So get_lsp_for_server runs
      // FIRST, then ensure_doc_opened_for_server_id targets the
      // method-specific server (which may not be the language's
      // primary), then drain the post-didOpen indexing burst once per
      // (server, workspace).
      case get_lsp_for_server(pool, config, workspace, server) {
        Ok(lsp) -> {
          let _ =
            ensure_doc_opened_for_server_id(
              pool,
              config,
              workspace,
              file_uri,
              server.id,
            )
          let _ = drain_post_didopen_if_needed(lsp, server, workspace)
          Ok(lsp)
        }
        Error(err) -> Error(err)
      }
  }
}

/// Prepare every Proc whose server scope is **preferred** for
/// `method` — Only-first-then-All. Used by `FanOut` strategy
/// (`textDocument/codeAction`). Spawn failures for individual
/// servers are warn-logged and skipped — the caller gets the
/// surviving subset so a missing ruff binary doesn't hide pyright's
/// contribution.
pub fn prepare_all_for_method(
  pool: Pool,
  file_uri: String,
  method: String,
) -> Result(List(#(String, Proc)), SessionError) {
  prepare_all_with_selector(pool, file_uri, method, fn(c, m) {
    languages.servers_for_method(c, m)
  })
}

/// Prepare every Proc whose scope **covers** `method` — both
/// Only-with-match AND every All-scope server. Used by `Merge`
/// strategy (`textDocument/diagnostic`) where each claiming server
/// contributes a subset of items to the merged response. Returns
/// `(server_config, proc)` pairs so callers can read per-server
/// metadata (e.g. `diagnostics_mode`) without re-looking up the
/// language config.
pub fn prepare_all_covering_method(
  pool: Pool,
  file_uri: String,
  method: String,
) -> Result(List(#(languages.ServerConfig, Proc)), SessionError) {
  use config <- result.try(lookup_config(file_uri))
  use raw_workspace <- result.try(discover_workspace(
    file_uri,
    config.root_markers,
  ))
  let workspace = promote_root(raw_workspace, config)
  let servers = languages.servers_covering_method(config, method)
  let prepared =
    list.filter_map(servers, fn(server) {
      // Spawn the LSP first — pool.ensure_open requires the proc to
      // already be cached (`NoCachedClient` otherwise) so didOpen
      // must come AFTER get_lsp_for_server, not before.
      case get_lsp_for_server(pool, config, workspace, server) {
        Ok(proc) -> {
          // M11 fix: didOpen targets THIS server, not the language's
          // primary. Without per-server didOpen, secondary servers
          // (ruff in python's pyright+ruff pair) never receive
          // document state and `textDocument/diagnostic` against
          // them surfaces as a transport error in the merge path.
          let _ =
            ensure_doc_opened_for_server_id(
              pool,
              config,
              workspace,
              file_uri,
              server.id,
            )
          let _ = drain_post_didopen_if_needed(proc, server, workspace)
          Ok(#(server, proc))
        }
        Error(err) -> {
          log.fields_at(
            "pharos/tools/session",
            log_entry.Warn,
            "skipping server for method",
            [
              #("server", server.id),
              #("method", method),
              #("reason", describe_session_error(err)),
            ],
          )
          Error(Nil)
        }
      }
    })
  Ok(prepared)
}

fn prepare_all_with_selector(
  pool: Pool,
  file_uri: String,
  method: String,
  select_servers: fn(LanguageConfig, String) -> List(languages.ServerConfig),
) -> Result(List(#(String, Proc)), SessionError) {
  use config <- result.try(lookup_config(file_uri))
  use raw_workspace <- result.try(discover_workspace(
    file_uri,
    config.root_markers,
  ))
  let workspace = promote_root(raw_workspace, config)
  let servers = select_servers(config, method)
  let prepared =
    list.filter_map(servers, fn(server) {
      case get_lsp_for_server(pool, config, workspace, server) {
        Ok(proc) -> {
          let _ =
            ensure_doc_opened_for_server_id(
              pool,
              config,
              workspace,
              file_uri,
              server.id,
            )
          let _ = drain_post_didopen_if_needed(proc, server, workspace)
          Ok(#(server.id, proc))
        }
        Error(err) -> {
          log.fields_at(
            "pharos/tools/session",
            log_entry.Warn,
            "skipping server for method",
            [
              #("server", server.id),
              #("method", method),
              #("reason", describe_session_error(err)),
            ],
          )
          Error(Nil)
        }
      }
    })
  Ok(prepared)
}

/// Render a `SessionError` as a string for logging. Tool-side error
/// rendering uses each tool's bespoke describe function; this is the
/// internal fallback used by `prepare_all_for_method`.
fn describe_session_error(err: SessionError) -> String {
  case err {
    NotAFileUri(uri) -> "uri must start with file:// — got: " <> uri
    WorkspaceNotFound(uri) ->
      "no workspace root marker found ascending from " <> uri
    SpawnFailed(reason) -> "LSP spawn failed: " <> reason
    HandshakeFailed(reason) -> "initialize handshake failed: " <> reason
    UnsupportedFileType(uri) -> "unsupported file type: " <> uri
  }
}

fn get_lsp_for_server(
  pool: Pool,
  config: LanguageConfig,
  workspace: String,
  server: languages.ServerConfig,
) -> Result(Proc, SessionError) {
  let spec =
    pool.SpawnSpec(
      server_id: server.id,
      command: server.command,
      args: server.args,
      init_params: build_initialize_params(workspace, config, server),
      workspace_configuration: server.workspace_configuration,
      readiness_token: server.readiness_token,
      readiness_timeout_ms: server_readiness_timeout_ms(server),
      initialize_timeout_ms: server_initialize_timeout_ms(server),
    )
  pool.get(pool, config.id, workspace, spec)
  |> result.map_error(fn(err) {
    case err {
      pool.ProcStartFailed(reason) -> SpawnFailed(reason)
    }
  })
}

/// Resolve the per-server readiness drain budget. ServerConfig's
/// override wins; otherwise fall back to the bundled default.
fn server_readiness_timeout_ms(server: languages.ServerConfig) -> Int {
  case server.readiness_timeout_ms {
    option.Some(n) -> n
    option.None -> languages.default_readiness_timeout_ms
  }
}

/// Resolve the per-server initialize handshake budget. Same shape as
/// readiness — ServerConfig override wins; default covers most.
fn server_initialize_timeout_ms(server: languages.ServerConfig) -> Int {
  case server.initialize_timeout_ms {
    option.Some(n) -> n
    option.None -> languages.default_initialize_timeout_ms
  }
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
  case languages.primary_server(config) {
    Error(_) ->
      Error(SpawnFailed(
        "language `"
          <> config.id
          <> "` has no servers configured (check pharos.toml)",
      ))
    Ok(server) -> {
      let spec =
        pool.SpawnSpec(
          server_id: server.id,
          command: server.command,
          args: server.args,
          init_params: build_initialize_params(workspace, config, server),
          workspace_configuration: server.workspace_configuration,
          readiness_token: server.readiness_token,
          readiness_timeout_ms: server_readiness_timeout_ms(server),
          initialize_timeout_ms: server_initialize_timeout_ms(server),
        )
      pool.get(pool, config.id, workspace, spec)
      |> result.map_error(fn(err) {
        case err {
          pool.ProcStartFailed(reason) -> SpawnFailed(reason)
        }
      })
    }
  }
}

fn build_initialize_params(
  workspace_path: String,
  _config: LanguageConfig,
  server: languages.ServerConfig,
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
    #("initializationOptions", server.initialization_options),
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
  let server_id = case languages.primary_server(config) {
    Ok(server) -> server.id
    Error(_) -> config.id
  }
  ensure_doc_opened_for_server_id(pool, config, workspace, file_uri, server_id)
}

/// Drain the post-didOpen indexing burst for `(server.id, workspace)`
/// once. rust-analyzer (and any LSP whose `readiness_token` matches
/// indexing progress) only starts indexing AFTER didOpen — the
/// post-handshake `wait_for_ready` in proc's initialiser sees no
/// progress to wait on. Without this second drain the first request
/// races indexing and surfaces as `null` or `-32801 content modified`.
///
/// Servers without a `readiness_token` (typescript-language-server,
/// ruff) skip the drain — `proc.wait_for_ready` is a no-op for them.
///
/// Idempotent: subsequent calls for the same `(server.id, workspace)`
/// pair short-circuit on the ETS-backed marker. wait_for_ready Error
/// returns leave the entry absent so the next call retries (matches
/// the transport-error retry semantics in `with_session_and_retry`).
/// Poll interval for non-claiming workers waiting on the drainer to
/// finish. ETS lookups are cheap; 100ms keeps wakeup latency low
/// without burning CPU.
const drain_poll_interval_ms: Int = 100

/// Maximum time a non-claiming worker waits for the drainer to mark
/// done before proceeding anyway. If drainer fails or stalls, the
/// content-modified retry path absorbs the residual race.
const drain_wait_budget_ms: Int = 45_000

fn drain_post_didopen_if_needed(
  lsp: Proc,
  server: languages.ServerConfig,
  workspace: String,
) -> Nil {
  case post_didopen_drained.is_done(server.id, workspace) {
    True -> Nil
    False ->
      case post_didopen_drained.try_claim(server.id, workspace) {
        True ->
          drain_and_mark(lsp, server, workspace, server_readiness_timeout_ms(server))
        // Lost the race — another worker is already draining. Block
        // until they mark done so our subsequent proc.request does NOT
        // queue behind the drainer's WaitForReady in the proc actor's
        // mailbox (which would expire proc.request's small actor.call
        // timeout — `5s + 5s buffer` for hover/document_symbols — and
        // crash the worker silently). Polling stays out of the proc
        // actor; the drainer alone serializes through it.
        False -> wait_for_drain_done(server, workspace, drain_wait_budget_ms)
      }
  }
}

fn drain_and_mark(
  lsp: Proc,
  server: languages.ServerConfig,
  workspace: String,
  timeout_ms: Int,
) -> Nil {
  case
    proc.wait_for_ready(lsp, server.readiness_token, timeout_ms)
  {
    Ok(_) -> post_didopen_drained.mark_done(server.id, workspace)
    // Drain failed (transport error). Leave claim in place so future
    // workers don't redrive — the proc itself is broken and the M9
    // retry-on-transport-error wrapper at the tool layer spawns a
    // fresh proc.
    Error(_) -> Nil
  }
}

fn wait_for_drain_done(
  server: languages.ServerConfig,
  workspace: String,
  remaining_ms: Int,
) -> Nil {
  case remaining_ms <= 0 {
    True -> Nil
    False ->
      case post_didopen_drained.is_done(server.id, workspace) {
        True -> Nil
        False -> {
          process.sleep(drain_poll_interval_ms)
          wait_for_drain_done(server, workspace, remaining_ms - drain_poll_interval_ms)
        }
      }
  }
}

/// Like `drain_post_didopen_if_needed/3` but resolves the language's
/// primary server first. Used by single-server prepare paths
/// (`prepare/2`, `prepare_for_method/3`) where the caller has the
/// LanguageConfig but not a specific ServerConfig.
fn drain_post_didopen_if_needed_primary(
  lsp: Proc,
  config: LanguageConfig,
  workspace: String,
) -> Nil {
  case languages.primary_server(config) {
    Ok(server) -> drain_post_didopen_if_needed(lsp, server, workspace)
    Error(_) -> Nil
  }
}

/// Like `ensure_doc_opened/4` but targets one explicit `server_id`
/// instead of the language's primary. Used by the multi-server merge
/// path so every covering server receives `didOpen` (M11 fix —
/// without it, ruff in the python pyright+ruff pair never got the
/// document state and the merge path's diagnostic request hit a
/// transport error).
fn ensure_doc_opened_for_server_id(
  pool: Pool,
  config: LanguageConfig,
  workspace: String,
  file_uri: String,
  server_id: String,
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
                  server_id,
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
