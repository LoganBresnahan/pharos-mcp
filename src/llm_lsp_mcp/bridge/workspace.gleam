//// Workspace state lookup (roots, active selection).
////
//// Asks the bridge for VSCode's workspace folders and the active
//// editor selection when the extension is running. Falls back to CWD
//// + null selection otherwise.
////
//// Used by `lsp/lifecycle` for `rootUri` at LSP `initialize`, and by
//// tools that take an implicit position from "where the cursor is".
////
//// Stub — workspace lookup lands in Milestone 7.
