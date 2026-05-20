//// Tool categorization + filter helper.
////
//// Every MCP tool pharos registers belongs to one of five categories
//// — `read`, `write`, `default`, `debug`, `raw` — exposed in
//// `pharos/config` as the `ToolCategory` enum. The category drives
//// the user-visible filter in `pharos.toml` / `PHAROS_TOOLS`:
////
////   tools = ["default"]                            # production preset
////   tools = ["read", "write"]                      # categories (subset)
////   tools = ["default", "debug"]                   # opt-in diagnostics
////   tools = ["read", "runtime_log_tail"]           # mix
////   tools = ["hover", "goto_definition"]           # explicit
////
//// `default` is a meta-alias that resolves to (read ∪ write ∪
//// CatDefault) — see `config.tool_allowed/3`. Tools placed in
//// `CatDefault` are NOT read or write themselves but ship in the
//// default production profile because the read/write surface
//// relies on them (today: the three timeout-recovery knobs from
//// ADR-021's 5-layer stack — `runtime_set_tool_timeout`,
//// `runtime_effective_tool_config`, `runtime_language_config`).
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
//// filter (`["read"]` does not pick up unknown tools). When adding
//// a runtime tool that the LLM-facing surface depends on (e.g.,
//// future `runtime_session_digest`), classify it as `CatDefault`
//// so it ships alongside read/write.

import pharos/config.{
  type ToolCategory, CatDebug, CatDefault, CatMemory, CatRaw, CatRead, CatWrite,
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
    | "inlay_hints"
    | "semantic_tokens"
    | "type_hierarchy_prepare"
    | "type_hierarchy_supertypes"
    | "type_hierarchy_subtypes"
    // -- ADR-026 symbol layer (read paths) --
    | "find_symbol"
    | "get_symbols_overview"
    | "containing_symbol"
    | "find_referencing_symbols" -> CatRead

    // -- write (returns WorkspaceEdit data; or applies it on demand) --
    "rename_preview"
    | "format_document"
    | "code_actions"
    | "apply_workspace_edit"
    // -- ADR-026 symbol layer (preview-only write path) --
    | "edit_at_symbol" -> CatWrite

    // -- default (essentials the LLM needs to follow tool-error
    //    recovery recipes; ship in the production default profile
    //    alongside read/write). Keep this list small — every entry
    //    here widens the prod attack surface. `echo` is included
    //    as the smoke-test affordance an MCP host can hit before
    //    any LSP-bound tool, useful for diagnosing transport
    //    issues without exposing the rest of the debug surface.
    "echo"
    | "runtime_set_tool_timeout"
    | "runtime_effective_tool_config"
    | "runtime_language_config"
    | "runtime_server_capabilities" -> CatDefault

    // -- ADR-027 memory tools --
    "memory_save"
    | "memory_get"
    | "memory_list"
    | "memory_prune"
    | "memory_audit" -> CatMemory

    // -- debug (pharos runtime introspection + sanity; opt-in
    //    via `tools = ["default", "debug"]` or explicit names) --
    "runtime_processes"
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
    | "runtime_kill_lsp"
    | "runtime_lsp_state"
    | "runtime_pool_recon" -> CatDebug

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
