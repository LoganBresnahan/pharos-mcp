//// Tests for the per-(uri, server_id) diagnostics cache (M11).
////
//// Before the rekey, the cache key was bare `uri`, so two LSPs
//// emitting publishDiagnostics for the same file (python = pyright +
//// ruff) would clobber each other and the merge path would surface
//// only one server's items. These tests lock down the new shape.

import gleam/dynamic
import gleam/list
import gleeunit/should
import pharos/lsp/diagnostics_cache

pub fn put_then_get_for_one_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///x.py")

  diagnostics_cache.put("file:///x.py", "pyright", dynamic.string("PY-1"))
  let assert Ok(v) = diagnostics_cache.get("file:///x.py", "pyright")
  v |> should.equal(dynamic.string("PY-1"))
}

pub fn two_servers_same_uri_do_not_clobber_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///x.py")

  diagnostics_cache.put("file:///x.py", "pyright", dynamic.string("PY-A"))
  diagnostics_cache.put("file:///x.py", "ruff", dynamic.string("RUFF-A"))

  let assert Ok(py) = diagnostics_cache.get("file:///x.py", "pyright")
  py |> should.equal(dynamic.string("PY-A"))

  let assert Ok(rf) = diagnostics_cache.get("file:///x.py", "ruff")
  rf |> should.equal(dynamic.string("RUFF-A"))
}

pub fn get_all_for_uri_returns_every_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///y.py")

  diagnostics_cache.put("file:///y.py", "pyright", dynamic.string("a"))
  diagnostics_cache.put("file:///y.py", "ruff", dynamic.string("b"))

  let rows = diagnostics_cache.get_all_for_uri("file:///y.py")
  list.length(rows) |> should.equal(2)
}

pub fn drop_one_server_leaves_other_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///z.py")

  diagnostics_cache.put("file:///z.py", "pyright", dynamic.string("P"))
  diagnostics_cache.put("file:///z.py", "ruff", dynamic.string("R"))

  diagnostics_cache.drop("file:///z.py", "pyright")

  case diagnostics_cache.get("file:///z.py", "pyright") {
    Ok(_) -> panic as { "pyright entry should be dropped" }
    Error(_) -> Nil
  }
  let assert Ok(_) = diagnostics_cache.get("file:///z.py", "ruff")
}

pub fn drop_uri_nukes_every_server_test() {
  diagnostics_cache.init()
  diagnostics_cache.drop_uri("file:///w.py")

  diagnostics_cache.put("file:///w.py", "pyright", dynamic.string("P"))
  diagnostics_cache.put("file:///w.py", "ruff", dynamic.string("R"))

  diagnostics_cache.drop_uri("file:///w.py")

  diagnostics_cache.get_all_for_uri("file:///w.py")
  |> list.length
  |> should.equal(0)
}
