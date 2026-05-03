//// MCP tool: `get_diagnostics`.
////
//// Returns LSP diagnostics (errors and warnings) for a file URI.
////
//// Implementation uses the kept-warm LSP pool (lsp/pool) and
//// drain-mode collection of `textDocument/publishDiagnostics`
//// notifications. Push-mode (drain) rather than pull-mode
//// (`textDocument/diagnostic`) because rust-analyzer's analysis is
//// lazy: a pull request immediately after `didOpen` returns
//// `kind: "full", items: []` before analysis runs, and the server
//// cancels concurrent pull requests rather than queueing them.
//// Push-mode aligns with what rust-analyzer actually wants the
//// client to do; the lifecycle.request infrastructure is still
//// available for tier-1 tools (hover, goto_definition, etc.) that
//// use synchronous request/response naturally.
////
//// v0.1 hardcodes rust-analyzer. Multi-language registry replaces
//// the hardcoding at M4 — until then `.rs` files are the only
//// supported input.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option
import llm_lsp_mcp/lsp/client
import llm_lsp_mcp/lsp/pool.{type Pool}
import llm_lsp_mcp/tools/tier1/session

const default_drain_window_ms: Int = 8000

const drain_step_ms: Int = 500

pub type DiagnosticsError {
  /// File URI did not have a `file://` prefix.
  NotAFileUri(uri: String)
  /// Walked the directory tree without finding `Cargo.toml`.
  WorkspaceNotFound(uri: String)
  /// rust-analyzer subprocess could not be spawned (not on PATH?
  /// permissions?).
  SpawnFailed(reason: String)
  /// Initialize handshake failed.
  HandshakeFailed(reason: String)
  /// I/O error while waiting for notifications.
  TransportFailed(reason: String)
  /// Tool was called on a file with an unsupported extension. v0.1
  /// only handles `.rs` files.
  UnsupportedFileType(uri: String)
}

pub type DiagnosticsResult {
  /// Server published diagnostics for the file. `body_json` is the
  /// verbatim JSON text of the `textDocument/publishDiagnostics`
  /// notification body — caller can hand it to a content block as
  /// is, or parse the `params.diagnostics` array inside.
  Diagnostics(uri: String, body_json: String)
  /// Drain window expired with no `publishDiagnostics` for the
  /// requested URI. Caller can interpret this as "no diagnostics
  /// available within timeout" — useful info for the LLM.
  NoDiagnosticsObserved(uri: String)
}

/// Run get_diagnostics for one URI via the kept-warm LSP pool. The
/// pool returns a Client (cached or freshly spawned + initialized).
/// On cache hit subsequent calls pay only the per-call drain cost
/// (~hundreds of ms once indexed), not the rust-analyzer cold-start
/// tax.
pub fn handle(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(map_session_error(err))
    Ok(lsp) -> drain(lsp, file_uri, timeout_ms, option.None)
  }
}

pub fn handle_with_default_timeout(
  pool: Pool,
  file_uri: String,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  handle(pool, file_uri, default_drain_window_ms)
}

// -- LSP loop -------------------------------------------------------------

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
