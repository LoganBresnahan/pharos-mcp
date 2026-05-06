//// Effective language registry — bundled defaults overlaid with
//// user-supplied overrides from `~/.config/pharos/languages.json`.
////
//// pharos ships with hardcoded LSP commands matching the developer's
//// dev box (rust-analyzer in `~/.cargo/bin/`, gopls under `~/.asdf/`,
//// etc.). End users on different machines have those binaries
//// somewhere else, and may want to add languages pharos does not
//// bundle (Haskell, Zig, etc.). This module loads an optional JSON
//// config at boot, merges it over the defaults, and stashes the
//// resulting registry in `persistent_term` so per-request lookups
//// run at O(1) without re-parsing.
////
//// Config file shape (all language-config fields optional except for
//// new languages, which must specify `command` and `file_extensions`
//// at minimum):
////
//// ```json
//// {
////   "languages": {
////     "rust": { "command": "/usr/local/bin/rust-analyzer" },
////     "haskell": {
////       "command": "haskell-language-server-wrapper",
////       "args": ["--lsp"],
////       "file_extensions": [".hs"],
////       "root_markers": ["cabal.project", "stack.yaml"],
////       "diagnostics_mode": "push"
////     }
////   }
//// }
//// ```
////
//// Path resolution:
////   1. `PHAROS_LANGUAGES_FILE` env var (explicit path); else
////   2. `$XDG_CONFIG_HOME/pharos/languages.json`; else
////   3. `~/.config/pharos/languages.json`.
////
//// Missing or malformed configs are non-fatal: a warn line lands in
//// the log and pharos continues with bundled defaults.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import pharos/env
import pharos/log
import pharos/lsp/languages.{
  type DiagnosticsMode, type LanguageConfig, type LookupError,
  LanguageConfig, NoPromotion, Pull, Push,
}

/// Load the effective registry into `persistent_term`. Call once at
/// boot. Subsequent lookups via `for_uri/1` do not re-parse.
pub fn init() -> Nil {
  let registry = case load_overrides() {
    Error(_) -> languages.default_registry()
    Ok(overrides) -> merge(languages.default_registry(), overrides)
  }
  store(registry)
  Nil
}

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

// -- Persistent-term backing ---------------------------------------------

@external(erlang, "pharos_runtime_ffi", "registry_store")
fn store(registry: Dict(String, LanguageConfig)) -> Nil

@external(erlang, "pharos_runtime_ffi", "registry_load")
fn load() -> Result(Dict(String, LanguageConfig), Nil)

// -- Override file IO -----------------------------------------------------

fn load_overrides() -> Result(Dict(String, LanguageConfig), String) {
  case resolve_config_path() {
    None -> Error("no override path resolved")
    Some(path) ->
      case read_file_text(path) {
        Error(_) -> Error("config file unreadable: " <> path)
        Ok(text) ->
          case parse_overrides(text) {
            Error(reason) -> {
              log.warn_at(
                "pharos/lsp/registry",
                "ignoring invalid language config at "
                <> path
                <> ": "
                <> reason,
              )
              Error(reason)
            }
            Ok(overrides) -> {
              log.info_at(
                "pharos/lsp/registry",
                "loaded language overrides from " <> path,
              )
              Ok(overrides)
            }
          }
      }
  }
}

fn resolve_config_path() -> Option(String) {
  case env.get("PHAROS_LANGUAGES_FILE") {
    Some(path) if path != "" -> Some(path)
    _ ->
      case env.get("XDG_CONFIG_HOME") {
        Some(xdg) if xdg != "" -> Some(xdg <> "/pharos/languages.json")
        _ ->
          case env.get("HOME") {
            Some(home) if home != "" ->
              Some(home <> "/.config/pharos/languages.json")
            _ -> None
          }
      }
  }
}

fn read_file_text(path: String) -> Result(String, Nil) {
  case raw_read_file(path) {
    Error(_) -> Error(Nil)
    Ok(bytes) -> bit_array.to_string(bytes)
  }
}

@external(erlang, "pharos_fs_ffi", "read_file")
fn raw_read_file(path: String) -> Result(BitArray, String)

// -- Parsing + merge -----------------------------------------------------

fn parse_overrides(text: String) -> Result(Dict(String, LanguageConfig), String) {
  case json.parse(text, decode.dynamic) {
    Error(_) -> Error("not valid JSON")
    Ok(value) ->
      case decode.run(value, top_level_decoder()) {
        Error(_) -> Error("languages object missing or malformed")
        Ok(entries) -> Ok(dict.from_list(entries))
      }
  }
}

fn top_level_decoder() -> decode.Decoder(List(#(String, LanguageConfig))) {
  use languages_dict <- decode.field(
    "languages",
    decode.dict(decode.string, partial_language_decoder()),
  )
  decode.success(
    languages_dict
    |> dict.to_list
    |> list.map(fn(pair) {
      let #(key, partial) = pair
      #(key, partial_to_full(key, partial))
    }),
  )
}

/// User-supplied partial spec. Every field optional; missing fields
/// are filled from the matching default (when one exists) or from
/// sensible language-spec defaults.
type PartialConfig {
  PartialConfig(
    id: Option(String),
    command: Option(String),
    args: Option(List(String)),
    file_extensions: Option(List(String)),
    root_markers: Option(List(String)),
    diagnostics_mode: Option(DiagnosticsMode),
    readiness_token: Option(String),
  )
}

fn partial_language_decoder() -> decode.Decoder(PartialConfig) {
  use id <- decode.optional_field(
    "id",
    None,
    decode.string |> decode.map(Some),
  )
  use command <- decode.optional_field(
    "command",
    None,
    decode.string |> decode.map(Some),
  )
  use args <- decode.optional_field(
    "args",
    None,
    decode.list(decode.string) |> decode.map(Some),
  )
  use file_extensions <- decode.optional_field(
    "file_extensions",
    None,
    decode.list(decode.string) |> decode.map(Some),
  )
  use root_markers <- decode.optional_field(
    "root_markers",
    None,
    decode.list(decode.string) |> decode.map(Some),
  )
  use diagnostics_mode <- decode.optional_field(
    "diagnostics_mode",
    None,
    decode.string |> decode.map(parse_mode),
  )
  use readiness_token <- decode.optional_field(
    "readiness_token",
    None,
    decode.string |> decode.map(Some),
  )
  decode.success(PartialConfig(
    id: id,
    command: command,
    args: args,
    file_extensions: file_extensions,
    root_markers: root_markers,
    diagnostics_mode: diagnostics_mode,
    readiness_token: readiness_token,
  ))
}

fn parse_mode(raw: String) -> Option(DiagnosticsMode) {
  case raw {
    "push" | "Push" | "PUSH" -> Some(Push)
    "pull" | "Pull" | "PULL" -> Some(Pull)
    _ -> None
  }
}

/// Promote a `PartialConfig` to a `LanguageConfig`. Fields not
/// supplied get blank defaults — this only fires for languages NOT
/// present in `default_registry`; the merge step below handles the
/// override case where defaults exist.
fn partial_to_full(key: String, partial: PartialConfig) -> LanguageConfig {
  LanguageConfig(
    id: option.unwrap(partial.id, key),
    command: option.unwrap(partial.command, ""),
    args: option.unwrap(partial.args, []),
    file_extensions: option.unwrap(partial.file_extensions, []),
    root_markers: option.unwrap(partial.root_markers, []),
    initialization_options: json.object([]),
    diagnostics_mode: option.unwrap(partial.diagnostics_mode, Push),
    workspace_configuration: None,
    readiness_token: partial.readiness_token,
    root_promotion: NoPromotion,
  )
}

/// For each entry in `overrides`: if a default exists for the same
/// key, copy non-default fields onto the default; otherwise insert
/// the overlay verbatim.
fn merge(
  defaults: Dict(String, LanguageConfig),
  overrides: Dict(String, LanguageConfig),
) -> Dict(String, LanguageConfig) {
  dict.fold(overrides, defaults, fn(acc, key, override) {
    case dict.get(acc, key) {
      Error(_) -> dict.insert(acc, key, override)
      Ok(default) -> dict.insert(acc, key, merge_one(default, override))
    }
  })
}

/// Field-by-field merge: override wins when its field looks
/// "supplied" (non-empty list, non-empty string). Recreates the
/// behavior the partial decoder gave us before promoting to
/// `LanguageConfig`. Initialization options + workspace
/// configuration are not yet overrideable here; future work.
fn merge_one(default: LanguageConfig, override: LanguageConfig) -> LanguageConfig {
  LanguageConfig(
    id: case override.id {
      "" -> default.id
      s -> s
    },
    command: case override.command {
      "" -> default.command
      s -> s
    },
    args: case override.args {
      [] -> default.args
      a -> a
    },
    file_extensions: case override.file_extensions {
      [] -> default.file_extensions
      a -> a
    },
    root_markers: case override.root_markers {
      [] -> default.root_markers
      a -> a
    },
    initialization_options: default.initialization_options,
    diagnostics_mode: override.diagnostics_mode,
    workspace_configuration: default.workspace_configuration,
    readiness_token: case override.readiness_token {
      None -> default.readiness_token
      Some(_) -> override.readiness_token
    },
    root_promotion: default.root_promotion,
  )
}
