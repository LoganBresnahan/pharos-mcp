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
//// Stage 1 of ADR-019: per-language overrides apply to the language's
//// FIRST (primary) server. Stage 3 will introduce explicit
//// per-server addressing via `[[languages.<id>.servers]]` array of
//// tables; today's flat shape stays valid as the canonical form for
//// languages with one server.

import gleam/dict.{type Dict}
import gleam/json
import gleam/option.{type Option, None, Some}
import pharos/config.{type LanguageOverride}
import pharos/log
import pharos/lsp/languages.{
  type DiagnosticsMode, type LanguageConfig, type LookupError, type ServerConfig,
  All, LanguageConfig, NoPromotion, Pull, Push, ServerConfig,
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

/// Apply a flat override to an existing `LanguageConfig`. Server-level
/// fields (command, args, diagnostics_mode, readiness_token) target
/// the FIRST server in the language's `servers` list — the primary.
/// Language-level fields (file_extensions, root_markers) replace
/// those on the parent record.
fn merge_one(default: LanguageConfig, override: LanguageOverride) -> LanguageConfig {
  let merged_servers = case default.servers {
    [] -> default.servers
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
