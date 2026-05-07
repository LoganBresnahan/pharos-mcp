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
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import pharos/config.{type LanguageOverride, type ServerOverride}
import pharos/log
import pharos/lsp/languages.{
  type DiagnosticsMode, type LanguageConfig, type LookupError, type MethodScope,
  type ServerConfig, All, LanguageConfig, NoPromotion, Only, Pull, Push,
  ServerConfig,
}

/// Load the effective registry into `persistent_term`. Call once at
/// boot. Subsequent lookups via `for_uri/1` do not re-parse.
pub fn init() -> Nil {
  let cfg = config.cached()
  let registry = case dict.size(cfg.languages) {
    0 -> languages.default_registry()
    _ -> {
      log.info_at(
        "pharos/lsp/registry",
        "applied "
          <> int_str(dict.size(cfg.languages))
          <> " language override(s) from pharos config",
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

/// Promote a bare `LanguageOverride` to a `LanguageConfig` with one
/// server. Fires only for brand-new languages NOT in
/// `default_registry`. `command` and `file_extensions` are required
/// for new languages; everything else gets sensible blanks.
fn partial_to_full(key: String, override: LanguageOverride) -> LanguageConfig {
  let server =
    ServerConfig(
      id: key,
      command: option.unwrap(override.command, ""),
      args: option.unwrap(override.args, []),
      initialization_options: json.object([]),
      workspace_configuration: None,
      methods: All,
      diagnostics_mode: parse_mode(override.diagnostics_mode),
      readiness_token: override.readiness_token,
    )
  LanguageConfig(
    id: option.unwrap(override.id, key),
    file_extensions: option.unwrap(override.file_extensions, []),
    root_markers: option.unwrap(override.root_markers, []),
    root_promotion: NoPromotion,
    servers: [server],
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
    initialization_options: default.initialization_options,
    workspace_configuration: default.workspace_configuration,
    methods: parse_methods(ovr.methods, default.methods),
    diagnostics_mode: case ovr.diagnostics_mode {
      None -> default.diagnostics_mode
      Some(_) -> parse_mode(ovr.diagnostics_mode)
    },
    readiness_token: case ovr.readiness_token {
      None -> default.readiness_token
      Some(_) -> ovr.readiness_token
    },
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
    initialization_options: primary.initialization_options,
    workspace_configuration: primary.workspace_configuration,
    methods: primary.methods,
    diagnostics_mode: case override.diagnostics_mode {
      None -> primary.diagnostics_mode
      Some(_) -> parse_mode(override.diagnostics_mode)
    },
    readiness_token: case override.readiness_token {
      None -> primary.readiness_token
      Some(_) -> override.readiness_token
    },
  )
}

fn parse_mode(raw: Option(String)) -> DiagnosticsMode {
  case raw {
    Some("pull") | Some("Pull") | Some("PULL") -> Pull
    Some("push") | Some("Push") | Some("PUSH") -> Push
    _ -> Push
  }
}
