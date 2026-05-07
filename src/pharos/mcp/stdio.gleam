//// MCP stdio transport — NDJSON framing.
////
//// Reads JSON-RPC 2.0 messages from stdin one line at a time and
//// writes responses to stdout one line at a time. The MCP spec uses
//// newline-delimited JSON over stdio, so each `\n` boundary is a
//// complete message; no Content-Length parsing here (that lives in
//// `lsp/framing` for the LSP side).
////
//// **Stdout is unbuffered** — written via a direct port over fd 1
//// in `pharos_stdin_ffi:write_line/1`, bypassing Erlang's `:user`
//// group leader. Without this, BEAM's release runtime
//// (`-noshell -mode embedded`) buffers stdout writes and only
//// flushes on stdin EOF. MCP hosts hold stdin open while waiting
//// for the response on stdout, which made initialize never return
//// before the host's 30s timeout. ADR-style note: this is the
//// reason stdio.write/1 is an FFI call, not a `gleam/io.println/1`
//// wrapper.
////
//// stdin reading is done via the Erlang FFI helper
//// `pharos_stdin_ffi:read_line/0`, which wraps `io:get_line/1`
//// and returns a tagged tuple matching `StdinResult`.

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
/// Unbuffered — see module-level note.
@external(erlang, "pharos_stdin_ffi", "write_line")
pub fn write(body: String) -> Nil
