//// LSP wire framing (Content-Length).
////
//// LSP frames each JSON-RPC message with HTTP-style headers:
////
////   Content-Length: <byte count>\r\n
////   \r\n
////   <body bytes>
////
//// Stateful parser — input arrives in arbitrary chunks. Buffers
//// partial headers and bodies until a complete message is available.
//// Handles multi-message coalesced reads.
////
//// Most error-prone module in the codebase; property tests via
//// `gleam_qcheck` cover partial-read cases.
////
//// Stub — parser + encoder land in Milestone 2.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
