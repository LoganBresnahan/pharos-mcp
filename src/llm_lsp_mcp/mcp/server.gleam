//// MCP protocol dispatch.
////
//// Handles the MCP request lifecycle: `initialize`, `initialized`,
//// `tools/list`, `tools/call`, `notifications/cancelled`, etc. Decodes
//// JSON-RPC envelopes via pollux, looks up handlers in the tool
//// registry, returns content-block responses.
////
//// Transport-agnostic — wired to `mcp/stdio` and `mcp/http` separately.
////
//// Stub — server skeleton lands in Milestone 1.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
