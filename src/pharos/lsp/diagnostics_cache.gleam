//// Diagnostics cache — Gleam wrapper over an ETS-backed store.
////
//// Why this exists: pharos's pool is didOpen-once per (lang,
//// workspace, uri) triple, but LSP servers emit
//// `textDocument/publishDiagnostics` only on first didOpen. Tools
//// that read diagnostics on subsequent calls time out unless we
//// remember what the server already told us.
////
//// The cache key is the file URI. Values are the raw `params`
//// `Dynamic` from the publishDiagnostics notification (verbatim
//// LSP shape `{uri, version?, diagnostics}`). Stale entries linger
//// until either (a) a fresh publishDiagnostics for the same URI
//// overwrites, or (b) a future tool calls `drop/1` after a known
//// edit. Stage 2 second-pass C lands the read/write side; explicit
//// cache invalidation lands later if needed.

import gleam/dynamic.{type Dynamic}

/// Initialise the underlying ETS table. Idempotent — calling more
/// than once is a no-op. Must run before the first `put` / `get`.
@external(erlang, "pharos_diagnostics_cache_ffi", "init")
pub fn init() -> Nil

/// Record the latest `publishDiagnostics.params` value for `uri`.
/// Subsequent reads via `get/1` return the same value until it is
/// overwritten or dropped.
@external(erlang, "pharos_diagnostics_cache_ffi", "put")
pub fn put(uri: String, value: Dynamic) -> Nil

/// Read the cached `publishDiagnostics.params` for `uri`. Returns
/// `Error(Nil)` when the cache has no entry for the URI yet.
@external(erlang, "pharos_diagnostics_cache_ffi", "get")
pub fn get(uri: String) -> Result(Dynamic, Nil)

/// Forget the cache entry for `uri`. Used when callers know the
/// content has changed and a stale entry would mislead.
@external(erlang, "pharos_diagnostics_cache_ffi", "drop")
pub fn drop(uri: String) -> Nil
