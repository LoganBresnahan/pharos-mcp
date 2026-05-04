//// Environment variable lookup.
////
//// Thin wrapper around `os:getenv/1` exposed via FFI. Returns
//// `None` when the variable is unset, `Some(value)` when set
//// (including the empty string).

import gleam/option.{type Option}

@external(erlang, "llm_lsp_mcp_env_ffi", "get")
pub fn get(name: String) -> Option(String)
