//// MCP HTTP/SSE transport.
////
//// Per the MCP spec — Streamable HTTP transport. Single endpoint
//// accepts POST for client → server, GET for SSE server → client
//// notification stream.
////
//// Built on `mist`. Coexists with `mcp/stdio` — both can be active in
//// the same binary process.
////
//// Stub — HTTP transport lands in Milestone 5.
