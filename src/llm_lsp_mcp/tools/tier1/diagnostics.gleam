//// MCP tool: `get_diagnostics`.
////
//// Returns LSP diagnostics (errors and warnings) for a file URI.
////
//// Milestone 3 implementation: spawn rust-analyzer per call against
//// the workspace containing the file, drain incoming
//// `textDocument/publishDiagnostics` notifications for the requested
//// URI for a fixed window, return the latest match. Spawn-per-call
//// is correct for a one-shot tool but slow on cold start (~5-15s
//// for rust-analyzer to index a small project). Kept-warm caching
//// lands in M4.
////
//// v0.1 hardcodes rust-analyzer. Multi-language registry replaces
//// the hardcoding at M4 — until then `.rs` files are the only
//// supported input.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_lsp_mcp/lsp/client
import llm_lsp_mcp/lsp/lifecycle
import llm_lsp_mcp/lsp/port
import llm_lsp_mcp/workspace_root

// Absolute path. The MCP host spawns the wrapper with a minimal PATH
// that may not include $HOME/.cargo/bin, so a bare `rust-analyzer`
// resolves to enoent. M4 will replace this with the language registry
// + PATH-resolution helper.
const rust_analyzer_command: String = "/home/oof/.cargo/bin/rust-analyzer"

const initialize_timeout_ms: Int = 30_000

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

/// Run get_diagnostics for one URI. Caller controls how long to drain
/// for; default is 8 seconds (enough for rust-analyzer to index a
/// small project from a cold start).
pub fn handle(
  file_uri: String,
  drain_window_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  use Nil <- result.try(check_supported_extension(file_uri))

  use workspace <- result.try(
    workspace_root.discover_from_uri(file_uri, ["Cargo.toml"])
    |> result.map_error(fn(err) {
      case err {
        workspace_root.NotAFileUri(uri) -> NotAFileUri(uri)
        workspace_root.NoMarkerFound -> WorkspaceNotFound(file_uri)
      }
    }),
  )

  use lsp <- result.try(
    client.start(rust_analyzer_command, [], workspace)
    |> result.map_error(describe_client_error_as_spawn),
  )

  let init_params = build_initialize_params(workspace)

  case lifecycle.initialize(lsp, 0, init_params, initialize_timeout_ms) {
    Error(err) -> {
      client.close(lsp)
      Error(HandshakeFailed(describe_initialize_error(err)))
    }

    Ok(#(lsp, _capabilities)) -> {
      let _ = send_did_open(lsp, file_uri)
      let outcome = drain(lsp, file_uri, drain_window_ms, None)
      client.close(lsp)
      outcome
    }
  }
}

/// Tell the LSP we have the file "open". Some servers (rust-analyzer
/// included) emit publishDiagnostics for opened files specifically;
/// without didOpen, diagnostics may only flow for whatever the
/// server decides to index in the workspace, and the file we asked
/// about may never be reached. Best-effort — failures here are
/// swallowed and the drain handles the no-diagnostics case.
fn send_did_open(lsp: client.Client, file_uri: String) -> Nil {
  case workspace_root.uri_to_path(file_uri) {
    Error(_) -> Nil
    Ok(path) ->
      case workspace_root.read_file(path) {
        Error(_) -> Nil
        Ok(content_bytes) ->
          case bit_array.to_string(content_bytes) {
            Error(_) -> Nil
            Ok(text) -> {
              let body =
                json.object([
                  #("jsonrpc", json.string("2.0")),
                  #("method", json.string("textDocument/didOpen")),
                  #(
                    "params",
                    json.object([
                      #(
                        "textDocument",
                        json.object([
                          #("uri", json.string(file_uri)),
                          #("languageId", json.string("rust")),
                          #("version", json.int(1)),
                          #("text", json.string(text)),
                        ]),
                      ),
                    ]),
                  ),
                ])
                |> json.to_string
                |> bit_array.from_string

              let _ = client.send_body(lsp, body)
              Nil
            }
          }
      }
  }
}

pub fn handle_with_default_timeout(
  file_uri: String,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  handle(file_uri, default_drain_window_ms)
}

// -- LSP loop -------------------------------------------------------------

fn drain(
  lsp: client.Client,
  target_uri: String,
  remaining_ms: Int,
  latest: Option(String),
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case remaining_ms <= 0 {
    True ->
      Ok(case latest {
        Some(body) -> Diagnostics(uri: target_uri, body_json: body)
        None -> NoDiagnosticsObserved(uri: target_uri)
      })

    False ->
      case client.next_message(lsp, drain_step_ms) {
        Error(client.PortReceiveError(_)) ->
          // Per-step timeout is fine; reduce overall budget and try
          // again. PortClosed surfaces as a Timeout from the FFI's
          // perspective when the subprocess is just slow, so we
          // don't distinguish here.
          drain(lsp, target_uri, remaining_ms - drain_step_ms, latest)

        Error(other) ->
          Error(TransportFailed(describe_client_error(other)))

        Ok(#(body, lsp)) -> {
          let next_latest = case extract_matching_body(body, target_uri) {
            Some(text) -> Some(text)
            None -> latest
          }
          drain(lsp, target_uri, remaining_ms - drain_step_ms, next_latest)
        }
      }
  }
}

/// If `body` is a `textDocument/publishDiagnostics` notification for
/// `target_uri`, return the verbatim JSON text. Otherwise None. We
/// keep the original JSON rather than reserialize from a parsed
/// Dynamic because gleam_json has no Dynamic→Json roundtrip.
fn extract_matching_body(body: BitArray, target_uri: String) -> Option(String) {
  case bit_array.to_string(body) {
    Error(Nil) -> None
    Ok(text) ->
      case json.parse(text, decode.dynamic) {
        Error(_) -> None
        Ok(value) ->
          case decode.run(value, publish_diagnostics_uri_decoder()) {
            Error(_) -> None
            Ok(uri) ->
              case uri == target_uri {
                True -> Some(text)
                False -> None
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

// -- Initialize params ----------------------------------------------------

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

// -- Validation -----------------------------------------------------------

fn check_supported_extension(uri: String) -> Result(Nil, DiagnosticsError) {
  case string.ends_with(uri, ".rs") {
    True -> Ok(Nil)
    False -> Error(UnsupportedFileType(uri))
  }
}

// -- Error description helpers -------------------------------------------

fn describe_client_error_as_spawn(err: client.Error) -> DiagnosticsError {
  case err {
    client.SpawnError(port.SpawnFailed(reason)) -> SpawnFailed(reason)
    other -> SpawnFailed(describe_client_error(other))
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

fn describe_initialize_error(err: lifecycle.InitializeError) -> String {
  case err {
    lifecycle.ClientFailure(c) -> describe_client_error(c)
    lifecycle.ResponseDecodeError(reason) ->
      "response decode error: " <> reason
    lifecycle.ServerError(_, message) -> "server error: " <> message
  }
}
