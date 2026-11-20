//// Shared helpers for tier-1 tools: request-id allocation, response
//// rendering, error description.
////
//// Each tool calls `lifecycle.request` with a unique request id.
//// `next_id/0` returns a microsecond timestamp — collision-free in
//// practice and avoids the need to thread a counter through the
//// MCP dispatch chain.

import gleam/dynamic.{type Dynamic}
import pharos/lsp/capabilities
import pharos/lsp/client
import pharos/lsp/lifecycle
import pharos/lsp/port
import pharos/lsp/proc.{type Proc}

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
    lifecycle.ResponseDecodeError(reason) -> "response decode error: " <> reason
    lifecycle.ServerError(code, message) ->
      "server error " <> int_to_string(code) <> ": " <> message
    lifecycle.ActorCallPanic(reason) ->
      "lsp actor call panicked (likely cached lsp_proc died before this "
      <> "call dispatched; retry should re-spawn): "
      <> reason
    lifecycle.Unsupported(server_id, method, capability) ->
      describe_unsupported(server_id, method, capability)
  }
}

/// #37: one message for every tool whose method the server doesn't
/// advertise. It's an error (isError), so an agent doesn't read an empty
/// answer or a timeout as the server's verdict on the code.
pub fn describe_unsupported(
  server_id: String,
  method: String,
  capability: String,
) -> String {
  let who = case server_id {
    "" -> "this language server"
    id -> "this language server (" <> id <> ")"
  }
  who
  <> " doesn't support "
  <> method
  <> ": it doesn't advertise "
  <> capability
  <> ", so pharos didn't send the request"
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
    client.SpawnError(_) -> "LSP spawn error (subprocess could not start)"
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

/// Short-circuit a tool call when the LSP server did not advertise
/// the required capability during its initialize handshake. Mirrors
/// the `-32601 Method not found` shape the server itself would
/// return, which the dogfood harness already counts as a GAP rather
/// than a FAIL. Saves a 30s+ round-trip on servers that silently
/// never reply to optional methods.
///
/// `Unknown` (no capabilities record on file — proc recovered from
/// ETS bridge across a pool restart, or initialize result lacked
/// the field) falls through to `body()` so we preserve the
/// pre-gate optimistic-dispatch behaviour rather than regressing
/// existing tools to a hard fail.
pub fn with_capability_gate(
  lsp: Proc,
  method: String,
  body: fn() -> Result(a, lifecycle.RequestError),
) -> Result(a, lifecycle.RequestError) {
  with_capability_gate_on(AbsentOrFalse, lsp, method, body)
}

/// When a capability gate refuses a method (#37).
pub type GateOn {
  /// Only when the server doesn't mention the capability at all. For the
  /// tools gated since #37, which sent every request before: some servers
  /// advertise `false` and serve the method anyway (zls answers
  /// textDocument/implementation with implementationProvider: false), and
  /// the gate must not take away an answer that worked.
  Absent
  /// When it's absent, null or false: the tools gated before #37 keep
  /// refusing exactly what they refused.
  AbsentOrFalse
}

/// `with_capability_gate`, choosing what counts as "doesn't advertise".
pub fn with_capability_gate_on(
  gate_on: GateOn,
  lsp: Proc,
  method: String,
  body: fn() -> Result(a, lifecycle.RequestError),
) -> Result(a, lifecycle.RequestError) {
  let support = case gate_on {
    Absent -> capabilities.check_absent(lsp, method)
    AbsentOrFalse -> capabilities.check(lsp, method)
  }
  case support {
    capabilities.Unsupported ->
      Error(lifecycle.Unsupported(
        server_id: proc.server_id(lsp),
        method: method,
        capability: capabilities.capability_name(method),
      ))
    _ -> body()
  }
}
