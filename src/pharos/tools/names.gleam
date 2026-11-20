//// Every MCP tool name pharos registers, in one leaf module (#32).
////
//// `pharos/config_keys` checks `[tool_config.<name>]` against this list,
//// and it can't import the tool modules or the server: they import
//// `pharos/config`. `config_keys_test` compares this list with the
//// server's registered tool definitions, both ways, so adding or removing
//// a tool without updating it fails the suite.

/// Sorted.
pub fn all() -> List(String) {
  [
    "apply_workspace_edit",
    "call_hierarchy_incoming_calls",
    "call_hierarchy_outgoing_calls",
    "call_hierarchy_prepare",
    "code_actions",
    "containing_symbol",
    "document_symbols",
    "echo",
    "edit_at_symbol",
    "fetch_uri_contents",
    "find_references",
    "find_referencing_symbols",
    "find_symbol",
    "format_document",
    "get_diagnostics",
    "get_symbols_overview",
    "goto_definition",
    "goto_implementation",
    "goto_type_definition",
    "hover",
    "inlay_hints",
    "lsp_request_raw",
    "memory_audit",
    "memory_get",
    "memory_list",
    "memory_prune",
    "memory_save",
    "rename_preview",
    "runtime_applications",
    "runtime_effective_tool_config",
    "runtime_ets_tables",
    "runtime_kill_lsp",
    "runtime_language_config",
    "runtime_log_clear",
    "runtime_log_level",
    "runtime_log_tail",
    "runtime_lsp_state",
    "runtime_memory",
    "runtime_pid_info",
    "runtime_pool_recon",
    "runtime_processes",
    "runtime_scheduler_util",
    "runtime_server_capabilities",
    "runtime_set_tool_timeout",
    "runtime_supervision_tree",
    "runtime_trace_calls",
    "runtime_trace_lsp",
    "semantic_tokens",
    "signature_help",
    "type_hierarchy_prepare",
    "type_hierarchy_subtypes",
    "type_hierarchy_supertypes",
    "workspace_symbols",
  ]
}

/// The category aliases and presets a `tools = [...]` entry may name
/// besides a tool (`pharos/config.tool_allowed`).
pub fn filter_aliases() -> List(String) {
  ["read", "write", "memory", "debug", "raw", "default", "all"]
}
