//// Erlang Port primitives for managing an LSP subprocess.
////
//// Thin typed wrappers around `llm_lsp_mcp_lsp_port_ffi`. This module
//// is the *I/O surface* — open the port, write bytes, read bytes,
//// close. The framing layer (`lsp/framing`) sits above and turns the
//// raw byte chunks into JSON-RPC message bodies. The lifecycle and
//// dispatch logic (`lsp/client`, `lsp/lifecycle`) sits above that.
////
//// At Milestone 2 the API is synchronous: callers block on
//// `receive_data` with an explicit timeout. Async fan-out arrives at
//// the actor abstraction in a later milestone when multiple in-flight
//// requests need to multiplex.

/// An opaque handle to a running subprocess. Internally an Erlang
/// `port()`; treated as opaque so Gleam can keep type discipline at
/// the boundary.
pub type Port

pub type SpawnError {
  SpawnFailed(reason: String)
}

pub type ReceiveError {
  /// No bytes arrived within the timeout. Caller can retry.
  Timeout
  /// Subprocess exited. `exit_status` is the OS exit code.
  PortClosed(exit_status: Int)
}

pub type SendError {
  /// Tried to write to a port that has already exited.
  Closed
}

/// Spawn a subprocess with the given command, arguments, and working
/// directory. The child inherits stdio; we read stdout in raw binary
/// mode (no line discipline — the framing parser handles message
/// boundaries).
@external(erlang, "llm_lsp_mcp_lsp_port_ffi", "spawn")
pub fn spawn(
  command: String,
  args: List(String),
  cwd: String,
) -> Result(Port, SpawnError)

/// Write raw bytes to the subprocess's stdin. The body should already
/// be Content-Length framed via `lsp/framing.encode`.
@external(erlang, "llm_lsp_mcp_lsp_port_ffi", "send")
pub fn send(port: Port, bytes: BitArray) -> Result(Nil, SendError)

/// Wait up to `timeout_ms` for the subprocess to write to stdout.
/// Returns whatever bytes the kernel hands us — partial reads are
/// expected and handled by the framing parser.
@external(erlang, "llm_lsp_mcp_lsp_port_ffi", "receive_data")
pub fn receive_data(
  port: Port,
  timeout_ms: Int,
) -> Result(BitArray, ReceiveError)

/// Close the port. Idempotent; closing a closed port is a no-op.
@external(erlang, "llm_lsp_mcp_lsp_port_ffi", "close")
pub fn close(port: Port) -> Nil
