//// Environment variable lookup.
////
//// Thin wrapper around `os:getenv/1` exposed via FFI. Returns
//// `None` when the variable is unset, `Some(value)` when set
//// (including the empty string).

import gleam/option.{type Option}

@external(erlang, "pharos_env_ffi", "get")
pub fn get(name: String) -> Option(String)
