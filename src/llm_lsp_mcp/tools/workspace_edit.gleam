//// `WorkspaceEdit` rendering helpers.
////
//// Tools that return LSP `WorkspaceEdit` results (rename_preview,
//// format_document, code_actions) format the edit as MCP content
//// blocks via this module. Output: structured JSON block + a
//// human-readable unified-diff block.
////
//// Handles both `changes` and `documentChanges` forms of
//// WorkspaceEdit. Never writes to disk — see the edit-as-data
//// philosophy in `doc/init.md` § Tool surface.
////
//// Stub — renderer lands in Milestone 8.
