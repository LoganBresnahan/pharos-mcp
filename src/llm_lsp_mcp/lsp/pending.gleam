//// Pending request id → caller mapping.
////
//// LSP responses arrive asynchronously, identified only by the `id`
//// from the original request. This module owns the map from outgoing
//// request id to the caller process awaiting the response, so
//// `lsp/client` can route responses back without blocking the I/O
//// loop.
////
//// Stub — pending tracker lands in Milestone 2.
