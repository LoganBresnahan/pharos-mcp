//// MCP tool: `get_diagnostics`.
////
//// Returns diagnostics (errors and warnings) for a file URI.
//// Diagnostics are pushed by the LSP via
//// `textDocument/publishDiagnostics` notifications and cached in the
//// LSP client; this tool reads from that cache and triggers a fresh
//// publish if needed.
////
//// Stub — first real tool, lands in Milestone 3.
