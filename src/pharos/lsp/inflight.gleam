//// In-flight LSP request tracker (ADR-016).
////
//// One ETS-backed table mapping the MCP request id of an in-flight
//// `tools/call` to the Proc handling it and the LSP request id
//// inside that Proc. Populated by `lsp/proc` immediately before the
//// LSP send, deleted after the response (success or error).
//// `mcp/server`'s `notifications/cancelled` handler reads the table
//// to route `$/cancelRequest` to the right proc.
////
//// Stdio transport's synchronous dispatch means the table mostly
//// MISSES on cancel — the request is already done by the time the
//// cancel notification is even read off stdin. HTTP transport runs
//// each request on its own connection process, so the cancel
//// arrives concurrently with the in-flight dispatcher and the
//// lookup hits. The bridge that lives behind `vscode-pharos-bridge`
//// uses HTTP; this is the path that benefits most.

import gleam/dynamic.{type Dynamic}

/// Initialise the ETS table. Idempotent. Call once at boot
/// (alongside the diagnostics cache and language registry).
@external(erlang, "pharos_runtime_ffi", "inflight_init")
pub fn init() -> Nil

/// Record an in-flight LSP request. `proc_subject` is stored as
/// `Dynamic` because the table sees a heterogeneous (Subject(Msg))
/// shape across languages and the cancel handler punts the cast.
@external(erlang, "pharos_runtime_ffi", "inflight_insert")
pub fn insert(mcp_id: String, proc_subject: Dynamic, lsp_id: Int) -> Nil

/// Look up an in-flight request by MCP id. `Error(Nil)` indicates a
/// cancel for an already-completed (or never-tracked) request.
@external(erlang, "pharos_runtime_ffi", "inflight_lookup")
pub fn lookup(mcp_id: String) -> Result(#(Dynamic, Int), Nil)

@external(erlang, "pharos_runtime_ffi", "inflight_delete")
pub fn delete(mcp_id: String) -> Nil

@external(erlang, "pharos_runtime_ffi", "inflight_size")
pub fn size() -> Int
