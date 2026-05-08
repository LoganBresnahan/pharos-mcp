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

/// Atomic test-and-set: returns True to the FIRST worker per
/// `(server_id, workspace)` (it should now run `proc.wait_for_ready`
/// and call `mark_done/2` afterward); returns False to every
/// subsequent worker (they skip the drain — relying on the existing
/// retry-on-content-modified path to absorb any cold-start race).
///
/// First-claim-wins exists because `proc.wait_for_ready` is an
/// `actor.call` with a 35s timeout. Two concurrent workers both
/// calling it queue behind each other in the proc actor's mailbox;
/// the second's caller-side deadline expires while waiting for the
/// first's 30s drain to complete, the worker crashes silently
/// (spawn_unlinked), and the inflight counter leaks.
@external(erlang, "pharos_post_didopen_drained_ffi", "try_claim")
pub fn try_claim(server_id: String, workspace: String) -> Bool

/// Called by the claiming worker after `proc.wait_for_ready` returned
/// Ok. Future workers see `is_done/2 == true` and skip both the claim
/// and the drain.
@external(erlang, "pharos_post_didopen_drained_ffi", "mark_done")
pub fn mark_done(server_id: String, workspace: String) -> Nil

/// True when `(server_id, workspace)` has already been drained
/// successfully. Workers consult this BEFORE attempting `try_claim`
/// to avoid even the ETS `insert_new` cost on the warm path.
@external(erlang, "pharos_post_didopen_drained_ffi", "is_done")
pub fn is_done(server_id: String, workspace: String) -> Bool
