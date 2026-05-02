//// LSP client GenServer-equivalent.
////
//// One process per running LSP. Owns the Erlang Port wrapping the LSP
//// subprocess (rust-analyzer, gopls, etc.), handles the bidirectional
//// JSON-RPC stream, routes responses back to callers via the pending
//// map (see `lsp/pending`), forwards notifications (publishDiagnostics,
//// progress, etc.) to subscribers.
////
//// Stub — client process lands in Milestone 2.
