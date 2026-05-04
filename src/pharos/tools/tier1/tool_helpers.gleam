//// Shared helpers for tier-1 tools: request-id allocation, response
//// rendering, error description.
////
//// Each tool calls `lifecycle.request` with a unique request id.
//// `next_id/0` returns a microsecond timestamp — collision-free in
//// practice and avoids the need to thread a counter through the
//// MCP dispatch chain.

import gleam/dynamic.{type Dynamic}
import pharos/lsp/lifecycle

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

pub fn describe_request_error(err: lifecycle.RequestError) -> String {
  case err {
    lifecycle.ClientFailure(_) -> "LSP transport error"
    lifecycle.ResponseDecodeError(reason) ->
      "response decode error: " <> reason
    lifecycle.ServerError(code, message) ->
      "server error " <> int_to_string(code) <> ": " <> message
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
