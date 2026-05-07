//// Effective language registry — bundled defaults overlaid with
//// user-supplied overrides from `pharos/config.languages`.
////
//// pharos ships with hardcoded LSP commands matching the developer's
//// dev box (rust-analyzer, gopls, etc.). End users on different
//// machines have those binaries somewhere else, and may want to add
//// languages pharos does not bundle (Haskell, Zig, etc.). This
//// module reads the cached `Config`, merges
//// `Config.languages` over the bundled defaults, and stashes the
//// resulting registry in `persistent_term` so per-request lookups
//// run at O(1) without re-parsing.
////
//// Override precedence: TOML files (global + project) → env vars,
//// resolved by `pharos/config.load/0`. By the time `init/0` runs,
//// `Config.languages` already reflects the merged user input.
////
//// Adding or overriding a language: see
//// `~/.config/pharos/pharos.toml`. New languages must specify
//// `command` and `file_extensions` at minimum; existing languages
//// only need the fields the user actually wants to change.

import gleam/dict.{type Dict}
import gleam/json
import gleam/option.{type Option, None, Some}
import pharos/config.{type LanguageOverride}
import pharos/log
import pharos/lsp/languages.{
  type DiagnosticsMode, type LanguageConfig, type LookupError, LanguageConfig,
  NoPromotion, Pull, Push,
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
          <> count_str(dict.size(cfg.languages))
          <> " language override(s) from pharos config",
      )
      merge_overrides(languages.default_registry(), cfg.languages)
    }
  }
  store(registry)
  Nil
}

fn count_str(n: Int) -> String {
  case n {
    1 -> "1"
    n -> int_str(n)
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_str(n: Int) -> String

/// Read the registry stored by `init/0`. Falls back to bundled
/// defaults if `init` was not yet called (test harnesses that bypass
/// the normal boot path, etc.).
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
/// registry. Used by tools that accept an explicit language argument
/// instead of inferring it from a file extension — primarily
/// `workspace_symbols`, where the natural URI is a directory and
/// extension routing fails. Returns `UnknownLanguage` with the id
/// echoed back so the caller can render a clear error.
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

/// Promote a bare `LanguageOverride` to a `LanguageConfig`. Fields
/// not supplied get blank defaults — this only fires for languages
/// NOT present in `default_registry`; the merge step below handles
/// the override case where defaults exist.
fn partial_to_full(key: String, override: LanguageOverride) -> LanguageConfig {
  LanguageConfig(
    id: option.unwrap(override.id, key),
    command: option.unwrap(override.command, ""),
    args: option.unwrap(override.args, []),
    file_extensions: option.unwrap(override.file_extensions, []),
    root_markers: option.unwrap(override.root_markers, []),
    initialization_options: json.object([]),
    diagnostics_mode: parse_mode(override.diagnostics_mode),
    workspace_configuration: None,
    readiness_token: override.readiness_token,
    root_promotion: NoPromotion,
  )
}

/// Field-by-field merge: override wins when its value is `Some(...)`
/// or its list is non-empty. Initialization options +
/// workspace_configuration are not yet overrideable here; future
/// work.
fn merge_one(default: LanguageConfig, override: LanguageOverride) -> LanguageConfig {
  LanguageConfig(
    id: case override.id {
      Some(s) -> s
      None -> default.id
    },
    command: case override.command {
      Some(s) -> s
      None -> default.command
    },
    args: case override.args {
      Some(xs) -> xs
      None -> default.args
    },
    file_extensions: case override.file_extensions {
      Some(xs) -> xs
      None -> default.file_extensions
    },
    root_markers: case override.root_markers {
      Some(xs) -> xs
      None -> default.root_markers
    },
    initialization_options: default.initialization_options,
    diagnostics_mode: case override.diagnostics_mode {
      None -> default.diagnostics_mode
      Some(_) -> parse_mode(override.diagnostics_mode)
    },
    workspace_configuration: default.workspace_configuration,
    readiness_token: case override.readiness_token {
      None -> default.readiness_token
      Some(_) -> override.readiness_token
    },
    root_promotion: default.root_promotion,
  )
}

fn parse_mode(raw: Option(String)) -> DiagnosticsMode {
  case raw {
    Some("pull") | Some("Pull") | Some("PULL") -> Pull
    Some("push") | Some("Push") | Some("PUSH") -> Push
    _ -> Push
  }
}
