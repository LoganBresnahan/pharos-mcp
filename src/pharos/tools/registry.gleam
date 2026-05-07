//// Tool categorization + filter helper.
////
//// Every MCP tool pharos registers belongs to one of four categories
//// — `read`, `write`, `debug`, `raw` — exposed in `pharos/config` as
//// the `ToolCategory` enum. The category drives the user-visible
//// filter in `pharos.toml` / `PHAROS_TOOLS`:
////
////   tools = ["read", "write"]                      # categories
////   tools = ["read", "runtime_log_tail"]           # mix
////   tools = ["hover", "goto_definition"]           # explicit
////
//// Resolution lives in `config.tool_allowed/3`. This module owns the
//// canonical (name → category) mapping and one helper —
//// `is_allowed/1` — that combines the cached config's filter with
//// the lookup so callers (`mcp/server.tools_list_response`,
//// `tools/call` dispatch) do not have to thread the category through
//// every call site.
////
//// Adding a tool: register its name and category in `category_for/1`.
//// An unrecognised name falls back to `CatRaw` — power-user
//// behaviour that fails closed when the user opted into a stricter
//// filter (`["read"]` does not pick up unknown tools).

import pharos/config.{
  type ToolCategory, CatDebug, CatRaw, CatRead, CatWrite,
}

/// Canonical category for `name`. Unknown tools default to `CatRaw`
/// so an unfiltered surface keeps working while a strict filter
/// (`["read"]`) excludes anything new until it is explicitly
/// classified.
pub fn category_for(name: String) -> ToolCategory {
  case name {
    // -- read (LSP non-mutating) --
    "hover"
    | "goto_definition"
    | "goto_type_definition"
    | "goto_implementation"
    | "find_references"
    | "document_symbols"
    | "workspace_symbols"
    | "signature_help"
    | "call_hierarchy_prepare"
    | "call_hierarchy_incoming_calls"
    | "call_hierarchy_outgoing_calls"
    | "get_diagnostics"
    | "inlay_hints" -> CatRead

    // -- write (returns WorkspaceEdit data; or applies it on demand) --
    "rename_preview"
    | "format_document"
    | "code_actions"
    | "apply_workspace_edit" -> CatWrite

    // -- debug (pharos runtime introspection + sanity) --
    "echo"
    | "runtime_processes"
    | "runtime_supervision_tree"
    | "runtime_ets_tables"
    | "runtime_memory"
    | "runtime_applications"
    | "runtime_scheduler_util"
    | "runtime_pid_info"
    | "runtime_log_tail"
    | "runtime_log_clear"
    | "runtime_log_level"
    | "runtime_trace_lsp"
    | "runtime_trace_calls"
    | "runtime_kill_lsp" -> CatDebug

    // -- raw (power-user escape hatch) --
    "lsp_request_raw" -> CatRaw

    _ -> CatRaw
  }
}

/// True iff the cached Config exposes `name`. Drives both the
/// `tools/list` filter (omit disallowed entries) and the
/// `tools/call` gate (refuse a call to a name the filter excludes).
pub fn is_allowed(name: String) -> Bool {
  let cfg = config.cached()
  config.tool_allowed(cfg.tools, name, category_for(name))
}
