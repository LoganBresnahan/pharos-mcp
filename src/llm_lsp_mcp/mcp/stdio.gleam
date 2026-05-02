//// MCP stdio transport.
////
//// Reads NDJSON-framed JSON-RPC 2.0 messages from stdin and writes
//// responses to stdout. Each message is one line of JSON terminated by
//// `\n`. Partial reads are buffered until a newline arrives.
////
//// Pairs with `mcp/server` for dispatch. Always-on in v0.1; coexists
//// with `mcp/http` (both can run in the same binary).
////
//// Stub — framing + reader land in Milestone 1.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
