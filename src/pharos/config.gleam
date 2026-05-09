//// Configuration umbrella.
////
//// Single source of truth for every knob pharos exposes. Reads —
//// in precedence order:
////
////   1. defaults (compiled into this module)
////   2. global TOML at `~/.config/pharos/pharos.toml`
////   3. project TOML at `./.pharos.toml` (walked up from cwd)
////   4. environment variables (`PHAROS_*`)
////   5. CLI flags (only `--version` / `--help` /
////      `--print-default-config` — every runtime knob is env or TOML)
////
//// Higher-numbered sources override lower-numbered ones. The
//// resolved `Config` is parked in `persistent_term` once at boot;
//// every downstream consumer reads via `cached/0` (O(1), lock-free)
//// instead of touching env vars or files directly.
////
//// Adding a new knob:
////   1. Extend `Config` (or a sub-record).
////   2. Set its default in `defaults/0`.
////   3. Add a TOML key in `apply_toml/2`.
////   4. Add an env override in `apply_env/1`.
////   5. Document in `doc/example-pharos.toml` and the README.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pharos/env
import pharos/log
import pharos/log/entry as log_entry

// -- Types ----------------------------------------------------------------

pub type Transport {
  Stdio
  Http
  Both
}

/// Tool exposure filter. Each `entry` is either a category alias —
/// `"read"`, `"write"`, `"debug"`, `"raw"` — or a literal MCP tool
/// name (e.g. `"hover"`). Resolved by `tool_allowed/3`.
pub type ToolFilter {
  ToolFilter(entries: List(String))
}

pub type HttpConfig {
  HttpConfig(port: Int, bind: String, port_file: Option(String))
}

pub type LogConfig {
  LogConfig(
    filter_spec: String,
    file: Option(String),
    ring_enabled: Bool,
    stderr_enabled: Bool,
    /// Cap on the active file-sink size before rotation triggers.
    /// `None` disables rotation (file appends forever, prior
    /// behaviour). `Some(N)` rotates `pharos.log` -> `pharos.log.1`
    /// when bytes-written exceeds N. Default: 10 MB when file sink
    /// is enabled.
    file_max_bytes: Option(Int),
    /// Number of rotated files to keep alongside the active file
    /// (`pharos.log.1` ... `pharos.log.N`). Older rotations drop.
    /// Default: 3.
    file_keep_rotated: Int,
  )
}

pub type LspConfig {
  LspConfig(trace: Bool)
}

pub type RuntimeConfig {
  RuntimeConfig(trace_calls_enabled: Bool)
}

pub type BridgeConfig {
  BridgeConfig(port: Option(Int))
}

/// User-supplied per-server overlay (M10 / ADR-019 stage 3 follow-up).
/// Each entry in `LanguageOverride.servers` matches by `id` against
/// the bundled defaults — present-id overrides patch existing fields,
/// absent-id entries append a new ServerConfig to the language's
/// servers list. `methods = ["..."]` declares an `Only` scope;
/// omitted means `All`.
pub type ServerOverride {
  ServerOverride(
    id: Option(String),
    command: Option(String),
    args: Option(List(String)),
    methods: Option(List(String)),
    diagnostics_mode: Option(String),
    readiness_token: Option(String),
    /// Override the post-handshake / post-didOpen drain budget. None
    /// = use the bundled default (`languages.default_readiness_timeout_ms`,
    /// 30s). Languages with slow indexing (rust-analyzer big workspace,
    /// jdtls big project) tune up; nothing tunes down typically.
    readiness_timeout_ms: Option(Int),
    /// Override the `initialize` handshake budget. None = use the
    /// bundled default (`languages.default_initialize_timeout_ms`,
    /// 90s — accommodates jdtls cold start).
    initialize_timeout_ms: Option(Int),
    /// Whole-blob replace of the server's `initialization_options`
    /// JSON sent at `initialize`. Stored as a TOML string containing
    /// JSON text (LSP-server upstream docs publish init options in
    /// JSON, so users can paste from those docs verbatim). Parse
    /// failures log a warning and fall back to bundled defaults so
    /// boot doesn't crash on a typo. See
    /// `pharos --print-language-config <lang>` for the bundled
    /// blob to start from.
    initialization_options_json: Option(String),
    /// Whole-blob replace of the server's `workspace_configuration`
    /// payload — the response pharos sends when the LSP pulls
    /// `workspace/configuration` (used heavily by
    /// typescript-language-server's `[typescript]` and `[javascript]`
    /// settings). Same TOML-string-of-JSON shape as
    /// `initialization_options_json`. Parse failure → warn + fall back.
    workspace_configuration_json: Option(String),
  )
}

/// User-supplied per-language overlay. Only fields the user wants
/// to change need a value; merge logic in `pharos/lsp/registry`
/// fills the rest from the bundled defaults (or from
/// language-spec-blank values when introducing a brand-new language).
///
/// Two override shapes coexist:
///   - **Flat (legacy + simple).** `command`, `args`, etc. at the
///     language level — applied to the language's primary
///     (first-listed) server. Convenient for the common case of
///     swapping a single binary path.
///   - **Per-server (`servers = [...]`).** TOML array of tables
///     `[[languages.<id>.servers]]`. Each entry merges into the
///     matching default by id, or appends as a new server if id is
///     absent. Use when adding a third server or tweaking
///     non-primary fields (e.g. ruff's command in python).
///
/// When both are present in one override, the per-server array is
/// applied first; the flat fields then patch the resulting primary
/// server's matching fields.
pub type LanguageOverride {
  LanguageOverride(
    id: Option(String),
    command: Option(String),
    args: Option(List(String)),
    file_extensions: Option(List(String)),
    root_markers: Option(List(String)),
    diagnostics_mode: Option(String),
    readiness_token: Option(String),
    servers: Option(List(ServerOverride)),
    /// Flat-shape variants of the per-server JSON overrides. Patches
    /// the language's PRIMARY (first-listed) server. For multi-server
    /// languages prefer the per-server form via
    /// `[[languages.<id>.servers]]` to be explicit about which
    /// server's blob is being replaced.
    initialization_options_json: Option(String),
    workspace_configuration_json: Option(String),
    /// Flat-shape variants of the per-server timeout overrides;
    /// patches the language's PRIMARY server. See ServerOverride.
    readiness_timeout_ms: Option(Int),
    initialize_timeout_ms: Option(Int),
  )
}

/// Per-tool config knobs — `[tool_config.<name>]` blocks in
/// pharos.toml. Carries `default_timeout_ms` plus an optional
/// `languages` sub-map for per-tool × per-language overrides
/// (`[tool_config.<name>.<lang>]`). The recursion lets a future
/// per-lang block carry its own `default_timeout_ms` independent
/// of the global per-tool default. Resolution: per-lang wins over
/// per-tool global.
pub type ToolConfig {
  ToolConfig(
    default_timeout_ms: Option(Int),
    languages: Dict(String, ToolConfig),
  )
}

pub type Config {
  Config(
    transport: Transport,
    tools: ToolFilter,
    http: HttpConfig,
    log: LogConfig,
    lsp: LspConfig,
    runtime: RuntimeConfig,
    bridge: BridgeConfig,
    languages: Dict(String, LanguageOverride),
    /// `[tool_config.<name>] default_timeout_ms = N` block plus
    /// per-tool × per-language overrides via
    /// `[tool_config.<name>.<lang>] default_timeout_ms = N`. Looks
    /// up by MCP tool name (e.g. `"hover"`, `"format_document"`);
    /// the optional language id walks the same registry as
    /// `[languages.<id>]`. Empty by default.
    tool_config: Dict(String, ToolConfig),
  )
}

/// Effective default timeout for a tool name, optionally narrowed
/// to a language id. Resolution order: per-tool × per-language
/// override → per-tool global → `None` (caller falls back to the
/// compiled-in const). Language id matches the language registry
/// key (e.g. `"rust"`, `"python"`, `"java"`).
pub fn tool_default_timeout_ms(
  name: String,
  lang: Option(String),
) -> Option(Int) {
  let cfg = cached()
  case dict.get(cfg.tool_config, name) {
    Error(_) -> None
    Ok(tc) -> {
      let per_lang = case lang {
        None -> None
        Some(l) ->
          case dict.get(tc.languages, l) {
            Error(_) -> None
            Ok(lang_tc) -> lang_tc.default_timeout_ms
          }
      }
      case per_lang {
        Some(_) -> per_lang
        None -> tc.default_timeout_ms
      }
    }
  }
}

// -- Defaults -------------------------------------------------------------

const default_http_port: Int = 3535

const default_http_bind: String = "127.0.0.1"

/// Compiled-in defaults. Loaded first; everything else overlays.
pub fn defaults() -> Config {
  Config(
    transport: Stdio,
    tools: ToolFilter(entries: ["read", "write", "debug", "raw"]),
    http: HttpConfig(
      port: default_http_port,
      bind: default_http_bind,
      port_file: None,
    ),
    log: LogConfig(
      filter_spec: "",
      file: None,
      ring_enabled: True,
      stderr_enabled: True,
      file_max_bytes: None,
      file_keep_rotated: 3,
    ),
    lsp: LspConfig(trace: False),
    runtime: RuntimeConfig(trace_calls_enabled: False),
    bridge: BridgeConfig(port: None),
    languages: dict.new(),
    tool_config: dict.new(),
  )
}

// -- Public load + cache --------------------------------------------------

/// Build the effective Config from defaults + TOML files + env vars
/// and park it in `persistent_term`. Call once at boot. Idempotent —
/// re-calling replaces the stored value.
pub fn load() -> Config {
  let config =
    defaults()
    |> overlay_global_toml
    |> overlay_project_toml
    |> apply_env

  store_persistent(config)
  config
}

/// Return the cached Config, falling back to compiled defaults if
/// `load/0` has not yet run (test harnesses bypassing boot, etc.).
pub fn cached() -> Config {
  case load_persistent() {
    Ok(config) -> config
    Error(_) -> defaults()
  }
}

@external(erlang, "pharos_runtime_ffi", "config_store")
fn store_persistent(config: Config) -> Nil

@external(erlang, "pharos_runtime_ffi", "config_load")
fn load_persistent() -> Result(Config, Nil)

// -- Tool filter ----------------------------------------------------------

pub type ToolCategory {
  CatRead
  CatWrite
  CatDebug
  CatRaw
}

/// True iff `name` (with its known category) is exposed under the
/// supplied filter. Resolution: a name is exposed iff its category
/// alias is in `entries`, OR the literal name is in `entries`.
pub fn tool_allowed(
  filter: ToolFilter,
  name: String,
  category: ToolCategory,
) -> Bool {
  let alias = category_alias(category)
  list.any(filter.entries, fn(e) { e == alias || e == name })
}

fn category_alias(category: ToolCategory) -> String {
  case category {
    CatRead -> "read"
    CatWrite -> "write"
    CatDebug -> "debug"
    CatRaw -> "raw"
  }
}

// -- Global TOML overlay --------------------------------------------------

fn overlay_global_toml(config: Config) -> Config {
  case env.get("PHAROS_CONFIG_FILE") {
    Some(path) if path != "" ->
      overlay_path(config, path, "PHAROS_CONFIG_FILE")
    _ ->
      case xdg_config_path() {
        None -> config
        Some(path) ->
          case path_exists(path) {
            False -> config
            True -> overlay_path(config, path, "global config")
          }
      }
  }
}

fn xdg_config_path() -> Option(String) {
  case env.get("XDG_CONFIG_HOME") {
    Some(xdg) if xdg != "" -> Some(xdg <> "/pharos/pharos.toml")
    _ ->
      case env.get("HOME") {
        Some(home) if home != "" -> Some(home <> "/.config/pharos/pharos.toml")
        _ -> None
      }
  }
}

// -- Project TOML overlay -------------------------------------------------

fn overlay_project_toml(config: Config) -> Config {
  case find_project_toml(cwd()) {
    None -> config
    Some(path) -> overlay_path(config, path, "project config")
  }
}

/// Walk up from `start_dir` looking for `.pharos.toml`. Returns the
/// first match. Stops at filesystem root (`dirname(d) == d`).
fn find_project_toml(start_dir: String) -> Option(String) {
  case start_dir {
    "" -> None
    dir -> walk_up(dir, dir)
  }
}

fn walk_up(current: String, previous: String) -> Option(String) {
  let candidate = current <> "/.pharos.toml"
  case path_exists(candidate) {
    True -> Some(candidate)
    False -> {
      let parent = dirname(current)
      case parent == current || parent == previous {
        True -> None
        False -> walk_up(parent, current)
      }
    }
  }
}

@external(erlang, "pharos_fs_ffi", "cwd")
fn cwd() -> String

@external(erlang, "pharos_fs_ffi", "is_regular_file")
fn path_exists(path: String) -> Bool

@external(erlang, "pharos_fs_ffi", "dirname")
fn dirname(path: String) -> String

// -- Path → Config overlay ------------------------------------------------

fn overlay_path(config: Config, path: String, label: String) -> Config {
  case read_toml(path) {
    Error(reason) -> {
      log.fields_at(
        "pharos/config",
        log_entry.Warn,
        "ignoring " <> label,
        [#("path", path), #("reason", reason)],
      )
      config
    }
    Ok(parsed) -> {
      log.fields_at(
        "pharos/config",
        log_entry.Info,
        "loaded " <> label,
        [#("path", path)],
      )
      apply_toml(config, parsed)
    }
  }
}

fn read_toml(path: String) -> Result(Dynamic, String) {
  use bytes <- result.try(read_bytes(path))
  toml_parse(bytes)
}

@external(erlang, "pharos_fs_ffi", "read_file")
fn read_bytes(path: String) -> Result(BitArray, String)

@external(erlang, "pharos_toml_ffi", "parse")
fn toml_parse(bytes: BitArray) -> Result(Dynamic, String)

// -- TOML decode + apply --------------------------------------------------

/// Apply a parsed TOML document on top of `config`. Missing keys
/// leave `config`'s prior value alone — TOML-as-overlay semantics.
fn apply_toml(config: Config, parsed: Dynamic) -> Config {
  config
  |> apply_top_transport(parsed)
  |> apply_top_tools(parsed)
  |> apply_section_server(parsed)
  |> apply_section_log(parsed)
  |> apply_section_lsp(parsed)
  |> apply_section_runtime(parsed)
  |> apply_section_bridge(parsed)
  |> apply_section_languages(parsed)
  |> apply_section_tool_config(parsed)
}

/// `[tool_config.<name>] default_timeout_ms = N` — per-tool override
/// for the compiled-in `default_timeout_ms` const inside each tool.
/// User opts in to tune defaults without passing `timeout_ms` on
/// every call.
///
/// TOML shape:
///
///     [tool_config.format_document]
///     default_timeout_ms = 90000
///
///     [tool_config.find_references]
///     default_timeout_ms = 120000
///
/// Top-level `tools = [...]` (the surface filter) coexists with this
/// section since one is a value and the other is a table-of-tables —
/// distinct TOML keys, no collision.
fn apply_section_tool_config(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "tool_config", decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> config
    Ok(raw) -> {
      let parsed_overrides =
        raw
        |> dict.to_list
        |> list.map(fn(pair) {
          let #(name, value) = pair
          #(name, decode_tool_config(value))
        })
        |> dict.from_list
      let merged =
        dict.fold(parsed_overrides, config.tool_config, fn(acc, key, val) {
          dict.insert(acc, key, val)
        })
      Config(..config, tool_config: merged)
    }
  }
}

/// Parse a `[tool_config.<name>]` block. Reads
/// `default_timeout_ms` if present; treats every other sub-table
/// as a per-language override (`[tool_config.<name>.<lang>]`)
/// recursively decoded into `languages`. Per-lang sub-blocks may
/// themselves carry `default_timeout_ms`; further nesting is
/// permitted by the type but not exercised today.
fn decode_tool_config(value: Dynamic) -> ToolConfig {
  let default_timeout_ms = decode_optional_int(value, "default_timeout_ms")
  let languages = case
    decode.run(value, decode.dict(decode.string, decode.dynamic))
  {
    Error(_) -> dict.new()
    Ok(raw) ->
      raw
      |> dict.to_list
      |> list.filter_map(fn(pair) {
        let #(key, sub_value) = pair
        case key {
          // `default_timeout_ms` is a scalar already consumed above.
          "default_timeout_ms" -> Error(Nil)
          _ -> {
            // Anything else is treated as a per-lang sub-table —
            // skip values that aren't dict-shaped (stray scalars
            // shouldn't error the boot, just get ignored).
            case
              decode.run(
                sub_value,
                decode.dict(decode.string, decode.dynamic),
              )
            {
              Error(_) -> Error(Nil)
              Ok(_) -> Ok(#(key, decode_tool_config(sub_value)))
            }
          }
        }
      })
      |> dict.from_list
  }
  ToolConfig(default_timeout_ms: default_timeout_ms, languages: languages)
}

fn apply_top_transport(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "transport", decode.string) {
    Ok(raw) ->
      case parse_transport(raw) {
        Some(t) -> Config(..config, transport: t)
        None -> config
      }
    Error(_) -> config
  }
}

fn apply_top_tools(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "tools", decode.list(decode.string)) {
    Ok(entries) -> Config(..config, tools: ToolFilter(entries: entries))
    Error(_) -> config
  }
}

fn apply_section_server(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "server", decode.dynamic) {
    Error(_) -> config
    Ok(server) -> {
      let with_transport = case
        decode_field(server, "transport", decode.string)
      {
        Ok(raw) ->
          case parse_transport(raw) {
            Some(t) -> Config(..config, transport: t)
            None -> config
          }
        Error(_) -> config
      }
      case decode_field(server, "http", decode.dynamic) {
        Error(_) -> with_transport
        Ok(http) -> {
          let port = case decode_field(http, "port", decode.int) {
            Ok(p) -> p
            Error(_) -> with_transport.http.port
          }
          let bind = case decode_field(http, "bind", decode.string) {
            Ok(b) ->
              case b {
                "" -> with_transport.http.bind
                non_empty -> non_empty
              }
            Error(_) -> with_transport.http.bind
          }
          let port_file = case
            decode_field(http, "port_file", decode.string)
          {
            Ok(p) ->
              case p {
                "" -> with_transport.http.port_file
                non_empty -> Some(non_empty)
              }
            Error(_) -> with_transport.http.port_file
          }
          Config(
            ..with_transport,
            http: HttpConfig(port: port, bind: bind, port_file: port_file),
          )
        }
      }
    }
  }
}

fn apply_section_log(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "log", decode.dynamic) {
    Error(_) -> config
    Ok(log_table) -> {
      let filter_spec = case
        decode_field(log_table, "filter", decode.string)
      {
        Ok(s) -> s
        Error(_) -> config.log.filter_spec
      }
      let file = case decode_field(log_table, "file", decode.string) {
        Ok(s) ->
          case s {
            "" -> config.log.file
            non_empty -> Some(non_empty)
          }
        Error(_) -> config.log.file
      }
      let ring_enabled = case decode_field(log_table, "ring", decode.bool) {
        Ok(b) -> b
        Error(_) -> config.log.ring_enabled
      }
      let stderr_enabled = case
        decode_field(log_table, "stderr", decode.bool)
      {
        Ok(b) -> b
        Error(_) -> config.log.stderr_enabled
      }
      let file_max_bytes = case
        decode_field(log_table, "file_max_bytes", decode.int)
      {
        Ok(n) if n > 0 -> Some(n)
        _ -> config.log.file_max_bytes
      }
      let file_keep_rotated = case
        decode_field(log_table, "file_keep_rotated", decode.int)
      {
        Ok(n) if n >= 0 -> n
        _ -> config.log.file_keep_rotated
      }
      Config(
        ..config,
        log: LogConfig(
          filter_spec: filter_spec,
          file: file,
          ring_enabled: ring_enabled,
          stderr_enabled: stderr_enabled,
          file_max_bytes: file_max_bytes,
          file_keep_rotated: file_keep_rotated,
        ),
      )
    }
  }
}

fn apply_section_lsp(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "lsp", decode.dynamic) {
    Error(_) -> config
    Ok(lsp_table) ->
      case decode_field(lsp_table, "trace", decode.bool) {
        Ok(b) -> Config(..config, lsp: LspConfig(trace: b))
        Error(_) -> config
      }
  }
}

fn apply_section_runtime(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "runtime", decode.dynamic) {
    Error(_) -> config
    Ok(rt) ->
      case decode_field(rt, "trace_calls_enabled", decode.bool) {
        Ok(b) ->
          Config(
            ..config,
            runtime: RuntimeConfig(trace_calls_enabled: b),
          )
        Error(_) -> config
      }
  }
}

fn apply_section_bridge(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "bridge", decode.dynamic) {
    Error(_) -> config
    Ok(br) ->
      case decode_field(br, "port", decode.int) {
        Ok(p) -> Config(..config, bridge: BridgeConfig(port: Some(p)))
        Error(_) -> config
      }
  }
}

fn apply_section_languages(config: Config, parsed: Dynamic) -> Config {
  case
    decode_field(
      parsed,
      "languages",
      decode.dict(decode.string, decode.dynamic),
    )
  {
    Error(_) -> config
    Ok(raw_map) -> {
      let parsed_overrides =
        raw_map
        |> dict.to_list
        |> list.map(fn(pair) {
          let #(name, value) = pair
          #(name, decode_language_override(value))
        })
        |> dict.from_list
      // Layer: anything in parsed_overrides wins over the prior
      // languages dict. Global+project compose because each call
      // folds the new overlay on top of what is already there.
      let merged =
        dict.fold(parsed_overrides, config.languages, fn(acc, key, override) {
          dict.insert(acc, key, override)
        })
      Config(..config, languages: merged)
    }
  }
}

fn decode_language_override(value: Dynamic) -> LanguageOverride {
  LanguageOverride(
    id: decode_optional_string(value, "id"),
    command: decode_optional_string(value, "command"),
    args: decode_optional_string_list(value, "args"),
    file_extensions: decode_optional_string_list(value, "file_extensions"),
    root_markers: decode_optional_string_list(value, "root_markers"),
    diagnostics_mode: decode_optional_string(value, "diagnostics_mode"),
    readiness_token: decode_optional_string(value, "readiness_token"),
    servers: decode_optional_servers_list(value),
    initialization_options_json: decode_optional_string(
      value,
      "initialization_options_json",
    ),
    workspace_configuration_json: decode_optional_string(
      value,
      "workspace_configuration_json",
    ),
    readiness_timeout_ms: decode_optional_int(value, "readiness_timeout_ms"),
    initialize_timeout_ms: decode_optional_int(value, "initialize_timeout_ms"),
  )
}

/// Decode `[[languages.<id>.servers]]` array of tables. Tomerl
/// renders TOML arrays of inline tables as a List(Dynamic) where
/// each element is a map; pull the per-server fields out of each.
/// Returns `None` when the key is absent or the value isn't an
/// array of tables — falls back to legacy flat-override semantics.
fn decode_optional_servers_list(parent: Dynamic) -> Option(List(ServerOverride)) {
  case decode_field(parent, "servers", decode.list(decode.dynamic)) {
    Error(_) -> None
    Ok(entries) ->
      Some(list.map(entries, decode_server_override))
  }
}

fn decode_server_override(value: Dynamic) -> ServerOverride {
  ServerOverride(
    id: decode_optional_string(value, "id"),
    command: decode_optional_string(value, "command"),
    args: decode_optional_string_list(value, "args"),
    methods: decode_optional_string_list(value, "methods"),
    diagnostics_mode: decode_optional_string(value, "diagnostics_mode"),
    readiness_token: decode_optional_string(value, "readiness_token"),
    readiness_timeout_ms: decode_optional_int(value, "readiness_timeout_ms"),
    initialize_timeout_ms: decode_optional_int(value, "initialize_timeout_ms"),
    initialization_options_json: decode_optional_string(
      value,
      "initialization_options_json",
    ),
    workspace_configuration_json: decode_optional_string(
      value,
      "workspace_configuration_json",
    ),
  )
}

fn decode_optional_string(parent: Dynamic, key: String) -> Option(String) {
  case decode_field(parent, key, decode.string) {
    Ok(s) -> Some(s)
    Error(_) -> None
  }
}

fn decode_optional_int(parent: Dynamic, key: String) -> Option(Int) {
  case decode_field(parent, key, decode.int) {
    Ok(n) -> Some(n)
    Error(_) -> None
  }
}

fn decode_optional_string_list(
  parent: Dynamic,
  key: String,
) -> Option(List(String)) {
  case decode_field(parent, key, decode.list(decode.string)) {
    Ok(xs) -> Some(xs)
    Error(_) -> None
  }
}

fn decode_field(
  parent: Dynamic,
  key: String,
  inner: decode.Decoder(a),
) -> Result(a, Nil) {
  let decoder = {
    use value <- decode.field(key, inner)
    decode.success(value)
  }
  decode.run(parent, decoder)
  |> result.replace_error(Nil)
}

fn parse_transport(raw: String) -> Option(Transport) {
  case string.lowercase(string.trim(raw)) {
    "stdio" -> Some(Stdio)
    "http" -> Some(Http)
    "both" -> Some(Both)
    _ -> None
  }
}

// -- Env-var overlay ------------------------------------------------------

fn apply_env(config: Config) -> Config {
  config
  |> env_transport
  |> env_tools
  |> env_http
  |> env_log
  |> env_lsp
  |> env_runtime
  |> env_bridge
}

fn env_transport(config: Config) -> Config {
  case env.get("PHAROS_TRANSPORT") {
    None -> config
    Some(raw) ->
      case parse_transport(raw) {
        Some(t) -> Config(..config, transport: t)
        None -> {
          log.fields_at(
            "pharos/config",
            log_entry.Warn,
            "unrecognized PHAROS_TRANSPORT; keeping prior value",
            [#("value", raw)],
          )
          config
        }
      }
  }
}

fn env_tools(config: Config) -> Config {
  case env.get("PHAROS_TOOLS") {
    None -> config
    Some(raw) ->
      case string.trim(raw) {
        "" -> config
        s -> Config(..config, tools: ToolFilter(entries: split_csv(s)))
      }
  }
}

fn env_http(config: Config) -> Config {
  let port = case env.get("PHAROS_HTTP_PORT") {
    None -> config.http.port
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(p) -> p
        Error(_) -> {
          log.fields_at(
            "pharos/config",
            log_entry.Warn,
            "PHAROS_HTTP_PORT not a valid integer; keeping prior value",
            [
              #("value", raw),
              #("kept", int.to_string(config.http.port)),
            ],
          )
          config.http.port
        }
      }
  }
  let bind = case env.get("PHAROS_HTTP_BIND") {
    None -> config.http.bind
    Some(raw) ->
      case string.trim(raw) {
        "" -> config.http.bind
        b -> b
      }
  }
  let port_file = case env.get("PHAROS_HTTP_PORT_FILE") {
    None -> config.http.port_file
    Some(raw) ->
      case raw {
        "" -> None
        path -> Some(path)
      }
  }
  Config(
    ..config,
    http: HttpConfig(port: port, bind: bind, port_file: port_file),
  )
}

fn env_log(config: Config) -> Config {
  let filter_spec = case env.get("PHAROS_LOG") {
    None -> config.log.filter_spec
    Some(raw) -> raw
  }
  let file = case env.get("PHAROS_LOG_FILE") {
    None -> config.log.file
    Some(raw) ->
      case raw {
        "" -> None
        path -> Some(path)
      }
  }
  let ring_enabled = read_bool_env(
    "PHAROS_LOG_RING",
    config.log.ring_enabled,
  )
  let stderr_enabled = read_bool_env(
    "PHAROS_LOG_STDERR",
    config.log.stderr_enabled,
  )
  Config(
    ..config,
    log: LogConfig(
      filter_spec: filter_spec,
      file: file,
      ring_enabled: ring_enabled,
      stderr_enabled: stderr_enabled,
      file_max_bytes: config.log.file_max_bytes,
      file_keep_rotated: config.log.file_keep_rotated,
    ),
  )
}

fn env_lsp(config: Config) -> Config {
  let trace = read_bool_env("PHAROS_TRACE_LSP", config.lsp.trace)
  Config(..config, lsp: LspConfig(trace: trace))
}

fn env_runtime(config: Config) -> Config {
  let enabled = read_bool_env(
    "PHAROS_RUNTIME_TRACE_ENABLED",
    config.runtime.trace_calls_enabled,
  )
  Config(..config, runtime: RuntimeConfig(trace_calls_enabled: enabled))
}

fn env_bridge(config: Config) -> Config {
  case env.get("PHAROS_BRIDGE_PORT") {
    None -> config
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(p) -> Config(..config, bridge: BridgeConfig(port: Some(p)))
        Error(_) -> config
      }
  }
}

fn read_bool_env(name: String, default: Bool) -> Bool {
  case env.get(name) {
    None -> default
    Some(raw) ->
      case string.lowercase(string.trim(raw)) {
        "0" | "off" | "false" | "no" | "" -> False
        _ -> True
      }
  }
}

fn split_csv(raw: String) -> List(String) {
  string.split(raw, ",")
  |> list.map(string.trim)
  |> list.filter(fn(s) { s != "" })
}
