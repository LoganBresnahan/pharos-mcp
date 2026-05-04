//// `lsp_request_raw` escape-hatch tool.
////
//// Single MCP tool that takes a `method` string + `Dynamic` params
//// and forwards verbatim to the appropriate LSP. Returns the raw
//// JSON result wrapped in a content block.
////
//// Coverage for the long tail of LSP methods we did not curate.
//// Loses Gleam type safety for this one tool — the trade is explicit.
////
//// Stub — escape-hatch lands in Milestone 8.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
