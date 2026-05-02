//// LSP lifecycle: initialize → initialized → ... → shutdown → exit.
////
//// Encapsulates the LSP startup dance: send `initialize` with our
//// client capabilities and the workspace root, await the server's
//// capability response, send `initialized` notification. Symmetric
//// shutdown sequence on teardown.
////
//// Per-LSP `initializationOptions` quirks (rust-analyzer's `cargo`
//// settings, tsserver's `typescript.tsdk`, etc.) live in
//// `lsp/languages` and are merged in here.
////
//// Stub — lifecycle handshake lands in Milestone 2.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
