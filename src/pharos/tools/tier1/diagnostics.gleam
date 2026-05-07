//// MCP tool: `get_diagnostics`.
////
//// Returns LSP diagnostics (errors and warnings) for a file URI.
//// Implementation branches on the language's `diagnostics_mode`:
////
////   - `Push` (rust-analyzer, gopls, pyright): drain incoming
////     `textDocument/publishDiagnostics` notifications for a fixed
////     window and return the latest match.
////
////   - `Pull` (typescript-language-server): send a synchronous
////     `textDocument/diagnostic` request (LSP 3.17+) and return
////     the response's items. Used for servers that do not push
////     publishDiagnostics on their own — the only way to get the
////     diagnostic data out of them is to ask explicitly.
////
//// In both cases the result body is shaped as a synthetic
//// `textDocument/publishDiagnostics` envelope so the MCP caller
//// reads identical JSON structure regardless of which transport
//// the LSP supports.

import gleam/dynamic/decode
import gleam/json
import gleam/option
import pharos/log
import pharos/lsp/client
import pharos/lsp/diagnostics_cache
import pharos/lsp/languages.{type LanguageConfig, Pull, Push}
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc
import pharos/tools/tier1/session
import pharos/tools/tier1/tool_helpers
import pharos/workspace_root

const default_drain_window_ms: Int = 8000

pub type DiagnosticsError {
  /// File URI did not have a `file://` prefix.
  NotAFileUri(uri: String)
  /// Walked the directory tree without finding any registered root
  /// marker for the language.
  WorkspaceNotFound(uri: String)
  /// LSP subprocess could not be spawned.
  SpawnFailed(reason: String)
  /// Initialize handshake failed.
  HandshakeFailed(reason: String)
  /// I/O error while waiting for diagnostics.
  TransportFailed(reason: String)
  /// Tool was called on a file with an unsupported extension.
  UnsupportedFileType(uri: String)
}

pub type DiagnosticsResult {
  /// Server published or returned diagnostics for the file.
  /// `body_json` is a `textDocument/publishDiagnostics`-shaped
  /// envelope — verbatim from the server in push mode, synthesized
  /// from the pull response in pull mode.
  Diagnostics(uri: String, body_json: String)
  /// Window expired with no diagnostics for the requested URI in
  /// push mode, OR the pull response had no items. Caller can
  /// interpret as "no diagnostics available" — useful info for the
  /// LLM either way.
  NoDiagnosticsObserved(uri: String)
}

/// Run get_diagnostics for one URI. Looks up the language config to
/// decide whether to drain (push mode) or to send a pull request,
/// then returns the result in publishDiagnostics envelope shape.
///
/// Stage 2 second-pass C: before draining, check the diagnostics
/// cache. The lifecycle classifier writes there on every inbound
/// publishDiagnostics, so a hit means the server already told us
/// the answer (typically on first didOpen) and we can return
/// without waiting. Cache misses fall back to the live drain or
/// pull request, and the captured value is written to cache so
/// subsequent calls hit.
pub fn handle(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.config_for_uri(file_uri) {
    Error(err) -> Error(map_session_error(err))
    Ok(config) -> attempt(pool, file_uri, config, timeout_ms, retries_left: 1)
  }
}

/// Single attempt at diagnostics extraction. On `TransportFailed`
/// (proc actor dead, Port closed mid-drain), evict the pool entry
/// for this language+workspace and recurse once with a fresh
/// session. Other error variants (NotAFileUri, WorkspaceNotFound,
/// SpawnFailed, HandshakeFailed, UnsupportedFileType) propagate
/// without retry — they would not be fixed by a fresh proc.
fn attempt(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
  timeout_ms: Int,
  retries_left retries_left: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(map_session_error(err))
    Ok(lsp) ->
      case lookup_cached(file_uri) {
        option.Some(body_json) ->
          Ok(Diagnostics(uri: file_uri, body_json: body_json))

        option.None -> {
          // Stage 1 of ADR-019: pick the primary (first) server's
          // diagnostics_mode. Stage 3 routes diagnostics through
          // every server with `Only(["textDocument/diagnostic"])` or
          // `All` scope and merges results.
          let mode = case languages.primary_server(config) {
            Ok(server) -> server.diagnostics_mode
            Error(_) -> Push
          }
          let result = case mode {
            Push -> push_drain(lsp, file_uri, timeout_ms)
            Pull -> pull_diagnostics(lsp, file_uri, timeout_ms)
          }
          case result, retries_left > 0 {
            Error(TransportFailed(_)), True -> {
              log.warn_at(
                "pharos/tools/tier1/diagnostics",
                "transport error during diagnostics; evicting and retrying once",
              )
              evict_for_uri(pool, file_uri, config)
              attempt(pool, file_uri, config, timeout_ms, retries_left: retries_left - 1)
            }
            _, _ -> result
          }
        }
      }
  }
}

fn evict_for_uri(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
) -> Nil {
  case workspace_root.discover_from_uri(file_uri, config.root_markers) {
    Error(_) -> Nil
    Ok(raw_workspace) -> {
      // Apply the same root-promotion the prepare path uses
      // (ADR-015) so we evict the actual cache key, not the
      // un-promoted innermost crate dir.
      let workspace = case config.root_promotion {
        languages.NoPromotion -> raw_workspace
        languages.CargoWorkspacePromotion ->
          workspace_root.promote_to_cargo_workspace(raw_workspace)
      }
      pool.evict(pool, config.id, workspace)
    }
  }
}

/// Read the diagnostics cache and re-encode the entry as a synthetic
/// `textDocument/publishDiagnostics` envelope so tool callers see the
/// same JSON shape whether the body came from cache, push, or pull.
fn lookup_cached(file_uri: String) -> option.Option(String) {
  case diagnostics_cache.get(file_uri) {
    Error(_) -> option.None
    Ok(params_value) -> {
      let envelope =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
        <> "\"params\":"
        <> tool_helpers.json_encode(params_value)
        <> "}"
      option.Some(envelope)
    }
  }
}

pub fn handle_with_default_timeout(
  pool: Pool,
  file_uri: String,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  handle(pool, file_uri, default_drain_window_ms)
}

// -- Push mode (drain) ---------------------------------------------------

/// Cache miss + Push-mode language: ask the proc to drain inbound
/// notifications inside its actor (where the Port owner lives) and
/// return the first publishDiagnostics for the target URI. The
/// proc's drain also writes every observed publishDiagnostics into
/// the diagnostics cache as a side effect, populating it for future
/// hits.
fn push_drain(
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case proc.wait_for_publish_diagnostics(lsp, file_uri, timeout_ms) {
    Error(err) ->
      Error(TransportFailed(
        "publishDiagnostics drain failed: " <> describe_client_error(err),
      ))
    Ok(option.None) -> Ok(NoDiagnosticsObserved(uri: file_uri))
    Ok(option.Some(body)) -> Ok(Diagnostics(uri: file_uri, body_json: body))
  }
}

// -- Pull mode (textDocument/diagnostic) ---------------------------------

fn pull_diagnostics(
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])

  case
    session.request_with_content_modified_retry(fn() {
      proc.request(lsp, "textDocument/diagnostic", params, timeout_ms)
    })
  {
    Error(err) ->
      Error(TransportFailed(tool_helpers.describe_request_error(err)))

    Ok(result_value) ->
      case decode.run(result_value, full_report_items_decoder()) {
        Error(decode_errs) ->
          Error(TransportFailed(
            "diagnostic response decode failed: "
            <> describe_decode_errors(decode_errs),
          ))

        Ok(items_json) ->
          case items_json == "[]" {
            True -> Ok(NoDiagnosticsObserved(uri: file_uri))
            False ->
              Ok(Diagnostics(
                uri: file_uri,
                body_json: synthesize_publish_body(file_uri, items_json),
              ))
          }
      }
  }
}

/// Decoder for the LSP `DocumentDiagnosticReport` (3.17+):
///   {kind: "full", items: [...], resultId?: "..."} or
///   {kind: "unchanged", resultId: "..."}
/// Returns the items as a JSON string, or "[]" for "unchanged" since
/// we have no prior result cached.
fn full_report_items_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "full" -> {
      use items <- decode.field("items", decode.dynamic)
      decode.success(tool_helpers.json_encode(items))
    }
    "unchanged" -> decode.success("[]")
    _ -> decode.failure("[]", "unknown report kind: " <> kind)
  }
}

fn synthesize_publish_body(uri: String, items_json: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
  <> "\"params\":{\"uri\":\""
  <> uri
  <> "\",\"diagnostics\":"
  <> items_json
  <> "}}"
}

// -- Error description helpers -------------------------------------------

fn map_session_error(err: session.SessionError) -> DiagnosticsError {
  case err {
    session.NotAFileUri(uri) -> NotAFileUri(uri)
    session.WorkspaceNotFound(uri) -> WorkspaceNotFound(uri)
    session.UnsupportedFileType(uri) -> UnsupportedFileType(uri)
    session.SpawnFailed(reason) -> SpawnFailed(reason)
    session.HandshakeFailed(reason) -> HandshakeFailed(reason)
  }
}

fn describe_client_error(err: client.Error) -> String {
  case err {
    client.PortReceiveError(_) -> "port receive error"
    client.PortSendError(_) -> "port send error"
    client.FramingError(_) -> "framing error"
    client.SpawnError(_) -> "spawn error"
  }
}

fn describe_decode_errors(errs: List(decode.DecodeError)) -> String {
  case errs {
    [] -> "no error info"
    [first, ..] -> first.expected <> " (got " <> first.found <> ")"
  }
}

