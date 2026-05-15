//// Tests for the configuration umbrella (`pharos/config`).
////
//// Pure-function coverage — defaults shape and the
//// `tool_allowed/3` resolver. Env overlay + TOML overlay are not
//// exercised here because they touch the OS environment and the
//// filesystem; release-prep tests cover those scenarios out of band.

import gleam/option.{None}
import gleeunit/should
import pharos/config.{
  type Config, CatDebug, CatDefault, CatRaw, CatRead, CatWrite, ToolFilter,
}

pub fn defaults_expose_default_profile_test() {
  let cfg = config.defaults()
  let filter = cfg.tools

  // Read surface — every read tool ships in the default profile.
  config.tool_allowed(filter, "hover", CatRead) |> should.be_true
  config.tool_allowed(filter, "inlay_hints", CatRead) |> should.be_true
  config.tool_allowed(filter, "semantic_tokens", CatRead) |> should.be_true
  config.tool_allowed(filter, "type_hierarchy_prepare", CatRead)
  |> should.be_true
  config.tool_allowed(filter, "type_hierarchy_supertypes", CatRead)
  |> should.be_true

  // Write surface — every write tool ships in the default profile.
  config.tool_allowed(filter, "rename_preview", CatWrite) |> should.be_true
  config.tool_allowed(filter, "apply_workspace_edit", CatWrite)
  |> should.be_true

  // CatDefault essentials — the LLM-facing escape hatches that read
  // and write tools tell the LLM to call when timeouts surface.
  config.tool_allowed(filter, "runtime_set_tool_timeout", CatDefault)
  |> should.be_true
  config.tool_allowed(filter, "runtime_effective_tool_config", CatDefault)
  |> should.be_true
  config.tool_allowed(filter, "runtime_language_config", CatDefault)
  |> should.be_true
  config.tool_allowed(filter, "echo", CatDefault) |> should.be_true

  // Debug + raw are NOT in the default profile — opt-in via
  // `tools = ["default", "debug"]` or explicit names.
  config.tool_allowed(filter, "runtime_processes", CatDebug) |> should.be_false
  config.tool_allowed(filter, "lsp_request_raw", CatRaw) |> should.be_false
}

pub fn default_alias_subsumes_read_write_default_test() {
  // The `"default"` meta-alias resolves to (read ∪ write ∪ CatDefault).
  // It should NOT pull debug or raw — those stay opt-in.
  let filter = ToolFilter(entries: ["default"])
  config.tool_allowed(filter, "hover", CatRead) |> should.be_true
  config.tool_allowed(filter, "rename_preview", CatWrite) |> should.be_true
  config.tool_allowed(filter, "runtime_set_tool_timeout", CatDefault)
  |> should.be_true
  config.tool_allowed(filter, "runtime_processes", CatDebug) |> should.be_false
  config.tool_allowed(filter, "lsp_request_raw", CatRaw) |> should.be_false
}

pub fn default_plus_debug_unions_categories_test() {
  // Production-debug profile: ship the default surface AND let the
  // user reach diagnostics without naming each tool explicitly.
  let filter = ToolFilter(entries: ["default", "debug"])
  config.tool_allowed(filter, "hover", CatRead) |> should.be_true
  config.tool_allowed(filter, "runtime_processes", CatDebug) |> should.be_true
  config.tool_allowed(filter, "runtime_set_tool_timeout", CatDefault)
  |> should.be_true
  config.tool_allowed(filter, "lsp_request_raw", CatRaw) |> should.be_false
}

pub fn category_alias_admits_unknown_member_test() {
  // A future debug tool that the user never names explicitly should
  // still be allowed when the user's filter includes the category.
  let filter = ToolFilter(entries: ["debug"])
  config.tool_allowed(filter, "runtime_future_thing", CatDebug)
  |> should.be_true
}

pub fn literal_name_admits_specific_tool_test() {
  // Filter excludes the category but names the tool directly.
  let filter = ToolFilter(entries: ["read", "runtime_log_tail"])
  config.tool_allowed(filter, "runtime_log_tail", CatDebug)
  |> should.be_true
}

pub fn category_omitted_means_blocked_test() {
  let filter = ToolFilter(entries: ["read"])
  config.tool_allowed(filter, "rename_preview", CatWrite) |> should.be_false
  config.tool_allowed(filter, "runtime_processes", CatDebug) |> should.be_false
  config.tool_allowed(filter, "lsp_request_raw", CatRaw) |> should.be_false
}

pub fn empty_filter_blocks_everything_test() {
  let filter = ToolFilter(entries: [])
  config.tool_allowed(filter, "hover", CatRead) |> should.be_false
  config.tool_allowed(filter, "rename_preview", CatWrite) |> should.be_false
}

pub fn all_alias_exposes_every_category_test() {
  // The `"all"` meta-alias is the inverse of `[]` — every tool in
  // every category is exposed. Used by dogfood / debug / power-user
  // installs that want the full surface in one entry.
  let filter = ToolFilter(entries: ["all"])
  config.tool_allowed(filter, "hover", CatRead) |> should.be_true
  config.tool_allowed(filter, "rename_preview", CatWrite) |> should.be_true
  config.tool_allowed(filter, "runtime_processes", CatDebug) |> should.be_true
  config.tool_allowed(filter, "lsp_request_raw", CatRaw) |> should.be_true
  config.tool_allowed(filter, "runtime_set_tool_timeout", CatDefault)
  |> should.be_true
}

pub fn defaults_use_stdio_transport_test() {
  let cfg: Config = config.defaults()
  cfg.transport |> should.equal(config.Stdio)
}

pub fn defaults_have_loopback_bind_test() {
  let cfg = config.defaults()
  cfg.http.bind |> should.equal("127.0.0.1")
}

pub fn defaults_have_no_log_file_test() {
  let cfg = config.defaults()
  cfg.log.file |> should.equal(None)
}
