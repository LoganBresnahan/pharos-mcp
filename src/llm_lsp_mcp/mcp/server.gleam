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
