//// Diagnostics cache — Gleam wrapper over an ETS-backed store.
////
//// Why this exists: pharos's pool is didOpen-once per (lang,
//// workspace, uri) triple, but LSP servers emit
//// `textDocument/publishDiagnostics` only on first didOpen. Tools
//// that read diagnostics on subsequent calls time out unless we
//// remember what the server already told us.
////
//// The cache key is `(uri, server_id)`. Multi-LSP languages
//// (python = pyright + ruff) emit independently for the same URI;
//// keying by URI alone would overwrite one server's items with the
//// other's. `get_all_for_uri/1` returns every cached server's
//// entry for the URI so the multi-server merge path can stitch
//// them together.
////
//// Stale entries linger until either (a) a fresh
//// publishDiagnostics for the same `(uri, server_id)` overwrites,
//// (b) `drop/2` for a specific (uri, server_id), or (c) `drop_uri/1`
//// nukes every entry for the URI (used after a known edit).

import gleam/dynamic.{type Dynamic}

/// Initialise the underlying ETS table. Idempotent — calling more
/// than once is a no-op. Must run before the first `put` / `get`.
@external(erlang, "pharos_diagnostics_cache_ffi", "init")
pub fn init() -> Nil

/// Record the latest `publishDiagnostics.params` value for
/// `(uri, server_id)`. Subsequent reads via `get/2` return the same
/// value until it is overwritten or dropped.
@external(erlang, "pharos_diagnostics_cache_ffi", "put")
pub fn put(uri: String, server_id: String, value: Dynamic) -> Nil

/// Read the cached `publishDiagnostics.params` for
/// `(uri, server_id)`. Returns `Error(Nil)` when the cache has no
/// entry yet.
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

/// Forget every cache entry for `uri` regardless of server. Use
/// after a known content change.
@external(erlang, "pharos_diagnostics_cache_ffi", "drop_uri")
pub fn drop_uri(uri: String) -> Nil
