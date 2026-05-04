//// Tool registry and dispatcher.
////
//// Maintains the canonical list of registered MCP tools, resolves
//// tool names to handlers, and applies server-side filtering from
//// `--tools`, `PHAROS_TOOLS`, or config.
////
//// Each tool module (e.g., `tools/tier1/hover`) registers itself by
//// providing `tool_definition()` (for `tools/list`) and `handle/2`
//// (for `tools/call`).
////
//// Stub — registry lands in Milestone 1; per-tier registration is
//// added incrementally as tool modules ship.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
