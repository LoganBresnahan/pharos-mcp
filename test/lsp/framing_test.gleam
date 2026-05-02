//// Tests for `llm_lsp_mcp/lsp/framing` (Content-Length parser).
////
//// Will include property tests via `gleam_qcheck` covering:
////   - partial header reads
////   - partial body reads
////   - multiple coalesced messages in one read
////   - malformed Content-Length
////
//// Stub — test cases land alongside the implementation in
//// Milestone 2.
