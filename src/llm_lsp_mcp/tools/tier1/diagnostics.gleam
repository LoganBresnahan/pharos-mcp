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

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option
import llm_lsp_mcp/lsp/client
import llm_lsp_mcp/lsp/languages.{Pull, Push}
import llm_lsp_mcp/lsp/lifecycle
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/tools/tier1/session
import llm_lsp_mcp/tools/tier1/tool_helpers

const default_drain_window_ms: Int = 8000

const drain_step_ms: Int = 500

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
pub fn handle(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.config_for_uri(file_uri) {
    Error(err) -> Error(map_session_error(err))

    Ok(config) ->
      case session.prepare(pool, file_uri) {
        Error(err) -> Error(map_session_error(err))
        Ok(lsp) ->
          case config.diagnostics_mode {
            Push -> drain(lsp, file_uri, timeout_ms, option.None)
            Pull -> pull_diagnostics(lsp, file_uri, timeout_ms)
          }
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

fn drain(
  lsp: client.Client,
  target_uri: String,
  remaining_ms: Int,
  latest: option.Option(String),
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case remaining_ms <= 0 {
    True ->
      Ok(case latest {
        option.Some(body) -> Diagnostics(uri: target_uri, body_json: body)
        option.None -> NoDiagnosticsObserved(uri: target_uri)
      })

    False ->
      case client.next_message(lsp, drain_step_ms) {
        Error(client.PortReceiveError(_)) ->
          drain(lsp, target_uri, remaining_ms - drain_step_ms, latest)

        Error(other) ->
          Error(TransportFailed(describe_client_error(other)))

        Ok(#(body, lsp)) -> {
          let next_latest = case extract_matching_body(body, target_uri) {
            option.Some(text) -> option.Some(text)
            option.None -> latest
          }
          drain(lsp, target_uri, remaining_ms - drain_step_ms, next_latest)
        }
      }
  }
}

/// If `body` is a `textDocument/publishDiagnostics` notification for
/// `target_uri`, return the verbatim JSON text. Otherwise None.
fn extract_matching_body(
  body: BitArray,
  target_uri: String,
) -> option.Option(String) {
  case bit_array.to_string(body) {
    Error(Nil) -> option.None
    Ok(text) ->
      case json.parse(text, decode.dynamic) {
        Error(_) -> option.None
        Ok(value) ->
          case decode.run(value, publish_diagnostics_uri_decoder()) {
            Error(_) -> option.None
            Ok(uri) ->
              case uri == target_uri {
                True -> option.Some(text)
                False -> option.None
              }
          }
      }
  }
}

fn publish_diagnostics_uri_decoder() -> decode.Decoder(String) {
  use method <- decode.field("method", decode.string)
  case method == "textDocument/publishDiagnostics" {
    False -> decode.failure("", "not publishDiagnostics")
    True -> {
      use uri <- decode.subfield(["params", "uri"], decode.string)
      decode.success(uri)
    }
  }
}

// -- Pull mode (textDocument/diagnostic) ---------------------------------

fn pull_diagnostics(
  lsp: client.Client,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])

  case
    lifecycle.request(
      lsp,
      "textDocument/diagnostic",
      params,
      tool_helpers.next_id(),
      timeout_ms,
    )
  {
    Error(err) ->
      Error(TransportFailed(tool_helpers.describe_request_error(err)))

    Ok(#(_lsp, result_value)) ->
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

