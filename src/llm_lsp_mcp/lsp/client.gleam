//// LSP client GenServer-equivalent.
////
//// One process per running LSP. Owns the Erlang Port wrapping the LSP
//// subprocess (rust-analyzer, gopls, etc.), handles the bidirectional
//// JSON-RPC stream, routes responses back to callers via the pending
//// map (see `lsp/pending`), forwards notifications (publishDiagnostics,
//// progress, etc.) to subscribers.
////
//// Stub — client process lands in Milestone 2.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
