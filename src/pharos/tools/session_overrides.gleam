//// Session-scoped tool_config overrides.
////
//// ADR 021's layer 4 in the timeout-resolution stack: an in-memory
//// override map the LLM can populate at runtime via the
//// `runtime_set_tool_timeout` MCP tool. Scoped to the MCP session
//// that set it (ADR-034): one agent's "jdtls is slow, wait 5 min"
//// must not change another agent's behaviour. Lives until the
//// session disconnects (`drop/1`) or pharos restarts. Beats TOML
//// overrides; loses to the per-call `timeout_ms` arg that the
//// decoder already short-circuits.
////
//// Stored in persistent_term so reads are O(1) from every actor
//// without ETS coordination. The outer map is keyed by session id.
//// Writes replace the whole map (small data, infrequent writes).

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/result
import pharos/session_ctx

/// Per-tool override carrier. `global` applies when no language is
/// resolved or the per-lang map has no entry for the resolved
/// language. Mirrors `config.ToolConfig`'s shape so the resolution
/// logic looks the same.
pub type ToolOverride {
  ToolOverride(global: Option(Int), languages: Dict(String, Int))
}

/// Look up a session-scoped override for `(tool, lang)`. Returns
/// `Some(timeout_ms)` if either the per-lang or global override
/// applies (per-lang wins); `None` otherwise so the caller falls
/// through to the TOML / compile-time layers.
pub fn get(tool: String, lang: Option(String)) -> Option(Int) {
  let map = session_map()
  case dict.get(map, tool) {
    Error(_) -> None
    Ok(override) -> {
      let per_lang = case lang {
        None -> None
        Some(l) ->
          case dict.get(override.languages, l) {
            Ok(n) -> Some(n)
            Error(_) -> None
          }
      }
      case per_lang {
        Some(_) -> per_lang
        None -> override.global
      }
    }
  }
}

/// Set a session-scoped override. `lang = None` writes to the
/// per-tool global slot; `lang = Some("rust")` writes the per-lang
/// slot. Replaces any existing value at the targeted slot.
pub fn set(tool: String, lang: Option(String), timeout_ms: Int) -> Nil {
  let map = session_map()
  let existing =
    dict.get(map, tool)
    |> result.unwrap(empty_override())
  let updated = case lang {
    None -> ToolOverride(..existing, global: Some(timeout_ms))
    Some(l) ->
      ToolOverride(
        ..existing,
        languages: dict.insert(existing.languages, l, timeout_ms),
      )
  }
  let new_map = dict.insert(map, tool, updated)
  store(dict.insert(load_or_empty(), session_ctx.id(), new_map))
}

/// Snapshot the calling session's overrides for the digest tool
/// (ADR 022 + Phase 4).
pub fn snapshot() -> Dict(String, ToolOverride) {
  session_map()
}

/// Forget every override a session set. Called when it disconnects.
pub fn drop(session_id: String) -> Nil {
  let all = load_or_empty()
  case dict.has_key(all, session_id) {
    False -> Nil
    True -> store(dict.delete(all, session_id))
  }
}

fn session_map() -> Dict(String, ToolOverride) {
  dict.get(load_or_empty(), session_ctx.id())
  |> result.unwrap(dict.new())
}

fn empty_override() -> ToolOverride {
  ToolOverride(global: None, languages: dict.new())
}

fn load_or_empty() -> Dict(String, Dict(String, ToolOverride)) {
  case load() {
    Ok(map) -> map
    Error(_) -> dict.new()
  }
}

@external(erlang, "pharos_runtime_ffi", "session_overrides_store")
fn store(map: Dict(String, Dict(String, ToolOverride))) -> Nil

@external(erlang, "pharos_runtime_ffi", "session_overrides_load")
fn load() -> Result(Dict(String, Dict(String, ToolOverride)), Nil)
