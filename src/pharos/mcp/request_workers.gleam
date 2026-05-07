//// MCP request-worker tracker (M10 async-dispatch refactor —
//// closes ADR-016's deferred follow-up).
////
//// Each inbound JSON-RPC line on the stdio transport now runs on
//// its own ephemeral process. The worker calls
//// `mcp/server.handle_line/2` and forwards the result back to
//// `stdio_worker` via the supplied write Subject. Two consequences:
////
////   1. `stdio_worker` no longer blocks during LSP dispatch — the
////      next line is read immediately. A `notifications/cancelled`
////      arriving on the same stream is now READ in time to act on
////      the in-flight request.
////
////   2. Cancel propagation can kill the in-flight worker via
////      `process.send_exit/2` instead of waiting for LSP cooperation.
////      The MCP cancel handler in `mcp/server` looks up the worker
////      pid via `lookup/1` and sends a kill signal so the wait on
////      the LSP response short-circuits even when the LSP itself
////      ignores `$/cancelRequest`.
////
//// The pid table is in ETS rather than a process state so the
//// cancel handler (running in stdio_worker's actor) can read it
//// without a synchronous call into a mediator. Inserts happen
//// before `handle_line` runs; deletes fire on every termination
//// path through a `try ... after` analogue.

import gleam/erlang/process.{type Pid, type Subject}

/// Initialise the ETS table backing the worker registry. Idempotent.
/// Call once at boot alongside the other registries.
@external(erlang, "pharos_runtime_ffi", "request_workers_init")
pub fn init() -> Nil

/// Register `worker_pid` as the dispatcher for `mcp_id`. Called by
/// the worker itself immediately before invoking
/// `mcp/server.handle_line/2`.
@external(erlang, "pharos_runtime_ffi", "request_workers_insert")
pub fn insert(mcp_id: String, worker_pid: Pid) -> Nil

/// Look up the worker pid for an in-flight MCP request. Returns
/// `Error(Nil)` when the request has already completed (worker
/// deregistered itself) or when the id was never registered (e.g.
/// HTTP transport, where each request runs on the mist connection
/// process directly without going through this table).
@external(erlang, "pharos_runtime_ffi", "request_workers_lookup")
pub fn lookup(mcp_id: String) -> Result(Pid, Nil)

/// Drop the registry entry. Workers call this from their cleanup
/// path. Idempotent.
@external(erlang, "pharos_runtime_ffi", "request_workers_delete")
pub fn delete(mcp_id: String) -> Nil

/// Number of live worker registrations. Useful for runtime
/// diagnostics — a positive size after the host has gone idle
/// indicates a leak.
@external(erlang, "pharos_runtime_ffi", "request_workers_size")
pub fn size() -> Int

/// Re-export the message shape the dispatcher sends back to
/// stdio_worker. Defined here rather than in stdio_worker so this
/// module owns the dispatch contract end-to-end.
pub type WriterMsg {
  /// Response payload for stdio_worker to write to stdout.
  WriteResponse(json: String)
  /// Notification that a worker exited with no response (cancel,
  /// notification dispatch, or NoReply). Stdio_worker uses this for
  /// log + cleanup; no stdout write happens.
  WorkerDone
}

/// Sentinel mcp_id used when peeking a request line cannot extract
/// one (parse error, notification, etc.). Workers handling these
/// lines still register so the table size reflects total in-flight
/// dispatchers; lookup by the sentinel is meaningless and will only
/// happen on a malformed cancel.
pub const anonymous_id: String = "__anonymous__"

/// Writes the dispatcher's reply back to stdio_worker. Called by
/// the worker process after `mcp/server.handle_line` returns.
pub fn send_reply(subject: Subject(WriterMsg), reply: WriterMsg) -> Nil {
  process.send(subject, reply)
}
