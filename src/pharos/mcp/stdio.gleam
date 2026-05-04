//// MCP stdio transport — NDJSON framing.
////
//// Reads JSON-RPC 2.0 messages from stdin one line at a time and
//// writes responses to stdout one line at a time. The MCP spec uses
//// newline-delimited JSON over stdio, so each `\n` boundary is a
//// complete message; no Content-Length parsing here (that lives in
//// `lsp/framing` for the LSP side).
////
//// stdin reading is done via the Erlang FFI helper
//// `pharos_stdin_ffi:read_line/0`, which wraps `io:get_line/1`
//// and returns a tagged tuple matching `StdinResult`.

import gleam/io
import gleam/string

pub type StdinResult {
  StdinLine(line: String)
  StdinEof
  StdinError(reason: String)
}

@external(erlang, "pharos_stdin_ffi", "read_line")
pub fn read_line() -> StdinResult

/// Strip the trailing newline (if any) from a line read from stdin.
pub fn trim_trailing_newline(line: String) -> String {
  line
  |> string.trim_end
}

/// Write a JSON-RPC message to stdout with the trailing newline that
/// NDJSON framing requires. The body should already be encoded JSON.
pub fn write(body: String) -> Nil {
  io.println(body)
}
