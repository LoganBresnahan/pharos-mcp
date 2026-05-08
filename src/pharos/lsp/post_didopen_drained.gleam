//// Track which `(server_id, workspace)` pairs have completed the
//// post-didOpen indexing drain so we only call `wait_for_ready`
//// once per pair.
////
//// Why a second drain is needed: `lifecycle.wait_for_ready/3` runs
//// post-handshake (before any `textDocument/didOpen`). rust-analyzer
//// in particular only starts indexing AFTER the first didOpen — the
//// post-handshake drain returns instantly because there is no
//// progress to wait on yet, and the first hover/goto against the
//// freshly-spawned analyzer then races against indexing and returns
//// `null` or `-32801 content modified`. The session.gleam
//// `request_with_content_modified_retry` papered over the second
//// failure mode; this drain removes it at the source.
////
//// Subsequent didOpens for additional files in the same workspace
//// skip the drain (workspace already indexed). Cross-workspace
//// drains are independent.

/// Initialise the underlying ETS table. Idempotent.
@external(erlang, "pharos_post_didopen_drained_ffi", "init")
pub fn init() -> Nil

/// Record that `(server_id, workspace)` has completed its
/// post-didOpen drain. Called only after `wait_for_ready/3` returns
/// Ok — Error paths leave the entry absent so the next call retries.
@external(erlang, "pharos_post_didopen_drained_ffi", "mark")
pub fn mark(server_id: String, workspace: String) -> Nil

/// True when `(server_id, workspace)` has already been drained.
@external(erlang, "pharos_post_didopen_drained_ffi", "is_marked")
pub fn is_marked(server_id: String, workspace: String) -> Bool
