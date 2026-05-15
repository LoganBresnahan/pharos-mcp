//// Render a `LanguageConfig` as TOML the user could paste into
//// pharos.toml. Backs both the `--print-language-config <lang>` CLI
//// flag and the `runtime_language_config` MCP tool — same renderer
//// keeps the two surfaces from drifting.
////
//// Output shape mirrors `[languages.<id>]` + `[[languages.<id>.servers]]`
//// override syntax exactly. A user wanting to tweak ONE field copies
//// the printed block, edits, drops into pharos.toml. No manual
//// schema reverse-engineering.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pharos/lsp/languages.{
  type LanguageConfig, type MethodScope, type ServerConfig, All, Only, Pull,
  Push,
}

/// Render every language in the registry as one big TOML string.
/// Languages separated by blank lines.
pub fn render_registry(registry: Dict(String, LanguageConfig)) -> String {
  let configs = dict.values(registry)
  configs
  |> list.map(render_language)
  |> string.join("\n\n")
}

/// Render one `LanguageConfig` as TOML. Includes the language-level
/// `[languages.<id>]` header and an `[[languages.<id>.servers]]` table
/// per server. Internal fields that have no override hook
/// (`root_promotion`) are emitted as a comment so the user knows
/// they're locked.
pub fn render_language(config: LanguageConfig) -> String {
  let header = "[languages." <> config.id <> "]"
  let extensions =
    "file_extensions = " <> render_string_list(config.file_extensions)
  let markers = "root_markers = " <> render_string_list(config.root_markers)
  let promotion_comment = case config.root_promotion {
    languages.NoPromotion -> "# root_promotion is locked to NoPromotion (not user-overridable)"
    languages.CargoWorkspacePromotion ->
      "# root_promotion is locked to CargoWorkspacePromotion (not user-overridable; ADR-015)"
  }
  let lang_block =
    [header, extensions, markers, promotion_comment]
    |> string.join("\n")

  let server_blocks =
    config.servers
    |> list.map(fn(server) { render_server(config.id, server) })
    |> string.join("\n\n")

  case config.servers {
    [] -> lang_block
    _ -> lang_block <> "\n\n" <> server_blocks
  }
}

fn render_server(language_id: String, server: ServerConfig) -> String {
  let header = "[[languages." <> language_id <> ".servers]]"
  let lines = [
    header,
    "id = " <> render_string(server.id),
    "command = " <> render_string(server.command),
    "args = " <> render_string_list(server.args),
    "methods = " <> render_methods(server.methods),
    "diagnostics_mode = " <> render_diagnostics_mode(server.diagnostics_mode),
    "readiness_token = " <> render_optional_string(server.readiness_token),
    render_optional_int(
      "ready_timeout_ms",
      server.ready_timeout_ms,
      "60000",
    ),
    render_optional_int(
      "initialize_timeout_ms",
      server.initialize_timeout_ms,
      "90000",
    ),
    render_init_options(server.initialization_options),
    render_workspace_config(server.workspace_configuration),
  ]
  string.join(lines, "\n")
}

fn render_string(s: String) -> String {
  // TOML basic strings; escape double-quotes and backslashes. Newlines
  // we don't expect for these fields.
  "\""
  <> s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  <> "\""
}

fn render_string_list(xs: List(String)) -> String {
  let inner =
    xs
    |> list.map(render_string)
    |> string.join(", ")
  "[" <> inner <> "]"
}

fn render_optional_string(s: option.Option(String)) -> String {
  case s {
    None -> "\"\"  # bundled default has no readiness token"
    Some(v) -> render_string(v)
  }
}

fn render_optional_int(
  field_name: String,
  value: option.Option(Int),
  default_str: String,
) -> String {
  case value {
    option.Some(n) ->
      field_name <> " = " <> int_to_string(n)
    option.None ->
      "# "
      <> field_name
      <> " uses bundled default ("
      <> default_str
      <> "ms)"
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

fn render_methods(scope: MethodScope) -> String {
  case scope {
    All -> "[]  # empty list = All-scope (claims every method as fallback)"
    Only(methods) -> render_string_list(methods)
  }
}

fn render_diagnostics_mode(mode: languages.DiagnosticsMode) -> String {
  case mode {
    Push -> "\"push\""
    Pull -> "\"pull\""
  }
}

fn render_init_options(value: json.Json) -> String {
  let encoded = json.to_string(value)
  // Empty object is the most common case; emit a one-liner.
  case encoded {
    "{}" -> "initialization_options_json = '''{}'''"
    _ -> "initialization_options_json = '''\n" <> encoded <> "\n'''"
  }
}

fn render_workspace_config(
  config: option.Option(Dict(String, json.Json)),
) -> String {
  case config {
    None ->
      "# workspace_configuration_json: bundled default sends nothing.\n"
      <> "# Example: workspace_configuration_json = '''{\"section\": {...}}'''"
    Some(d) -> {
      let entries =
        dict.to_list(d)
        |> list.map(fn(pair) {
          let #(key, value) = pair
          "\"" <> key <> "\":" <> json.to_string(value)
        })
        |> string.join(",\n  ")
      "workspace_configuration_json = '''\n{\n  " <> entries <> "\n}\n'''"
    }
  }
}
