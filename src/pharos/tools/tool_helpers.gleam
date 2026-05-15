//// Shared helpers for tier-1 tools: request-id allocation, response
//// rendering, error description.
////
//// Each tool calls `lifecycle.request` with a unique request id.
//// `next_id/0` returns a microsecond timestamp — collision-free in
//// practice and avoids the need to thread a counter through the
//// MCP dispatch chain.

import gleam/dynamic.{type Dynamic}
import pharos/lsp/client
import pharos/lsp/lifecycle
import pharos/lsp/port

@external(erlang, "erlang", "system_time")
fn system_time(unit: ErlangTimeUnit) -> Int

type ErlangTimeUnit {
  Microsecond
}

/// Allocate a fresh request id. Modular microsecond timestamp kept
/// inside i32 range — rust-analyzer's lsp-server crate parses
/// `RequestId::Int` as i32, so larger ids fail to deserialize and
/// the message is misidentified as a notification ("unhandled
/// notification: ..."). Modulo 2^31 - 1 (i32 max) gives ~2000s of
/// uniqueness which is more than enough for any single tool call's
/// outstanding requests.
const i32_max: Int = 2_147_483_647

pub fn next_id() -> Int {
  let raw = system_time(Microsecond)
  raw % i32_max
}

/// Re-encode a Dynamic LSP response value as a JSON string for
/// embedding in an MCP text content block. Wraps the FFI to OTP 27's
/// `json:encode/1` flattened to a binary.
@external(erlang, "pharos_fs_ffi", "encode_json")
pub fn json_encode(value: Dynamic) -> String

/// Render a request-level error for the LLM. Distinguishes the
/// shapes the LLM needs to choose its next action:
///   - `port.Timeout` — the LSP didn't respond in the per-tool
///     budget. Retry / bump `timeout_ms` / set a session default
///     via `runtime_set_tool_timeout`.
///   - `port.PortClosed(_)` — the LSP process exited
///     unexpectedly. Don't retry blindly; surface as a real
///     failure.
///   - `lifecycle.ServerError(_, _)` — the LSP responded with a
///     JSON-RPC error. The message tells the LLM what's wrong.
///   - everything else — pass through with a clarifying prefix.
pub fn describe_request_error(err: lifecycle.RequestError) -> String {
  case err {
    lifecycle.ClientFailure(client_err) -> describe_client_error(client_err)
    lifecycle.ResponseDecodeError(reason) ->
      "response decode error: " <> reason
    lifecycle.ServerError(code, message) ->
      "server error " <> int_to_string(code) <> ": " <> message
    lifecycle.ActorCallPanic(reason) ->
      "lsp actor call panicked (likely cached lsp_proc died before this "
      <> "call dispatched; retry should re-spawn): "
      <> reason
  }
}

fn describe_client_error(err: client.Error) -> String {
  case err {
    client.PortReceiveError(port.Timeout) ->
      "tool timeout: LSP did not respond in time. The LSP may still be "
      <> "indexing — pass a larger `timeout_ms` on this tool call, or call "
      <> "`runtime_set_tool_timeout` to raise the default for this session, "
      <> "or simply retry."
    client.PortReceiveError(port.PortClosed(status)) ->
      "LSP process exited unexpectedly (transport closed; exit status "
      <> int_to_string(status)
      <> ")"
    client.PortSendError(_) ->
      "LSP process exited unexpectedly (send failed; transport closed)"
    client.FramingError(_) ->
      "LSP protocol framing error (malformed message from server)"
    client.SpawnError(_) ->
      "LSP spawn error (subprocess could not start)"
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
