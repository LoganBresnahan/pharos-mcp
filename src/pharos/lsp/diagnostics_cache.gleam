//// Diagnostics cache — Gleam wrapper over an ETS-backed store.
////
//// Why this exists: servers push `textDocument/publishDiagnostics`
//// when they have something to say, not when asked, and some
//// (rust-analyzer) skip a publish when a file's diagnostics did not
//// change. Tools that read diagnostics need the last publish kept.
////
//// The cache key is `(uri, server_id)`. Multi-LSP languages
//// (python = pyright + ruff) emit independently for the same URI;
//// keying by URI alone would overwrite one server's items with the
//// other's. `get_all_for_uri/1` returns every cached server's
//// entry for the URI so the multi-server merge path can stitch
//// them together.
////
//// ADR-038: every row is keyed by the proc too, since one URI can be
//// open under the same server id in two procs of a shared daemon.
//// Entries are stamped when written. The pool records the version it
//// expects each open document to be at (`expect/4`), and the proc
//// stamps each sync once written (`mark_synced/3`), so `lookup/3` can
//// tell an entry that describes the text the server has now (`Fresh`)
//// from one written before (`CarriedOver`), and a caller can wait for
//// its sync to be written (`stamp_status/4`). Batches of syncs are
//// stamped the same way (`expect_batch/2`, `mark_batch/1`), and each
//// starts a settle window (`settle_ms`, `settle_left_ms/1`).
//// Nothing is dropped on a sync. An entry is replaced by the next
//// publish for the same `(uri, server_id)`, or removed by `drop/2` or
//// `drop_uri/1`.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}

/// Initialise the underlying ETS table. Idempotent — calling more
/// than once is a no-op. Must run before the first `put` / `get`.
@external(erlang, "pharos_diagnostics_cache_ffi", "init")
pub fn init() -> Nil

/// Record a `publishDiagnostics.params` value for `(uri, server_id)`,
/// keyed by the calling process (the proc that read it).
@external(erlang, "pharos_diagnostics_cache_ffi", "put")
pub fn put(uri: String, server_id: String, value: Dynamic) -> Nil

/// Read any proc's cached `publishDiagnostics.params` for
/// `(uri, server_id)`, for tests and introspection; tools use
/// `lookup/3`. Returns `Error(Nil)` when the cache has no entry.
@external(erlang, "pharos_diagnostics_cache_ffi", "get")
pub fn get(uri: String, server_id: String) -> Result(Dynamic, Nil)

/// Read every cached server's `publishDiagnostics.params` for the
/// URI. Returns a list of `(server_id, params)` tuples; empty when
/// nothing is cached. Used by the multi-server merge path so the
/// cache survives across calls.
@external(erlang, "pharos_diagnostics_cache_ffi", "get_all_for_uri")
pub fn get_all_for_uri(uri: String) -> List(#(String, Dynamic))

/// Forget the cache entry for one `(uri, server_id)`. Used when
/// callers know that one server's view is stale (e.g. after a
/// targeted re-publish).
@external(erlang, "pharos_diagnostics_cache_ffi", "drop")
pub fn drop(uri: String, server_id: String) -> Nil

/// Forget everything about `uri` regardless of server: its entries,
/// its synced stamps and its expectations.
@external(erlang, "pharos_diagnostics_cache_ffi", "drop_uri")
pub fn drop_uri(uri: String) -> Nil

/// Record a `publishDiagnostics.params` value read by the calling
/// proc, unless it carries a `version` lower than the version that
/// proc last synced for the document (ADR-038): such a publish admits
/// to describing text the server has already replaced.
@external(erlang, "pharos_diagnostics_cache_ffi", "put_publish")
pub fn put_publish(
  uri: String,
  server_id: String,
  version: Option(Int),
  value: Dynamic,
) -> Nil

/// Record that the calling proc just wrote the document's sync at
/// `version` (a `didOpen`, or a re-sync after the file changed). Must
/// be called by the proc right after the write, so the stamp orders
/// exactly against the publishes it caches.
@external(erlang, "pharos_diagnostics_cache_ffi", "mark_synced")
pub fn mark_synced(uri: String, server_id: String, version: Int) -> Nil

/// How long a server gets, from a batch of syncs reaching it, to
/// publish about the new text before a carried-over entry is answered
/// as it stands (ADR-038).
pub const settle_ms: Int = 2000

/// The calling proc is starting to write batch `n` of syncs. Called
/// before the first write: every entry cached after it was published
/// after the batch reached the server. It also starts the batch's
/// settle window.
@external(erlang, "pharos_diagnostics_cache_ffi", "mark_batch")
pub fn mark_batch(n: Int) -> Nil

/// The pool sent the proc `pid` batch `n`. A file's diagnostics depend
/// on the server's other files, so until that batch is stamped nothing
/// on that proc is fresh, and an entry from before it is not fresh
/// until the batch's settle window has passed. Past the window, a
/// server that has not republished a document the batch did not change
/// is taken to have left its diagnostics as they were.
@external(erlang, "pharos_diagnostics_cache_ffi", "expect_batch")
pub fn expect_batch(pid: Pid, n: Int) -> Nil

/// ADR-043: has the proc `pid` started writing batch `n`, or a later
/// one? It writes a batch whole, so a request sent after this reads
/// Reached reaches the server after the batch.
@external(erlang, "pharos_diagnostics_cache_ffi", "batch_status")
pub fn batch_status(pid: Pid, n: Int) -> StampStatus

/// The calling proc failed to write the document's sync.
@external(erlang, "pharos_diagnostics_cache_ffi", "mark_failed")
pub fn mark_failed(uri: String, server_id: String) -> Nil

/// The calling proc closed the document: the server is back on the disk.
/// Counts as reached for anyone still waiting on an earlier sync of it.
@external(erlang, "pharos_diagnostics_cache_ffi", "mark_closed")
pub fn mark_closed(uri: String, server_id: String) -> Nil

pub type StampStatus {
  Reached
  Pending
  Failed
}

/// Has the proc `pid` written the document's sync at `version` or later,
/// or closed the document since?
@external(erlang, "pharos_diagnostics_cache_ffi", "stamp_status")
pub fn stamp_status(
  uri: String,
  server_id: String,
  version: Int,
  pid: Pid,
) -> StampStatus

/// The pool recorded a sync of the document at `version`, to be
/// written by the proc `pid`.
@external(erlang, "pharos_diagnostics_cache_ffi", "expect")
pub fn expect(uri: String, server_id: String, version: Int, pid: Pid) -> Nil

/// Has the proc `pid` written the close of a document last synced at
/// `version`, or reopened it since?
@external(erlang, "pharos_diagnostics_cache_ffi", "close_status")
pub fn close_status(
  uri: String,
  server_id: String,
  version: Int,
  pid: Pid,
) -> StampStatus

/// The pool recorded a close of the document, to be written by the proc
/// `pid`. From then on, entries from before the close are not served.
@external(erlang, "pharos_diagnostics_cache_ffi", "expect_closed")
pub fn expect_closed(uri: String, server_id: String, pid: Pid) -> Nil

/// The proc `pid` is gone: drop every row it owned.
@external(erlang, "pharos_diagnostics_cache_ffi", "forget_proc")
pub fn forget_proc(pid: Pid) -> Nil

pub type Lookup {
  /// Published after the sync pharos expects was written, or for a
  /// document pharos does not hold open: the server's view of the text
  /// it has now.
  Fresh(params: Dynamic)
  /// Published before the expected sync of this document, or before
  /// the last batch of syncs on its proc while that batch's settle
  /// window lasts (another open document changed; diagnostics depend on
  /// other files), or that sync isn't written yet.
  /// Either the server has not yet answered for the new text, or it held
  /// back a set that did not change. Read it as "unsure", not as
  /// "unchanged".
  CarriedOver(params: Dynamic)
  /// Nothing cached, or only an entry from before pharos closed the
  /// document (the text it described is no longer held open; the file
  /// may be gone).
  Missing
}

/// The entry the proc `pid` cached for `(uri, server_id)`, and whether
/// it describes the text the server has now.
pub fn lookup(uri: String, server_id: String, pid: Pid) -> Lookup {
  lookup_within(uri, server_id, pid, settle_ms)
}

/// `lookup/3` with an explicit settle window, for tests.
@external(erlang, "pharos_diagnostics_cache_ffi", "lookup")
pub fn lookup_within(
  uri: String,
  server_id: String,
  pid: Pid,
  settle_window_ms: Int,
) -> Lookup

/// Milliseconds left in the settle window of the last batch sent to
/// the proc `pid`; 0 once it has passed. The window runs from the sync,
/// not from the question, so asking again later does not wait again.
pub fn settle_left_ms(pid: Pid) -> Int {
  settle_left_within(pid, settle_ms)
}

/// `settle_left_ms/1` with an explicit settle window, for tests.
@external(erlang, "pharos_diagnostics_cache_ffi", "settle_left")
pub fn settle_left_within(pid: Pid, settle_window_ms: Int) -> Int

/// #30: record a `$/progress` the calling proc read after readiness.
/// `kind` is `begin`, `report` or `end`.
@external(erlang, "pharos_diagnostics_cache_ffi", "progress")
pub fn progress(token: String, kind: String) -> Nil

/// #30: False while the proc `pid`'s server is still working on what
/// `uri`'s latest sync changed: a progress that began after the sync and
/// hasn't run past `stuck_ms` is running, or the server reports progress
/// and the sync is younger than `grace_ms`.
@external(erlang, "pharos_diagnostics_cache_ffi", "progress_quiet")
pub fn progress_quiet(
  uri: String,
  server_id: String,
  pid: Pid,
  grace_ms: Int,
  stuck_ms: Int,
) -> Bool

/// #27: True while the proc `pid`'s server has a progress running (it's
/// indexing) that began less than `stuck_ms` ago.
@external(erlang, "pharos_diagnostics_cache_ffi", "progress_active")
pub fn progress_active(pid: Pid, stuck_ms: Int) -> Bool

/// #38: ms since the latest sync of `uri` was written to proc `pid`'s
/// server; -1 if never.
@external(erlang, "pharos_diagnostics_cache_ffi", "sync_age_ms")
pub fn sync_age_ms(uri: String, server_id: String, pid: Pid) -> Int

/// #45: ms since proc `pid` cached its latest publish about `uri`; -1 if
/// it never has.
@external(erlang, "pharos_diagnostics_cache_ffi", "publish_age_ms")
pub fn publish_age_ms(uri: String, server_id: String, pid: Pid) -> Int

/// #45: the calling proc wrote the document's didOpen at `version`.
@external(erlang, "pharos_diagnostics_cache_ffi", "mark_opened")
pub fn mark_opened(uri: String, server_id: String, version: Int) -> Nil

/// #45: was the latest sync of `uri` written to proc `pid` its didOpen
/// (not a later change)?
@external(erlang, "pharos_diagnostics_cache_ffi", "last_sync_was_open")
pub fn last_sync_was_open(uri: String, server_id: String, pid: Pid) -> Bool

/// #44: ms since proc `pid` wrote its first didOpen; -1 if it hasn't.
@external(erlang, "pharos_diagnostics_cache_ffi", "first_open_age_ms")
pub fn first_open_age_ms(pid: Pid) -> Int

/// #44: did a progress of proc `pid` end less than `ms` ago?
@external(erlang, "pharos_diagnostics_cache_ffi", "progress_ended_within")
pub fn progress_ended_within(pid: Pid, ms: Int) -> Bool

/// #45: ms since the first publish after the latest sync of `uri` on proc
/// `pid`; -1 if none has come since that sync.
@external(erlang, "pharos_diagnostics_cache_ffi", "first_publish_age_ms")
pub fn first_publish_age_ms(uri: String, server_id: String, pid: Pid) -> Int

/// #46: get_diagnostics answered `[]` for `uri` from the server's silence
/// after its open. Not a publish; read only by a later question on the
/// still-unpublished file, which then waits as for a carried-over set.
@external(erlang, "pharos_diagnostics_cache_ffi", "mark_assumed_clean")
pub fn mark_assumed_clean(uri: String, server_id: String, pid: Pid) -> Nil

@external(erlang, "pharos_diagnostics_cache_ffi", "assumed_clean")
pub fn assumed_clean(uri: String, server_id: String, pid: Pid) -> Bool
