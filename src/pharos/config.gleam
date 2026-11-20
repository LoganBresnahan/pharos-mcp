//// Configuration umbrella.
////
//// Single source of truth for every knob pharos exposes. Reads —
//// in precedence order:
////
////   1. defaults (compiled into this module)
////   2. global TOML at `~/.config/pharos/pharos.toml`
////   3. project TOML: `.pharos.toml` or `pharos.toml`, in the nearest
////      directory walking up from cwd that has either (`.pharos.toml` wins
////      when both are there; the global file is never read as a project
////      file)
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
////   5. List the key in `pharos/config_keys`, or every use of it warns
////      as unknown (#32).
////   6. Document in `doc/example-pharos.toml` and the README.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pharos/config_keys
import pharos/env
import pharos/log
import pharos/log/entry as log_entry
import pharos/log/rotate as log_rotate
import pharos/log/writer
import pharos/lsp/languages.{type CustomUriScheme}
import pharos/tools/names as tool_names

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
    /// Override the total spawn-time readiness budget — drain +
    /// probe combined (ADR-024). None = use the bundled default
    /// (`languages.default_ready_timeout_ms`, 60s). Languages with
    /// slow indexing (rust-analyzer big workspace, jdtls big project)
    /// tune up; nothing tunes down typically.
    ready_timeout_ms: Option(Int),
    /// Override the `initialize` handshake budget. None = use the
    /// bundled default (`languages.default_initialize_timeout_ms`,
    /// 90s — accommodates jdtls cold start).
    initialize_timeout_ms: Option(Int),
    /// #27. How long after its session is ready the server may answer
    /// workspace searches empty while it indexes without reporting
    /// progress; find_symbol retries within it. 0 turns it off.
    lazy_workspace_index_ms: Option(Int),
    /// #30. How long after a sync get_diagnostics waits for a check the
    /// server starts on save to begin. 0: no grace.
    save_check_grace_ms: Option(Int),
    /// #38. Send changes as a ranged whole-document replace.
    full_change_as_range: Option(Bool),
    /// #38. Wait this long after a change before a pull request.
    pull_after_change_ms: Option(Int),
    /// ADR-043. true: always scan for files changed on disk for this
    /// server; false: never. Unset: scan when the server registers file
    /// watchers.
    watch_files: Option(Bool),
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
    /// #17. `document_language_ids = { ".tsx" = "typescriptreact" }`:
    /// the LSP languageId per extension. Replaces the bundled list.
    document_language_ids: Option(List(#(String, String))),
    root_markers: Option(List(String)),
    /// ADR-032 step 4. In-tree dependency directory segments and
    /// out-of-tree dependency-cache suffixes for this language. Both
    /// replace the bundled list rather than adding to it, same as
    /// `root_markers`. See `languages.LanguageConfig` for the
    /// matching semantics each one carries.
    vendor_segments: Option(List(String)),
    dependency_cache_fragments: Option(List(String)),
    /// ADR-034. Env vars whose values split LSP sharing between
    /// sessions. Replaces the bundled list.
    env_keys: Option(List(String)),
    /// ADR-034. Seconds of no requests before this language's LSP is
    /// stopped; 0 never stops it.
    idle_stop_secs: Option(Int),
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
    ready_timeout_ms: Option(Int),
    initialize_timeout_ms: Option(Int),
    /// #27. How long after its session is ready the server may answer
    /// workspace searches empty while it indexes without reporting
    /// progress; find_symbol retries within it. 0 turns it off.
    lazy_workspace_index_ms: Option(Int),
    /// #30. How long after a sync get_diagnostics waits for a check the
    /// server starts on save to begin. 0: no grace.
    save_check_grace_ms: Option(Int),
    /// #38. Send changes as a ranged whole-document replace.
    full_change_as_range: Option(Bool),
    /// #38. Wait this long after a change before a pull request.
    pull_after_change_ms: Option(Int),
    /// ADR-043. true: always scan for files changed on disk for this
    /// server; false: never. Unset: scan when the server registers file
    /// watchers.
    watch_files: Option(Bool),
    /// ADR-029. User-defined custom URI schemes for this language.
    /// Each entry merges into the bundled defaults by scheme key:
    /// user-supplied schemes that already exist replace the default
    /// entry, new schemes get appended. `None` keeps defaults
    /// unchanged. TOML shape:
    ///
    ///     [languages.scala.custom_uri_schemes."metals-decode"]
    ///     fetch_method = "metals/readMetalsResource"
    ///     fetch_response_field = "value"
    ///
    /// The dotted scheme key form supports schemes with `-` in the
    /// name (`metals-decode`, `vscode-userdata`). For simple alpha
    /// names the quotes are optional (`custom_uri_schemes.jdt`).
    custom_uri_schemes: Option(Dict(String, CustomUriScheme)),
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
    // The `"default"` meta-alias expands to read + write + memory
    // plus a small allowlist of debug-category essentials the LLM
    // needs to recover from tool errors (`echo`,
    // `runtime_set_tool_timeout`, `runtime_effective_tool_config`,
    // `runtime_language_config`, `runtime_server_capabilities`) —
    // see `is_default_essential/1`. Diagnostics beyond those five
    // (`runtime_processes`, log_*, trace_*, kill_lsp, etc.) are
    // opt-in via `tools = ["default", "debug"]` or explicit names;
    // same for the `"raw"` escape hatch.
    tools: ToolFilter(entries: ["default"]),
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
  let config = resolve(cwd(), env.get)
  store_persistent(config)
  config
}

/// Build the effective Config for a working directory and an env
/// lookup, without caching it. `load/0` is this over the process's
/// own cwd and env; a session context (ADR-034) is this over the
/// session's. Same code either way, so the two cannot drift.
pub fn resolve(cwd: String, getenv: fn(String) -> Option(String)) -> Config {
  warn_dotted_global(cwd, getenv)
  defaults()
  |> overlay_global_toml(getenv)
  |> overlay_project_toml(cwd, getenv)
  |> warn_unknown_tool_languages
  |> apply_env(getenv)
}

/// Return the calling process's session Config when one is bound
/// (ADR-034), else the Config stored by `load/0`, else compiled
/// defaults (test harnesses bypassing boot, etc.).
pub fn cached() -> Config {
  case session_config() {
    Ok(config) -> config
    Error(_) ->
      case load_persistent() {
        Ok(config) -> config
        Error(_) -> defaults()
      }
  }
}

@external(erlang, "pharos_session_ctx_ffi", "config")
fn session_config() -> Result(Config, Nil)

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
  /// Project-local memory tools (ADR-027): cross-MCP-client
  /// knowledge store under `.pharos/memories/` and `~/.pharos/memories/`.
  /// Ships in the default profile; opt out via explicit category
  /// list (`tools = ["read", "write"]`).
  CatMemory
}

/// True iff `name` (with its known category) is exposed under the
/// supplied filter. Resolution: a name is exposed iff
///   1. the literal tool name is in `entries`, or
///   2. its category alias ("read"/"write"/"memory"/"debug"/"raw")
///      is in `entries`, or
///   3. the meta-alias `"default"` is in `entries` AND EITHER the
///      tool's category is part of the default-shipped profile
///      (read, write, memory) OR the tool is one of the five
///      default-essentials — small carve-out from `CatDebug` for
///      the LLM-facing escape hatches the read/write surface
///      points at when timeouts surface (ADR-021's 5-layer stack).
///   4. the meta-alias `"all"` is in `entries` (every category
///      exposed).
///
/// Rule 3 makes `tools = ["default"]` a one-knob production preset
/// — same surface as the previous `CatDefault`-as-its-own-category
/// design but without the conceptual overlap with `CatDebug`. Rule 4
/// makes `tools = ["all"]` the matching one-knob "expose everything"
/// preset for dogfood / debugging / power-user installs.
pub fn tool_allowed(
  filter: ToolFilter,
  name: String,
  category: ToolCategory,
) -> Bool {
  let alias = category_alias(category)
  let default_member =
    is_in_default_profile(category) || is_default_essential(name)
  list.any(filter.entries, fn(e) {
    e == "all"
    || e == alias
    || e == name
    || { e == "default" && default_member }
  })
}

fn category_alias(category: ToolCategory) -> String {
  case category {
    CatRead -> "read"
    CatWrite -> "write"
    CatDebug -> "debug"
    CatRaw -> "raw"
    CatMemory -> "memory"
  }
}

/// Categories that the meta-alias `"default"` resolves to wholesale.
/// Read + Write + Memory cover the LLM's primary surface; the
/// default-essentials allowlist (`is_default_essential/1`) covers
/// the small `CatDebug` carve-out the LLM needs for tool-error
/// recovery.
fn is_in_default_profile(category: ToolCategory) -> Bool {
  case category {
    CatRead | CatWrite | CatMemory -> True
    CatDebug | CatRaw -> False
  }
}

/// Named members of `CatDebug` that the `"default"` filter alias
/// pulls in despite the category itself being opt-in. Keep this
/// list small — every entry widens the production attack surface.
/// `echo` is the MCP smoke-test affordance an MCP host can hit
/// before any LSP-bound tool; the four `runtime_*` tools are the
/// timeout-recovery knobs printed in every `tool timeout` error
/// message (ADR-021's 5-layer stack). Without them in the default
/// profile the LLM cannot self-service the very escape hatch we
/// tell it about.
fn is_default_essential(name: String) -> Bool {
  case name {
    "echo"
    | "runtime_set_tool_timeout"
    | "runtime_effective_tool_config"
    | "runtime_language_config"
    | "runtime_server_capabilities" -> True
    _ -> False
  }
}

/// The languages config read so far defines, each with the server ids
/// it defines for it: what `config_keys` takes as already known (#32).
fn earlier_servers(config: Config) -> List(#(String, List(String))) {
  dict.to_list(config.languages)
  |> list.map(fn(pair) {
    let #(id, override) = pair
    #(id, case override.servers {
      Some(servers) ->
        list.filter_map(servers, fn(s) { option.to_result(s.id, Nil) })
      None -> []
    })
  })
}

/// #32: the `[tool_config.<tool>.<lang>]` blocks whose language neither
/// pharos bundles nor any config file defines, once every file is read
/// (a language the project file adds may be named in the global one):
/// `#(key, language, likely misspelling)`.
pub fn unknown_tool_languages(
  config: Config,
) -> List(#(String, String, Option(String))) {
  let known =
    list.append(
      dict.keys(languages.default_registry()),
      dict.keys(config.languages),
    )
  dict.to_list(config.tool_config)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.flat_map(fn(pair) {
    let #(tool, tc) = pair
    dict.keys(tc.languages)
    |> list.sort(string.compare)
    |> list.filter_map(fn(lang) {
      case list.contains(known, lang) {
        True -> Error(Nil)
        False ->
          Ok(#(
            "tool_config." <> tool <> "." <> lang,
            lang,
            config_keys.closest(lang, known),
          ))
      }
    })
  })
}

fn warn_unknown_tool_languages(config: Config) -> Config {
  list.each(unknown_tool_languages(config), fn(found) {
    let #(key, lang, suggestion) = found
    case first_config_check(key, <<"tool language">>, writer.running()) {
      False -> Nil
      True ->
        log.fields_at(
          "pharos/config",
          log_entry.Warn,
          "config names an unknown language",
          [
            #("key", key),
            #("name", lang),
            ..option_field("did_you_mean", suggestion)
          ],
        )
    }
  })
  config
}

/// #32: checks the config files again, discarding the result, so their
/// warnings reach the log writer's sinks (the daemon log, the ring) once
/// it is up. The first check, at boot, runs before the writer starts and
/// reaches stderr only. Call once the writer runs.
pub fn recheck() -> Nil {
  let _ = resolve(cwd(), env.get)
  Nil
}

// -- Global TOML overlay --------------------------------------------------

fn overlay_global_toml(
  config: Config,
  getenv: fn(String) -> Option(String),
) -> Config {
  case getenv("PHAROS_CONFIG_FILE") {
    Some(path) if path != "" -> overlay_path(config, path, "PHAROS_CONFIG_FILE")
    _ ->
      case xdg_config_path(getenv) {
        None -> config
        Some(path) ->
          case path_exists(path) {
            False -> config
            True -> overlay_path(config, path, "global config")
          }
      }
  }
}

/// #32. The global file is `pharos.toml`; a `.pharos.toml` beside where
/// it would be is never read as the global file (the dotted name is the
/// project file's). Warns about one, unless the project walk takes it (a
/// cwd in that directory), or PHAROS_CONFIG_FILE names the global file.
fn warn_dotted_global(
  cwd: String,
  getenv: fn(String) -> Option(String),
) -> Nil {
  case dotted_global_ignored(cwd, getenv) {
    None -> Nil
    Some(#(dotted, path)) ->
      case first_config_check(dotted, <<"misnamed">>, writer.running()) {
        False -> Nil
        True ->
          log.fields_at(
            "pharos/config",
            log_entry.Warn,
            "config file not read: the global file is pharos.toml",
            [#("ignored", dotted), #("expected_at", path)],
          )
      }
  }
}

/// The `.pharos.toml` in the global config directory that nothing
/// reads, with where the global file is expected: when there is no
/// `pharos.toml` beside it, PHAROS_CONFIG_FILE doesn't name the global
/// file, and the project walk from `cwd` doesn't take it.
pub fn dotted_global_ignored(
  cwd: String,
  getenv: fn(String) -> Option(String),
) -> Option(#(String, String)) {
  let global = case getenv("PHAROS_CONFIG_FILE") {
    Some(set) if set != "" -> None
    _ -> xdg_config_path(getenv)
  }
  case global {
    None -> None
    Some(path) -> {
      let dotted = dirname(path) <> "/.pharos.toml"
      let taken = case find_project_config(cwd, getenv) {
        #(Some(found), _) -> same_file(found, dotted)
        #(None, _) -> False
      }
      case path_exists(dotted) && !path_exists(path) && !taken {
        True -> Some(#(dotted, path))
        False -> None
      }
    }
  }
}

fn xdg_config_path(getenv: fn(String) -> Option(String)) -> Option(String) {
  case getenv("XDG_CONFIG_HOME") {
    Some(xdg) if xdg != "" -> Some(xdg <> "/pharos/pharos.toml")
    _ ->
      case getenv("HOME") {
        Some(home) if home != "" -> Some(home <> "/.config/pharos/pharos.toml")
        _ -> None
      }
  }
}

// -- Project TOML overlay -------------------------------------------------

fn overlay_project_toml(
  config: Config,
  cwd: String,
  getenv: fn(String) -> Option(String),
) -> Config {
  let #(found, ignored) = find_project_config(cwd, getenv)
  list.each(ignored, fn(pair) {
    let #(path, instead) = pair
    case first_config_check(path, <<"shadowed">>, writer.running()) {
      False -> Nil
      True ->
        log.fields_at(
          "pharos/config",
          log_entry.Warn,
          "config file ignored: the other project file name in its directory is read instead",
          [#("ignored", path), #("read", instead)],
        )
    }
  })
  case found {
    None -> config
    Some(path) -> overlay_path(config, path, "project config")
  }
}

/// #32. The project config: the nearest directory, walking up from
/// `start_dir` to the filesystem root, holding `.pharos.toml` or
/// `pharos.toml`. In a directory with both, `.pharos.toml` is read and
/// `pharos.toml` is returned as ignored, `#(ignored, read)`. The global
/// file (`PHAROS_CONFIG_FILE`, else the XDG one) is never taken as a
/// project file, so a project under `~/.config/pharos`, or a walk passing
/// it, doesn't read it twice.
pub fn find_project_config(
  start_dir: String,
  getenv: fn(String) -> Option(String),
) -> #(Option(String), List(#(String, String))) {
  let global = case getenv("PHAROS_CONFIG_FILE") {
    Some(path) if path != "" -> Some(path)
    _ -> xdg_config_path(getenv)
  }
  let usable = fn(path) {
    path_exists(path)
    && case global {
      Some(g) -> !same_file(path, g)
      None -> True
    }
  }
  case start_dir {
    "" -> #(None, [])
    dir -> walk_up(dir, dir, usable)
  }
}

fn walk_up(
  current: String,
  previous: String,
  usable: fn(String) -> Bool,
) -> #(Option(String), List(#(String, String))) {
  let dotted = current <> "/.pharos.toml"
  let plain = current <> "/pharos.toml"
  case usable(dotted), usable(plain) {
    True, True -> #(Some(dotted), [#(plain, dotted)])
    True, False -> #(Some(dotted), [])
    False, True -> #(Some(plain), [])
    False, False -> {
      let parent = dirname(current)
      case parent == current || parent == previous {
        True -> #(None, [])
        False -> walk_up(parent, current, usable)
      }
    }
  }
}

@external(erlang, "pharos_fs_ffi", "same_file")
fn same_file(a: String, b: String) -> Bool

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
      log.fields_at("pharos/config", log_entry.Warn, "ignoring " <> label, [
        #("path", path),
        #("reason", reason),
      ])
      config
    }
    Ok(#(bytes, parsed)) -> {
      log.fields_at("pharos/config", log_entry.Info, "loaded " <> label, [
        #("path", path),
      ])
      warn_unknown_keys(path, bytes, parsed, earlier_servers(config))
      apply_toml(config, parsed)
    }
  }
}

/// #32. One warning per stray key, wrongly typed or invalid value,
/// unknown tool or language name, or missing required key; how the file
/// applies doesn't change. The config is
/// resolved at boot and again for every session (ADR-034), so a file's
/// warnings are logged once per pharos process for each content it has
/// (an edited file warns afresh) and each state of the log writer. At
/// boot the writer isn't up, so they go to stderr (a daemon's boot log);
/// `recheck/0`, once it is up, logs them again through it, so they reach
/// the log file and `runtime_log_tail` too. A daemon's writer has no
/// stderr sink unless PHAROS_LOG_STDERR turns it on, so its boot log
/// holds one copy; in direct mode with the stderr sink on (the default),
/// stderr shows each warning twice, before and after the writer starts.
fn warn_unknown_keys(
  path: String,
  bytes: BitArray,
  parsed: Dynamic,
  earlier: List(#(String, List(String))),
) -> Nil {
  case config_keys.check(parsed, earlier) {
    [] -> Nil
    problems ->
      case first_config_check(path, bytes, writer.running()) {
        False -> Nil
        True ->
          list.each(problems, fn(problem) {
            let #(message, fields) = case problem {
              config_keys.UnknownKey(key, suggestion) -> #(
                "unknown config key, ignored",
                [#("key", key), ..option_field("did_you_mean", suggestion)],
              )
              config_keys.WrongType(key, expected, got) -> #(
                "config value has the wrong type, ignored",
                [#("key", key), #("expected", expected), #("got", got)],
              )
              config_keys.UnknownName(key, name, kind, suggestion) -> #(
                "config names an unknown " <> kind,
                [
                  #("key", key),
                  #("name", name),
                  ..option_field("did_you_mean", suggestion)
                ],
              )
              config_keys.BadValue(key, value, expected, effect) -> #(
                "config value is invalid",
                [
                  #("key", key),
                  #("value", value),
                  #("expected", expected),
                  #("effect", effect),
                ],
              )
              config_keys.MissingKey(key, missing, effect) -> #(
                "config table lacks a key it needs",
                [#("key", key), #("missing", missing), #("effect", effect)],
              )
              config_keys.MisplacedKey(key, belongs) -> #(
                "config key is in the wrong table, ignored",
                [#("key", key), #("belongs_in", belongs)],
              )
              config_keys.NotUsed(key, why) -> #("config key does nothing yet", [
                #("key", key),
                #("why", why),
              ])
            }
            log.fields_at("pharos/config", log_entry.Warn, message, [
              #("path", path),
              ..fields
            ])
          })
      }
  }
}

fn option_field(
  name: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    Some(v) -> [#(name, v)]
    None -> []
  }
}

/// True the first time this process checks `path` with these contents
/// while the log writer is (or isn't) running.
@external(erlang, "pharos_runtime_ffi", "first_config_check")
fn first_config_check(path: String, bytes: BitArray, writer_up: Bool) -> Bool

fn read_toml(path: String) -> Result(#(BitArray, Dynamic), String) {
  use bytes <- result.try(read_bytes(path))
  use parsed <- result.try(toml_parse(bytes))
  Ok(#(bytes, parsed))
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
  case
    decode_field(
      parsed,
      "tool_config",
      decode.dict(decode.string, decode.dynamic),
    )
  {
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
  let default_timeout_ms = decode_positive_int(value, "default_timeout_ms")
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
              decode.run(sub_value, decode.dict(decode.string, decode.dynamic))
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

/// #32: a list in which no entry names a tool, category or preset is
/// ignored, keeping the earlier value ("default" unless an earlier file
/// set it): it would expose no tools at all. An explicit `tools = []`
/// still does exactly that.
fn apply_top_tools(config: Config, parsed: Dynamic) -> Config {
  case decode_field(parsed, "tools", decode.list(decode.string)) {
    Ok([]) -> Config(..config, tools: ToolFilter(entries: []))
    Ok(entries) -> {
      let known = list.append(tool_names.all(), tool_names.filter_aliases())
      case list.any(entries, list.contains(known, _)) {
        True -> Config(..config, tools: ToolFilter(entries: entries))
        False -> config
      }
    }
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
          let port_file = case decode_field(http, "port_file", decode.string) {
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
      let filter_spec = case decode_field(log_table, "filter", decode.string) {
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
      let stderr_enabled = case decode_field(log_table, "stderr", decode.bool) {
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
          Config(..config, runtime: RuntimeConfig(trace_calls_enabled: b))
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
    file_extensions: decode_extensions(value),
    document_language_ids: decode_optional_string_table(
      value,
      "document_language_ids",
    ),
    root_markers: decode_optional_string_list(value, "root_markers"),
    vendor_segments: decode_optional_string_list(value, "vendor_segments"),
    dependency_cache_fragments: decode_optional_string_list(
      value,
      "dependency_cache_fragments",
    ),
    env_keys: decode_optional_string_list(value, "env_keys"),
    idle_stop_secs: decode_optional_int(value, "idle_stop_secs")
      |> option.then(fn(n) {
        case n >= 0 {
          True -> Some(n)
          False -> None
        }
      }),
    diagnostics_mode: decode_diagnostics_mode(value),
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
    ready_timeout_ms: decode_ready_timeout_ms(value),
    initialize_timeout_ms: decode_positive_int(value, "initialize_timeout_ms"),
    lazy_workspace_index_ms: decode_optional_int(
      value,
      "lazy_workspace_index_ms",
    ),
    save_check_grace_ms: decode_optional_int(value, "save_check_grace_ms"),
    full_change_as_range: decode_optional_bool(value, "full_change_as_range"),
    pull_after_change_ms: decode_optional_int(value, "pull_after_change_ms"),
    watch_files: decode_optional_bool(value, "watch_files"),
    custom_uri_schemes: decode_optional_custom_uri_schemes(value),
  )
}

/// ADR-029. Decode `[languages.<id>.custom_uri_schemes.<scheme>]`
/// sub-tables into a Dict keyed by scheme name. Missing key → None
/// (defaults from `languages.gleam` flow through unchanged). Each
/// sub-table requires both `fetch_method` and `fetch_response_field`
/// — missing either skips that scheme so partial config doesn't
/// silently land malformed entries.
fn decode_optional_custom_uri_schemes(
  parent: Dynamic,
) -> Option(Dict(String, CustomUriScheme)) {
  case decode_field(parent, "custom_uri_schemes", decode.dynamic) {
    Error(_) -> None
    Ok(table) ->
      case decode.run(table, decode.dict(decode.string, decode.dynamic)) {
        Error(_) -> None
        Ok(entries) -> {
          let pairs =
            entries
            |> dict.to_list
            |> list.filter_map(fn(pair) {
              let #(scheme, body) = pair
              case decode_custom_uri_scheme_body(body) {
                Some(meta) -> Ok(#(scheme, meta))
                None -> Error(Nil)
              }
            })
          case pairs {
            [] -> None
            _ -> Some(dict.from_list(pairs))
          }
        }
      }
  }
}

fn decode_custom_uri_scheme_body(value: Dynamic) -> Option(CustomUriScheme) {
  case
    decode_optional_string(value, "fetch_method"),
    decode_optional_string(value, "fetch_response_field")
  {
    Some(method), Some(field) ->
      Some(languages.CustomUriScheme(
        fetch_method: method,
        fetch_response_field: field,
      ))
    // `fetch_response_field` defaults to "" when omitted — useful
    // for schemes whose LSP method returns the content string
    // directly (jdtls's `java/classFileContents`).
    Some(method), None ->
      Some(languages.CustomUriScheme(
        fetch_method: method,
        fetch_response_field: "",
      ))
    None, _ -> None
  }
}

/// #32: empty entries are dropped (one would claim every file); a list
/// with nothing else in it is ignored, so the bundled extensions stay,
/// rather than leaving the language none. An explicit `[]` stays `[]`.
fn decode_extensions(value: Dynamic) -> Option(List(String)) {
  case decode_optional_string_list(value, "file_extensions") {
    Some(extensions) ->
      case list.filter(extensions, fn(ext) { ext != "" }), extensions {
        [], [_, ..] -> None
        kept, _ -> Some(kept)
      }
    None -> None
  }
}

/// #32: a mode `registry` doesn't recognise is ignored, so the bundled
/// mode stays (it used to be read as push).
fn decode_diagnostics_mode(value: Dynamic) -> Option(String) {
  case decode_optional_string(value, "diagnostics_mode") {
    Some(mode) ->
      case
        list.contains(
          [
            "push", "Push", "PUSH", "pull", "Pull", "PULL", "tsserver",
            "Tsserver", "TSSERVER",
          ],
          mode,
        )
      {
        True -> Some(mode)
        False -> None
      }
    None -> None
  }
}

/// #32: a timeout of 0 or less is ignored, so the default stays (it used
/// to time out at once).
fn decode_positive_int(value: Dynamic, key: String) -> Option(Int) {
  case decode_optional_int(value, key) {
    Some(n) if n > 0 -> Some(n)
    _ -> None
  }
}

/// ADR-024 rename: `readiness_timeout_ms` → `ready_timeout_ms`.
/// Accept either TOML key with the new name winning so existing
/// user configs do not break silently.
fn decode_ready_timeout_ms(value: Dynamic) -> Option(Int) {
  case decode_optional_int(value, "ready_timeout_ms") {
    Some(n) -> Some(n)
    None -> decode_optional_int(value, "readiness_timeout_ms")
  }
}

/// Decode `[[languages.<id>.servers]]` array of tables. Tomerl
/// renders TOML arrays of inline tables as a List(Dynamic) where
/// each element is a map; pull the per-server fields out of each.
/// Returns `None` when the key is absent or the value isn't an
/// array of tables — falls back to legacy flat-override semantics.
fn decode_optional_servers_list(
  parent: Dynamic,
) -> Option(List(ServerOverride)) {
  case decode_field(parent, "servers", decode.list(decode.dynamic)) {
    Error(_) -> None
    Ok(entries) -> Some(list.map(entries, decode_server_override))
  }
}

fn decode_server_override(value: Dynamic) -> ServerOverride {
  ServerOverride(
    id: decode_optional_string(value, "id"),
    command: decode_optional_string(value, "command"),
    args: decode_optional_string_list(value, "args"),
    methods: decode_optional_string_list(value, "methods"),
    diagnostics_mode: decode_diagnostics_mode(value),
    readiness_token: decode_optional_string(value, "readiness_token"),
    ready_timeout_ms: decode_ready_timeout_ms(value),
    initialize_timeout_ms: decode_positive_int(value, "initialize_timeout_ms"),
    lazy_workspace_index_ms: decode_optional_int(
      value,
      "lazy_workspace_index_ms",
    ),
    save_check_grace_ms: decode_optional_int(value, "save_check_grace_ms"),
    full_change_as_range: decode_optional_bool(value, "full_change_as_range"),
    pull_after_change_ms: decode_optional_int(value, "pull_after_change_ms"),
    watch_files: decode_optional_bool(value, "watch_files"),
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

/// A TOML table of strings, as (key, value) pairs sorted by key; None
/// when the key is missing or isn't such a table.
fn decode_optional_string_table(
  parent: Dynamic,
  key: String,
) -> Option(List(#(String, String))) {
  case decode_field(parent, key, decode.dict(decode.string, decode.string)) {
    Ok(table) ->
      Some(
        dict.to_list(table)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
      )
    Error(_) -> None
  }
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

fn apply_env(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  config
  |> env_transport(getenv)
  |> env_tools(getenv)
  |> env_http(getenv)
  |> env_log(getenv)
  |> env_lsp(getenv)
  |> env_runtime(getenv)
  |> env_bridge(getenv)
}

fn env_transport(
  config: Config,
  getenv: fn(String) -> Option(String),
) -> Config {
  case getenv("PHAROS_TRANSPORT") {
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

fn env_tools(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  case getenv("PHAROS_TOOLS") {
    None -> config
    Some(raw) ->
      case string.trim(raw) {
        "" -> config
        s -> Config(..config, tools: ToolFilter(entries: split_csv(s)))
      }
  }
}

fn env_http(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  let port = case getenv("PHAROS_HTTP_PORT") {
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
  let bind = case getenv("PHAROS_HTTP_BIND") {
    None -> config.http.bind
    Some(raw) ->
      case string.trim(raw) {
        "" -> config.http.bind
        b -> b
      }
  }
  let port_file = case getenv("PHAROS_HTTP_PORT_FILE") {
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

fn env_log(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  let filter_spec = case getenv("PHAROS_LOG") {
    None -> config.log.filter_spec
    Some(raw) -> raw
  }
  // ADR-030 C2: when the user hasn't configured a log file via env
  // OR TOML, default to a per-PID per-timestamp path under
  // the log dir (`log_rotate.log_cache_dir`). Multi-instance pharos (Phase 5 was
  // the trigger) used to leave a single `PHAROS_LOG_FILE` path
  // shared across instances, which clobbered. The auto-default
  // produces one readable file per pharos PID per launch.
  let file = case getenv("PHAROS_LOG_FILE") {
    Some("") -> None
    Some(path) -> Some(path)
    None ->
      case config.log.file {
        Some(path) -> Some(path)
        None -> log_rotate.default_session_log_path()
      }
  }
  let ring_enabled =
    read_bool_env(getenv, "PHAROS_LOG_RING", config.log.ring_enabled)
  let stderr_enabled =
    read_bool_env(getenv, "PHAROS_LOG_STDERR", config.log.stderr_enabled)
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

fn env_lsp(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  let trace = read_bool_env(getenv, "PHAROS_TRACE_LSP", config.lsp.trace)
  Config(..config, lsp: LspConfig(trace: trace))
}

fn env_runtime(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  let enabled =
    read_bool_env(
      getenv,
      "PHAROS_RUNTIME_TRACE_ENABLED",
      config.runtime.trace_calls_enabled,
    )
  Config(..config, runtime: RuntimeConfig(trace_calls_enabled: enabled))
}

fn env_bridge(config: Config, getenv: fn(String) -> Option(String)) -> Config {
  case getenv("PHAROS_BRIDGE_PORT") {
    None -> config
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(p) -> Config(..config, bridge: BridgeConfig(port: Some(p)))
        Error(_) -> config
      }
  }
}

fn read_bool_env(
  getenv: fn(String) -> Option(String),
  name: String,
  default: Bool,
) -> Bool {
  case getenv(name) {
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

fn decode_optional_bool(parent: Dynamic, key: String) -> Option(Bool) {
  case decode_field(parent, key, decode.bool) {
    Ok(b) -> Some(b)
    Error(_) -> None
  }
}
