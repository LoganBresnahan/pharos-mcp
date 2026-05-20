//// Effective language registry — bundled defaults overlaid with
//// user-supplied overrides from `pharos/config.languages`.
////
//// pharos ships with hardcoded LSP commands matching the developer's
//// dev box. End users on different machines have those binaries
//// somewhere else, and may want to add languages pharos does not
//// bundle. This module reads the cached `Config`, merges
//// `Config.languages` over the bundled defaults, and stashes the
//// resulting registry in `persistent_term` so per-request lookups
//// run at O(1) without re-parsing.
////
//// Override precedence: TOML files (global + project) → env vars,
//// resolved by `pharos/config.load/0`. By the time `init/0` runs,
//// `Config.languages` already reflects the merged user input.
////
//// Two override shapes are accepted (both processed in
//// `merge_one/2`):
////
////   - **Flat (legacy + simple).** `command`, `args`,
////     `diagnostics_mode`, `readiness_token` at the language level
////     patch the language's primary (first) server. Convenient for
////     swapping a single binary path.
////
////   - **Per-server (`[[languages.<id>.servers]]`).** TOML array
////     of tables. Each entry merges into the matching default by
////     `id`. An entry whose `id` is absent from the defaults
////     APPENDS as a new server to the language's `servers` list —
////     useful for layering additional servers (mypy alongside
////     pyright + ruff, eslint-language-server alongside
////     typescript-language-server, etc.).
////
//// When both shapes are supplied in one override, the per-server
//// array is applied first; the flat fields then patch the
//// resulting primary server's matching fields.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import pharos/config.{type LanguageOverride, type ServerOverride}
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/languages.{
  type DiagnosticsMode, type LanguageConfig, type LookupError, type MethodScope,
  type ServerConfig, All, LanguageConfig, NoPromotion, Only, ProbeWorkspaceSymbol,
  Pull, Push, ServerConfig,
}

/// Load the effective registry into `persistent_term`. Call once at
/// boot. Subsequent lookups via `for_uri/1` do not re-parse.
pub fn init() -> Nil {
  let cfg = config.cached()
  let registry = case dict.size(cfg.languages) {
    0 -> languages.default_registry()
    _ -> {
      log.fields_at(
        "pharos/lsp/registry",
        log_entry.Info,
        "applied language override(s) from pharos config",
        [#("count", int_str(dict.size(cfg.languages)))],
      )
      merge_overrides(languages.default_registry(), cfg.languages)
    }
  }
  store(registry)
  Nil
}

@external(erlang, "erlang", "integer_to_binary")
fn int_str(n: Int) -> String

/// Read the registry stored by `init/0`. Falls back to bundled
/// defaults if `init` was not yet called.
pub fn cached() -> Dict(String, LanguageConfig) {
  case load() {
    Ok(registry) -> registry
    Error(_) -> languages.default_registry()
  }
}

/// Resolve a file URI through the cached registry.
pub fn for_uri(uri: String) -> Result(LanguageConfig, LookupError) {
  languages.for_uri(cached(), uri)
}

/// Resolve a language id (e.g. `"rust"`, `"go"`) through the cached
/// registry. Used by tools that accept an explicit language argument.
pub fn for_language(id: String) -> Result(LanguageConfig, LookupError) {
  case dict.get(cached(), id) {
    Ok(config) -> Ok(config)
    Error(_) -> Error(languages.UnknownLanguage(id))
  }
}

/// ADR-029. Resolve a custom URI scheme (e.g. `jdt://...`) through
/// the cached registry. Returns the language + scheme metadata for
/// the language that claims the URI's scheme. `Error(Nil)` when the
/// URI shape is malformed or no language claims the scheme.
pub fn for_custom_uri(
  uri: String,
) -> Result(#(LanguageConfig, languages.CustomUriScheme), Nil) {
  languages.for_custom_uri(cached(), uri)
}

/// ADR-029. All `(scheme, language_id)` pairs across the registry.
/// Used by the MCP `instructions` advert generator.
pub fn all_custom_schemes() -> List(#(String, String)) {
  languages.all_custom_schemes(cached())
}

// -- Persistent-term backing ---------------------------------------------

@external(erlang, "pharos_runtime_ffi", "registry_store")
fn store(registry: Dict(String, LanguageConfig)) -> Nil

@external(erlang, "pharos_runtime_ffi", "registry_load")
fn load() -> Result(Dict(String, LanguageConfig), Nil)

// -- Override merging ----------------------------------------------------

fn merge_overrides(
  defaults: Dict(String, LanguageConfig),
  overrides: Dict(String, LanguageOverride),
) -> Dict(String, LanguageConfig) {
  dict.fold(overrides, defaults, fn(acc, key, override) {
    case dict.get(acc, key) {
      Error(_) -> dict.insert(acc, key, partial_to_full(key, override))
      Ok(default) -> dict.insert(acc, key, merge_one(default, override))
    }
  })
}

/// Promote a bare `LanguageOverride` to a `LanguageConfig`. Fires
/// only for brand-new languages NOT in `default_registry`.
///
/// Two override shapes are honored, matching `merge_one`:
///   1. `[[languages.<key>.servers]]` — per-server entries become
///      fresh ServerConfigs (via `apply_server_overrides` against an
///      empty defaults list, so each entry with an `id` appends).
///   2. Flat fields (`command`, `args`, etc.) — synthesize a primary
///      ServerConfig if the per-server array yielded none, then in
///      either case patch the resulting first server with
///      `merge_primary` so the flat-shape fields land on the primary.
///
/// `command` and `file_extensions` are still required for usefulness;
/// missing values yield a registry entry that fails to spawn (visible
/// via `pharos --doctor`).
fn partial_to_full(key: String, override: LanguageOverride) -> LanguageConfig {
  let from_array = case override.servers {
    None -> []
    Some(server_overrides) -> apply_server_overrides([], server_overrides)
  }
  let with_primary = case from_array {
    [] -> [synth_primary(key, override)]
    _ -> from_array
  }
  let final_servers = case with_primary {
    [] -> []
    [primary, ..rest] -> [merge_primary(primary, override), ..rest]
  }
  LanguageConfig(
    id: option.unwrap(override.id, key),
    file_extensions: option.unwrap(override.file_extensions, []),
    root_markers: option.unwrap(override.root_markers, []),
    root_promotion: NoPromotion,
    servers: final_servers,
    // ADR-029: user-defined language entries get no custom URI
    // schemes by default. Adding them via toml is deferred post-v1.0.
    custom_uri_schemes: dict.new(),
  )
}

fn synth_primary(key: String, override: LanguageOverride) -> ServerConfig {
  ServerConfig(
    id: key,
    command: option.unwrap(override.command, ""),
    args: option.unwrap(override.args, []),
    initialization_options: json.object([]),
    workspace_configuration: None,
    methods: All,
    diagnostics_mode: parse_mode(override.diagnostics_mode),
    readiness_token: override.readiness_token,
    ready_timeout_ms: override.ready_timeout_ms,
    initialize_timeout_ms: override.initialize_timeout_ms,
    warmup_probe: ProbeWorkspaceSymbol(""),
  )
}

/// Apply an override (flat fields and/or `servers` array) to an
/// existing `LanguageConfig`. The per-server array is applied
/// first — for each `ServerOverride`, find the matching ServerConfig
/// in defaults by id and merge fields, or append as a new server if
/// no match exists. Then the flat fields patch the resulting primary
/// server's matching fields. Language-level fields
/// (file_extensions, root_markers) replace the parent record's.
fn merge_one(default: LanguageConfig, override: LanguageOverride) -> LanguageConfig {
  // Step 1: per-server array merge / append.
  let after_servers_array = case override.servers {
    None -> default.servers
    Some(server_overrides) ->
      apply_server_overrides(default.servers, server_overrides)
  }
  // Step 2: flat fields patch primary server.
  let merged_servers = case after_servers_array {
    [] -> after_servers_array
    [primary, ..rest] -> [merge_primary(primary, override), ..rest]
  }
  LanguageConfig(
    id: case override.id {
      Some(s) -> s
      None -> default.id
    },
    file_extensions: case override.file_extensions {
      Some(xs) -> xs
      None -> default.file_extensions
    },
    root_markers: case override.root_markers {
      Some(xs) -> xs
      None -> default.root_markers
    },
    root_promotion: default.root_promotion,
    servers: merged_servers,
    // ADR-029: toml overrides of `custom_uri_schemes` are deferred to
    // post-v1.0. The merger passes the default through verbatim so
    // the jdt:// entry on java() reaches the registry unchanged.
    custom_uri_schemes: default.custom_uri_schemes,
  )
}

/// Per-server merge step. Iterate the override array; each entry
/// either patches an existing server (matched by `id`) or appends
/// as a new server (for ids absent from the defaults). Servers from
/// the defaults that the override didn't touch keep their existing
/// shape.
fn apply_server_overrides(
  defaults: List(ServerConfig),
  overrides: List(ServerOverride),
) -> List(ServerConfig) {
  list.fold(overrides, defaults, fn(acc, ovr) {
    case ovr.id {
      None -> acc
      Some(target_id) -> apply_one_server_override(acc, target_id, ovr)
    }
  })
}

fn apply_one_server_override(
  servers: List(ServerConfig),
  target_id: String,
  ovr: ServerOverride,
) -> List(ServerConfig) {
  let #(found, patched) =
    list.fold(servers, #(False, []), fn(state, server) {
      let #(matched, acc) = state
      case server.id == target_id {
        True -> #(True, [merge_server(server, ovr), ..acc])
        False -> #(matched, [server, ..acc])
      }
    })
  let in_order = list.reverse(patched)
  case found {
    True -> in_order
    False -> list.append(in_order, [server_from_override(target_id, ovr)])
  }
}

/// Per-server field merge. `methods = [...]` overrides the scope
/// (translates to `Only(methods)`); omitted methods keeps the
/// default. To force `All` scope on an override, omit `methods` and
/// rely on the default; this module never lets a TOML override
/// downgrade a server's scope from `Only` back to `All` because no
/// real use case has surfaced.
fn merge_server(
  default: ServerConfig,
  ovr: ServerOverride,
) -> ServerConfig {
  ServerConfig(
    id: default.id,
    command: case ovr.command {
      Some(s) -> s
      None -> default.command
    },
    args: case ovr.args {
      Some(xs) -> xs
      None -> default.args
    },
    initialization_options: parse_init_options_or(
      ovr.initialization_options_json,
      default.initialization_options,
      default.id,
    ),
    workspace_configuration: parse_workspace_config_or(
      ovr.workspace_configuration_json,
      default.workspace_configuration,
      default.id,
    ),
    methods: parse_methods(ovr.methods, default.methods),
    diagnostics_mode: case ovr.diagnostics_mode {
      None -> default.diagnostics_mode
      Some(_) -> parse_mode(ovr.diagnostics_mode)
    },
    readiness_token: case ovr.readiness_token {
      None -> default.readiness_token
      Some(_) -> ovr.readiness_token
    },
    ready_timeout_ms: case ovr.ready_timeout_ms {
      None -> default.ready_timeout_ms
      Some(_) -> ovr.ready_timeout_ms
    },
    initialize_timeout_ms: case ovr.initialize_timeout_ms {
      None -> default.initialize_timeout_ms
      Some(_) -> ovr.initialize_timeout_ms
    },
    warmup_probe: default.warmup_probe,
  )
}

/// Build a brand-new ServerConfig from an override entry whose `id`
/// is absent from the defaults. `command` is required for usefulness;
/// an entry with no `command` still appears in the registry but will
/// fail to spawn (visible via `pharos --doctor`). Methods default to
/// `All`.
fn server_from_override(target_id: String, ovr: ServerOverride) -> ServerConfig {
  ServerConfig(
    id: target_id,
    command: option.unwrap(ovr.command, ""),
    args: option.unwrap(ovr.args, []),
    initialization_options: json.object([]),
    workspace_configuration: None,
    methods: parse_methods(ovr.methods, All),
    diagnostics_mode: parse_mode(ovr.diagnostics_mode),
    readiness_token: ovr.readiness_token,
    ready_timeout_ms: ovr.ready_timeout_ms,
    initialize_timeout_ms: ovr.initialize_timeout_ms,
    warmup_probe: ProbeWorkspaceSymbol(""),
  )
}

fn parse_methods(
  raw: Option(List(String)),
  fallback: MethodScope,
) -> MethodScope {
  case raw {
    None -> fallback
    Some([]) -> All
    Some(methods) -> Only(methods)
  }
}

fn merge_primary(
  primary: ServerConfig,
  override: LanguageOverride,
) -> ServerConfig {
  ServerConfig(
    id: primary.id,
    command: case override.command {
      Some(s) -> s
      None -> primary.command
    },
    args: case override.args {
      Some(xs) -> xs
      None -> primary.args
    },
    initialization_options: parse_init_options_or(
      override.initialization_options_json,
      primary.initialization_options,
      primary.id,
    ),
    workspace_configuration: parse_workspace_config_or(
      override.workspace_configuration_json,
      primary.workspace_configuration,
      primary.id,
    ),
    methods: primary.methods,
    diagnostics_mode: case override.diagnostics_mode {
      None -> primary.diagnostics_mode
      Some(_) -> parse_mode(override.diagnostics_mode)
    },
    readiness_token: case override.readiness_token {
      None -> primary.readiness_token
      Some(_) -> override.readiness_token
    },
    ready_timeout_ms: case override.ready_timeout_ms {
      None -> primary.ready_timeout_ms
      Some(_) -> override.ready_timeout_ms
    },
    initialize_timeout_ms: case override.initialize_timeout_ms {
      None -> primary.initialize_timeout_ms
      Some(_) -> override.initialize_timeout_ms
    },
    warmup_probe: primary.warmup_probe,
  )
}

fn parse_mode(raw: Option(String)) -> DiagnosticsMode {
  case raw {
    Some("pull") | Some("Pull") | Some("PULL") -> Pull
    Some("push") | Some("Push") | Some("PUSH") -> Push
    _ -> Push
  }
}

// -- JSON-string overrides -----------------------------------------------

/// Whole-blob replace for `initialization_options`. Validates that the
/// user-supplied string parses as JSON (any shape — object, array,
/// scalar) and, on success, returns it as a `Json` passthrough value.
/// Parse failure logs a warning and falls back to the bundled default
/// so a typo in pharos.toml does not crash boot.
fn parse_init_options_or(
  raw: Option(String),
  fallback: Json,
  server_id: String,
) -> Json {
  case raw {
    None -> fallback
    Some(text) ->
      case json.parse(text, decode.dynamic) {
        Ok(_) -> json_passthrough(text)
        Error(err) -> {
          log.fields_at(
            "pharos/lsp/registry",
            log_entry.Warn,
            "initialization_options_json did not parse; using bundled default",
            [
              #("server", server_id),
              #("reason", describe_json_decode_error(err)),
            ],
          )
          fallback
        }
      }
  }
}

/// Whole-blob replace for `workspace_configuration`. Input must be a
/// JSON OBJECT whose top-level keys are the section names the LSP
/// pulls (`typescript`, `javascript`, etc.); each value is its own
/// JSON fragment. Erlang FFI splits the object into key→raw-bytes
/// pairs so each value passes through gleam_json verbatim. Anything
/// other than a top-level object falls back with a warning.
fn parse_workspace_config_or(
  raw: Option(String),
  fallback: Option(Dict(String, Json)),
  server_id: String,
) -> Option(Dict(String, Json)) {
  case raw {
    None -> fallback
    Some(text) ->
      case workspace_config_pairs(text) {
        Ok(pairs) ->
          Some(
            list.map(pairs, fn(pair) {
              let #(key, value_text) = pair
              #(key, json_passthrough(value_text))
            })
            |> dict.from_list,
          )
        Error(reason) -> {
          log.fields_at(
            "pharos/lsp/registry",
            log_entry.Warn,
            "workspace_configuration_json invalid; using bundled default",
            [#("server", server_id), #("reason", reason)],
          )
          fallback
        }
      }
  }
}

fn describe_json_decode_error(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(b) -> "unexpected byte " <> b
    json.UnexpectedSequence(s) -> "unexpected sequence " <> s
    json.UnableToDecode(_) -> "shape did not match decoder"
  }
}

@external(erlang, "pharos_json_passthrough_ffi", "raw")
fn json_passthrough(text: String) -> Json

@external(erlang, "pharos_json_passthrough_ffi", "parse_object_to_raw_pairs")
fn workspace_config_pairs_ffi(text: String) -> Result(
  List(#(String, String)),
  WorkspaceConfigError,
)

type WorkspaceConfigError {
  NotAnObject
  ParseFailed
}

fn workspace_config_pairs(
  text: String,
) -> Result(List(#(String, String)), String) {
  case workspace_config_pairs_ffi(text) {
    Ok(pairs) -> Ok(pairs)
    Error(NotAnObject) ->
      Error("top-level value must be a JSON object (section names → settings)")
    Error(ParseFailed) -> Error("text did not parse as JSON")
  }
}
