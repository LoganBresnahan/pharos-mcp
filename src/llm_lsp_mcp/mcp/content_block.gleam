//// MCP content blocks.
////
//// Content blocks are the unit of tool output: text, image, or
//// resource. Tools return a list of these, which the MCP client
//// surfaces to the LLM.
////
//// Provides typed constructors and JSON encoders for each variant.
//// Helpers also format LSP-flavored payloads into LLM-friendly blocks
//// (markdown rendering of `Hover` results, unified-diff rendering of
//// `WorkspaceEdit`, etc.).
////
//// Stub — block types land in Milestone 1; rendering helpers in
//// Milestone 4 and 8.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
