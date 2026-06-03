//// Library entry / facade for `pharos`.
////
//// `main/0` is the CLI entrypoint — invoked from Mix via the `start`
//// alias defined in `mix.exs` (`mix start`) and from the
//// Burrito-wrapped binary at runtime. Behaviour:
////
////   1. Parse argv. Recognised meta flags short-circuit and exit:
////        --version, -V             — print version and exit
////        --help, -h                — print usage and exit
////        --print-default-config    — print the canonical TOML
////                                    starter file and exit
////   2. Load Config from `pharos/config` (defaults overlaid by
////      `~/.config/pharos/pharos.toml`, `.pharos.toml` walked up
////      from cwd, then `PHAROS_*` env vars).
////   3. Build the supervised tree from the resolved Config.
////   4. Block until shutdown.
////
//// Every runtime knob lives in TOML or env vars — there are no
//// runtime-configuration CLI flags. See `doc/example-pharos.toml`
//// and the README for the full surface.

import gleam/dict
import gleam/erlang/process.{type Pid}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import pharos/cli
import pharos/config.{type Config}
import pharos/env
import pharos/heartbeat
import pharos/log
import pharos/log/entry
import pharos/log/filter
import pharos/log/rotate as log_rotate
import pharos/log/trace_ring
import pharos/lsp/capabilities
import pharos/lsp/diagnostics_cache
import pharos/lsp/dyn_sup
import pharos/lsp/inflight
import pharos/lsp/instance_track
import pharos/lsp/languages
import pharos/lsp/pool
import pharos/lsp/registry
import pharos/lsp/registry_toml
import pharos/mcp/request_workers
import pharos/supervisor as root_supervisor
import pharos/tools/session
import pharos/workspace_root

const server_version: String = "0.1.1"

pub fn main() -> Nil {
  // Set ERL_CRASH_DUMP target before anything else so a BEAM-level
  // panic from later in boot lands in `~/.cache/pharos/log/` next to
  // pharos's own crash-dump file rather than in the invoker's cwd
  // (the historical default, which pollutes user project trees and
  // hides the trace under .gitignore). No-op if BEAM has already
  // cached the env value, but in practice this fires before any
  // OS-level halt path runs.
  redirect_erl_crash_dump()
  case handle_meta_flags(argv()) {
    Handled -> Nil
    Continue ->
      case boot() {
        Error(reason) -> {
          log.error("root supervisor failed to start: " <> reason)
          Nil
        }
        Ok(_pid) -> {
          let cfg = config.cached()
          log.info(
            "pharos starting (transport="
              <> transport_label(cfg.transport)
              <> ")",
          )
          // ADR-024 + `pharos warm <lang>...` subcommand:
          // `post_boot_dispatch/0` looks at argv to decide between
          // warm-and-exit mode (`pharos warm rust typescript`) and
          // the normal MCP-server warmup path (consults
          // `PHAROS_WARM_LANGS` env var). Always runs the actual
          // warming in a spawned process so we return here to
          // `process.sleep_forever/0` (or the OTP app callback
          // returns to its caller in release mode).
          post_boot_dispatch()
          // Stdio/Both: stdio_worker drives termination via stdin
          // EOF. Http only: no stdio termination signal; sleep
          // until SIGTERM.
          process.sleep_forever()
        }
      }
  }
}

/// Hook called from `pharos_app_ffi:start/2` so meta-flag dispatch
/// works in Burrito-wrapped release mode. The release entry path
/// bypasses `main/0` entirely — it goes straight from `:elixir`'s
/// start_cli through the OTP application controller into
/// `pharos_app_ffi:start/2`, which means `--doctor`, `--purge-cache`,
/// and `--cleanup` would never be checked. This function lets the
/// app-start callback run the same dispatch.
///
/// Returns `True` when a meta flag fired (caller should halt) and
/// `False` when normal boot should continue.
pub fn dispatch_meta_or_continue() -> Bool {
  case handle_meta_flags(argv()) {
    Handled -> True
    Continue -> False
  }
}

/// Idempotent application-bootstrap entry point. Returns the root
/// supervisor's Pid. Called both from `pharos_app_ffi:start/2` (so
/// OTP's application_controller treats the supervisor as the
/// application's primary process) and from `main/0` (so `mix start`
/// and dev shells produce the same tree without double-spawning).
///
/// Idempotency: a second call when the supervisor is already running
/// returns the existing Pid via the `pharos_root_supervisor`
/// registered name without re-running ETS init or
/// `root_supervisor.start`.
pub fn boot() -> Result(Pid, String) {
  case find_root_supervisor() {
    Ok(pid) -> Ok(pid)
    Error(_) -> do_boot()
  }
}

fn do_boot() -> Result(Pid, String) {
  // Resolve and stash Config in persistent_term FIRST. Downstream
  // initialisers (notably registry.init, which merges
  // Config.languages over the bundled defaults) read it. Every
  // downstream consumer (log, http transport, registry, runtime
  // tools) reads the cached value instead of touching env vars or
  // files itself.
  let cfg = config.load()

  // Pre-supervisor init: idempotent ETS tables that supervised
  // children read or write. Order does not matter beyond "before
  // root_supervisor.start" — except registry.init, which must run
  // AFTER config.load so persistent_term carries the user's
  // language overrides at merge time.
  diagnostics_cache.init()
  trace_ring.init(trace_ring.default_capacity)
  registry.init()
  inflight.init()
  request_workers.init()
  dyn_sup.init_subjects_bridge()
  capabilities.init()
  // ADR-030 S3: create `~/.local/share/pharos/instances/<our-pid>/`
  // so client.start can write tracking files for each LSP it
  // spawns. Idempotent. No-op on platforms where $HOME is unset
  // (falls back to /tmp/pharos-instances/).
  instance_track.init()
  // ADR-030 C2: migrate any legacy `erl_crash.dump` from cwd into
  // the log cache dir and LRU-trim session logs (keep 10) and
  // crash dumps (keep 5). Best-effort; never blocks boot.
  log_rotate.boot_sweep()

  // Diagnostic logger handler: capture every SASL/supervisor/error
  // logger event by writing the raw term to stderr. Bypasses the
  // gleam `logging` library's SASL filter and survives the
  // EndOfStream removal of the default handler observed in
  // dogfood pass 11. Side-effect only; idempotent.
  install_sasl_capture_handler()

  // `pharos warm <lang>...` boots the supervised tree (pool +
  // ETS + dyn_sup) but suppresses every transport so stdin EOF
  // does not race the warm-then-exit dispatch into a half-stopped
  // application_controller (which would skip the stop/1 callback
  // and leak the instance dir).
  let resolved_transport = case parse_warm_args(argv()) {
    Some(_) -> root_supervisor.Disabled
    None -> map_transport(cfg.transport)
  }

  let supervisor_config =
    root_supervisor.Config(
      transport: resolved_transport,
      log_filter: build_log_filter(cfg),
      log_ring_enabled: cfg.log.ring_enabled,
      log_stderr_enabled: cfg.log.stderr_enabled,
      log_file_path: cfg.log.file,
      log_file_max_bytes: cfg.log.file_max_bytes,
      log_file_keep_rotated: cfg.log.file_keep_rotated,
      http_port: cfg.http.port,
      http_bind: cfg.http.bind,
    )

  case root_supervisor.start(supervisor_config) {
    Error(_) -> Error("root_supervisor.start returned an error")
    Ok(started) -> {
      register_root_supervisor(started.pid)
      // ADR-030 I1: spawn the linked heartbeat process AFTER the
      // root supervisor is up. Wiring it here (not in main/0) means
      // both `mix start` and the burrito release path get the
      // heartbeat — the release path enters via
      // `pharos_app_ffi:start/2` → `boot/0` and bypasses `main/0`
      // entirely. Cheap loop (`erlang:memory/1` +
      // `erlang:system_info/1`) at `PHAROS_HEARTBEAT_INTERVAL_MS`
      // (default 60_000) cadence.
      let _heartbeat = heartbeat.start()
      Ok(started.pid)
    }
  }
}

@external(erlang, "pharos_runtime_ffi", "register_root_supervisor")
fn register_root_supervisor(pid: Pid) -> Nil

@external(erlang, "pharos_runtime_ffi", "find_root_supervisor")
fn find_root_supervisor() -> Result(Pid, Nil)

@external(erlang, "pharos_runtime_ffi", "install_sasl_capture_handler")
fn install_sasl_capture_handler() -> Nil

@external(erlang, "pharos_runtime_ffi", "redirect_erl_crash_dump")
fn redirect_erl_crash_dump() -> Nil

@external(erlang, "pharos_runtime_ffi", "argv")
fn argv() -> List(String)

fn map_transport(t: config.Transport) -> root_supervisor.Transport {
  case t {
    config.Stdio -> root_supervisor.Stdio
    config.Http -> root_supervisor.Http
    config.Both -> root_supervisor.Both
  }
}

fn transport_label(transport: config.Transport) -> String {
  case transport {
    config.Stdio -> "stdio"
    config.Http -> "http"
    config.Both -> "both"
  }
}

/// Combine `log.filter_spec` (the user's RUST_LOG-style spec) with
/// `lsp.trace` (the convenience flag) into the runtime filter the
/// writer consumes. Trace flag forces `pharos/lsp/trace=debug` on top
/// of whatever the spec already says — same precedence order
/// pharos.gleam used before the config umbrella landed.
fn build_log_filter(cfg: Config) -> filter.Filter {
  let parsed = filter.parse_spec(cfg.log.filter_spec)
  case cfg.lsp.trace {
    False -> parsed
    True ->
      filter.Filter(
        default: parsed.default,
        overrides: [
          filter.Override("pharos/lsp/trace", Some(entry.Debug)),
          ..parsed.overrides
        ],
      )
  }
}

// -- Meta-flag dispatch --------------------------------------------------

type MetaOutcome {
  /// One of the meta flags fired; main should exit without booting.
  Handled
  /// No meta flag matched; proceed with normal boot.
  Continue
}

fn handle_meta_flags(args: List(String)) -> MetaOutcome {
  case match_meta(args) {
    None -> Continue
    Some(VersionRequested) -> {
      io.println("pharos " <> server_version)
      Handled
    }
    Some(HelpRequested) -> {
      io.println(usage())
      Handled
    }
    Some(PrintDefaultConfig) -> {
      io.println(default_config_template)
      Handled
    }
    Some(PrintLanguageConfig(language)) -> {
      print_language_config(language)
      Handled
    }
    Some(Doctor) -> {
      let _exit = cli.doctor()
      Handled
    }
    Some(PurgeCache) -> {
      let _exit = cli.purge_cache()
      Handled
    }
    Some(Cleanup(apply)) -> {
      let _exit = cli.cleanup(apply, 5000)
      Handled
    }
  }
}

type MetaFlag {
  VersionRequested
  HelpRequested
  PrintDefaultConfig
  PrintLanguageConfig(String)
  Doctor
  PurgeCache
  /// ADR-030 Layer 3: scan `~/.local/share/pharos/instances/` for
  /// subdirs whose owner pharos PID is dead, list them, and on
  /// `--yes` reap the listed LSP children. `Bool` is `True` when
  /// `--yes` is present (apply changes), `False` for dry-run.
  Cleanup(Bool)
}

fn match_meta(args: List(String)) -> Option(MetaFlag) {
  // Two-arg flags (`--print-language-config <id>`) handled before
  // the single-arg fold so the fold doesn't see the language name in
  // isolation and treat it as an unknown.
  case match_print_language_config(args) {
    Some(flag) -> Some(flag)
    None ->
      list.fold_until(args, None, fn(_acc, arg) {
        case arg {
          "--version" | "-V" -> list.Stop(Some(VersionRequested))
          "--help" | "-h" -> list.Stop(Some(HelpRequested))
          "--print-default-config" -> list.Stop(Some(PrintDefaultConfig))
          "--doctor" -> list.Stop(Some(Doctor))
          "--purge-cache" -> list.Stop(Some(PurgeCache))
          "--cleanup" ->
            // Dry-run by default; `--cleanup --yes` applies.
            list.Stop(Some(Cleanup(list.contains(args, "--yes"))))
          _ -> list.Continue(None)
        }
      })
  }
}

fn match_print_language_config(args: List(String)) -> Option(MetaFlag) {
  case args {
    ["--print-language-config", language, ..] ->
      Some(PrintLanguageConfig(language))
    [first, ..rest] ->
      case string.starts_with(first, "--print-language-config=") {
        True ->
          Some(PrintLanguageConfig(string.drop_start(first, 24)))
        False -> match_print_language_config(rest)
      }
    [] -> None
  }
}

fn print_language_config(language: String) -> Nil {
  let registry = registry.cached()
  case dict.get(registry, language) {
    Error(_) ->
      // Route through the unbuffered stdio FFI: io.println goes via
      // Erlang's `:user` group leader which the M11 `-noinput` flag
      // makes flaky under pharos-dev / burrito release stdio. The
      // FFI helper bypasses `:user` and writes directly to fd 1.
      stdio_write_line(
        "language `"
        <> language
        <> "` not found in registry. Known: "
        <> string.join(dict.keys(registry), ", "),
      )
    Ok(config) -> stdio_write_line(registry_toml.render_language(config))
  }
}

@external(erlang, "pharos_stdin_ffi", "write_line")
fn stdio_write_line(body: String) -> Nil

// -- ADR-024 boot-time warmup --------------------------------------------

/// Read `PHAROS_WARM_LANGS` (CSV of language ids) and pre-spawn
/// each language's LSP against cwd. Blocking — pool.get only returns
/// after the readiness probe succeeds. Failures (no workspace, no
/// pool, probe budget exhausted) log warn + continue so a missing
/// rust toolchain does not block gopls from warming. Ops-only knob;
/// production stays cold-start-on-first-call.
fn warm_from_env() -> Nil {
  case env.get("PHAROS_WARM_LANGS") {
    option.None -> Nil
    option.Some(raw) ->
      case split_csv(raw) {
        [] -> Nil
        langs -> warm_langs(langs)
      }
  }
}

/// Pre-spawn the supplied languages' LSPs against the current working
/// directory. Blocking — each `pool.get` call returns after the
/// readiness probe succeeds (or fails). Used by both the
/// `PHAROS_WARM_LANGS` env-var path and the `pharos warm <lang>...`
/// subcommand. Failures (no workspace, no pool, probe budget
/// exhausted) log a warn and continue so a missing rust toolchain
/// does not block gopls from warming.
pub fn warm_langs(langs: List(String)) -> Nil {
  case langs {
    [] -> Nil
    _ ->
      case pool.global() {
        Error(_) ->
          log.warn_at(
            "pharos/lsp/pool",
            "warmup requested but pool not running; skipping",
          )
        Ok(pool_handle) ->
          list.each(langs, fn(lang) { warm_one(pool_handle, lang) })
      }
  }
}

/// Dispatch the action that runs *after* `pharos:boot/0` returns —
/// either the user requested `pharos warm <lang>...` (warm and exit
/// via init:stop), or the normal MCP-server flow (consult
/// `PHAROS_WARM_LANGS` and stay alive).
///
/// Called by both `main/0` (mix start path) and
/// `pharos_app_ffi:start/2` (burrito release path). Always spawns
/// the actual work so the caller can return immediately to
/// `process.sleep_forever/0` or the OTP application controller.
pub fn post_boot_dispatch() -> Nil {
  case parse_warm_args(argv()) {
    Some(warm_request) -> {
      let _ =
        process.spawn(fn() {
          // Wait until the :pharos application is fully registered
          // as :running with application_controller before calling
          // init:stop(). Without this guard a fast warm (e.g. an
          // LSP that the pool already cached, or a no-op when the
          // lang is unknown) can call init:stop before the start/2
          // callback has returned, which leaves
          // application_controller in a half-started state where
          // the stop/1 callback never fires — leaking the instance
          // dir.
          wait_for_pharos_running(2000)
          let langs = resolve_warm_request(warm_request)
          warm_langs(langs)
          init_stop()
          Nil
        })
      Nil
    }
    None -> {
      let _ = process.spawn(fn() { warm_from_env() })
      Nil
    }
  }
}

/// Resolve a `WarmRequest` to a concrete list of language ids.
/// `WarmAll` enumerates every language in the registry (warm_one's
/// existing root-marker check skips ones whose project marker is
/// not in cwd, with a clear log line). `WarmExplicit` returns the
/// user's exact list unchanged.
fn resolve_warm_request(req: WarmRequest) -> List(String) {
  case req {
    WarmExplicit(langs) -> langs
    WarmAll -> dict.keys(registry.cached())
  }
}

@external(erlang, "pharos_runtime_ffi", "wait_for_pharos_running")
fn wait_for_pharos_running(timeout_ms: Int) -> Nil

/// What `pharos warm` was asked to do.
type WarmRequest {
  /// `pharos warm rust typescript go` — the named languages only.
  WarmExplicit(List(String))
  /// `pharos warm --all` — every language in the registry. The
  /// per-language root-marker check inside `warm_one/2` skips
  /// languages whose project marker is not present in cwd.
  WarmAll
}

/// Parse `pharos warm [--all | <lang>...]` style argv. Returns
/// `Some(WarmAll)` when `--all` is present (any position),
/// `Some(WarmExplicit(langs))` for an explicit lang list, and
/// `None` when `warm` is not the subcommand. Skips leading
/// argv positions that are flag-like (start with `-`) in case
/// the user passes other flags before the subcommand.
fn parse_warm_args(args: List(String)) -> Option(WarmRequest) {
  case skip_flags(args) {
    ["warm", ..rest] ->
      case list.contains(rest, "--all") {
        True -> Some(WarmAll)
        False -> Some(WarmExplicit(list.filter(rest, fn(a) { !is_flag(a) })))
      }
    _ -> None
  }
}

fn skip_flags(args: List(String)) -> List(String) {
  case args {
    [first, ..rest] ->
      case is_flag(first) {
        True -> skip_flags(rest)
        False -> args
      }
    [] -> []
  }
}

fn is_flag(arg: String) -> Bool {
  string.starts_with(arg, "-")
}

@external(erlang, "pharos_runtime_ffi", "init_stop")
fn init_stop() -> Nil

fn warm_one(pool_handle: pool.Pool, lang: String) -> Nil {
  case registry_for_language(lang) {
    Error(reason) -> {
      log.fields_at(
        "pharos/lsp/pool",
        entry.Warn,
        "warm: skipping language",
        [#("language", lang), #("reason", reason)],
      )
      Nil
    }
    Ok(config) ->
      case languages.primary_server(config) {
        Error(_) -> {
          log.fields_at(
            "pharos/lsp/pool",
            entry.Warn,
            "warm: language has no primary server",
            [#("language", lang)],
          )
          Nil
        }
        Ok(server) -> {
          case workspace_root.discover_from_dir(cwd_for_warmup(), config.root_markers) {
            Error(_) -> {
              log.fields_at(
                "pharos/lsp/pool",
                entry.Warn,
                "warm: no workspace root marker found near cwd",
                [#("language", lang), #("cwd", cwd_for_warmup())],
              )
              Nil
            }
            Ok(workspace) -> {
              let started_ms = system_time_ms()
              let spec = session.build_spawn_spec(workspace, config, server)
              case pool.get(pool_handle, config.id, workspace, spec) {
                Ok(_) ->
                  log.fields_at(
                    "pharos/lsp/pool",
                    entry.Info,
                    "warm: spawned LSP",
                    [
                      #("language", lang),
                      #("workspace", workspace),
                      #(
                        "elapsed_ms",
                        int_to_string(system_time_ms() - started_ms),
                      ),
                    ],
                  )
                Error(err) ->
                  log.fields_at(
                    "pharos/lsp/pool",
                    entry.Warn,
                    "warm: spawn failed",
                    [
                      #("language", lang),
                      #("workspace", workspace),
                      #("reason", describe_get_error(err)),
                    ],
                  )
              }
              Nil
            }
          }
        }
      }
  }
}

fn describe_get_error(err: pool.GetError) -> String {
  case err {
    pool.ProcStartFailed(reason) -> "spawn failed: " <> reason
    pool.ProbeFailed(reason) -> "probe failed: " <> reason
    pool.SpawnerCrashed(reason) -> "spawner crashed: " <> reason
  }
}

fn registry_for_language(lang: String) -> Result(languages.LanguageConfig, String) {
  let r = registry.cached()
  case dict.get(r, lang) {
    Ok(config) -> Ok(config)
    Error(_) -> Error("unknown language id (not in registry)")
  }
}

@external(erlang, "pharos_fs_ffi", "cwd")
fn cwd_for_warmup() -> String

@external(erlang, "erlang", "system_time")
fn system_time_raw(unit: ErlangTimeUnit) -> Int

type ErlangTimeUnit {
  Millisecond
}

fn system_time_ms() -> Int {
  system_time_raw(Millisecond)
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

fn split_csv(raw: String) -> List(String) {
  string.split(raw, ",")
  |> list.map(string.trim)
  |> list.filter(fn(s) { s != "" })
}

fn usage() -> String {
  "Usage: pharos [FLAG]

pharos is an MCP server bridging LLMs to LSP servers. Configuration
lives in TOML and environment variables — there are no runtime
configuration CLI flags.

Flags
  --version, -V              Print version and exit.
  --help, -h                 Print this usage and exit.
  --print-default-config     Print the canonical pharos.toml
                             starter file with comments. Redirect
                             into ~/.config/pharos/pharos.toml to
                             begin overriding defaults.
  --print-language-config <lang>
                             Print the bundled config for one
                             language as TOML — copy + edit the
                             output to override individual fields
                             via pharos.toml's `[languages.<id>]`
                             and `[[languages.<id>.servers]]` blocks.
                             Useful when the override is a JSON-string
                             field (initialization_options_json,
                             workspace_configuration_json) and you
                             want to start from the bundled default.
  --doctor                   Self-diagnostic. Resolves Config the
                             same way a normal boot does, probes
                             each language server's binary on PATH,
                             and reports anything that would break.
                             Doubles as a Burrito-cache warmup —
                             run once after install so the first
                             MCP host spawn is fast.
  --purge-cache              Remove Burrito's extracted ERTS+BEAM
                             payload. Next run re-extracts (~1-3s).
                             Does NOT remove the binary itself or
                             your config files.

Configuration sources (precedence: lower wins under higher)
  1. Compiled-in defaults
  2. ~/.config/pharos/pharos.toml             (global)
  3. .pharos.toml walked up from cwd          (project)
  4. PHAROS_* environment variables           (override)

See doc/example-pharos.toml in the source repo for the full schema."
}

const default_config_template: String = "# pharos configuration. Drop this file at
#   ~/.config/pharos/pharos.toml
# (global) or
#   ./.pharos.toml
# (project; walked up from cwd, beats global). Either is fully
# optional — pharos boots cleanly with no config file at all.
#
# Every key here is at its compiled-in default. Delete keys you do
# not want to override; uncomment and edit the rest.

# transport — \"stdio\" | \"http\" | \"both\". Most MCP hosts spawn
# pharos as a subprocess and speak stdio.
# transport = \"stdio\"

# tools — choose which MCP tools the LLM sees.
# Each entry is either a category alias (expands to a set) or a
# specific tool name. Mix freely. Default exposes everything.
#
#   \"read\"  — non-mutating LSP queries (17 tools):
#     hover, goto_definition, goto_type_definition,
#     goto_implementation, find_references, document_symbols,
#     workspace_symbols, signature_help,
#     call_hierarchy_prepare, call_hierarchy_incoming_calls,
#     call_hierarchy_outgoing_calls, get_diagnostics,
#     inlay_hints, semantic_tokens,
#     type_hierarchy_prepare, type_hierarchy_supertypes,
#     type_hierarchy_subtypes
#
#   \"write\" — edit-producing LSP tools (4 tools). The first three
#             return `WorkspaceEdit` data; `apply_workspace_edit`
#             writes a `WorkspaceEdit` to disk on demand
#             (`dry_run=true` by default):
#     rename_preview, format_document, code_actions,
#     apply_workspace_edit
#
#   \"debug\" — pharos runtime introspection (15 tools incl. echo):
#     echo, runtime_processes, runtime_supervision_tree,
#     runtime_ets_tables, runtime_memory, runtime_applications,
#     runtime_scheduler_util, runtime_pid_info,
#     runtime_log_tail, runtime_log_clear, runtime_log_level,
#     runtime_trace_lsp, runtime_trace_calls, runtime_kill_lsp,
#     runtime_language_config
#
#   \"raw\"   — power-user escape hatch (1 tool):
#     lsp_request_raw
#
# Examples:
#   tools = [\"read\"]                       # query-only agent
#   tools = [\"read\", \"write\"]              # full LSP surface
#   tools = [\"read\", \"runtime_log_tail\"]   # category + one extra
#   tools = [\"hover\", \"goto_definition\"]   # fully explicit
# tools = [\"read\", \"write\", \"debug\", \"raw\"]

[server.http]
# port — 0 lets the OS pick a free port. Pharos logs the bound
# port to stderr (and writes it to port_file if set).
# port = 3535

# bind — interface to bind on. Localhost-only by default.
# bind = \"127.0.0.1\"

# port_file — atomic write+rename of the bound port to a path.
# Headless callers read this file to discover where pharos landed.
# port_file = \"~/.cache/pharos/http-port\"

[log]
# filter — RUST_LOG-style spec. \"info\" by default; per-target
# overrides override the default level for matching prefixes.
#   PHAROS_LOG=info,pharos/lsp/proc=debug,pharos/lsp/trace=off
# filter = \"info\"

# file — append-only log file path. None disables file sink.
# file = \"~/.cache/pharos/log/pharos.log\"

# ring — keep an in-memory ring buffer feeding runtime_log_tail.
# ring = true

# stderr — also fan out to stderr. Required for foreground
# debugging; safe to disable when file sink is set.
# stderr = true

[lsp]
# trace — convenience flag for turning on the wire tracer at
# debug level. Equivalent to filter = \"...,pharos/lsp/trace=debug\".
# trace = false

[runtime]
# trace_calls_enabled — gates the runtime_trace_calls MCP tool
# (recon-backed). Off by default because raw module/function
# tracing has scheduler side effects.
# trace_calls_enabled = false

# [bridge]
# port — VSCode bridge listener port for the M7 extension.
# port = 31_337

# [languages.<id>] — per-language overrides. Two override shapes
# are accepted; mix freely.
#
# 1) Flat shape (legacy + simplest). Patches the primary (first)
# server of the language.
#
# [languages.rust]
# command = \"/opt/custom/rust-analyzer-nightly\"
#
# [languages.python]
# command = \"pyright-langserver\"
# args = [\"--stdio\"]
#
# 2) Per-server array of tables. Required to target a non-primary
# server (ruff in python) or to add a third server alongside the
# bundled defaults. Each entry merges into the default by id, or
# appends as a new server when the id is absent.
#
# [[languages.python.servers]]
# id = \"ruff\"
# command = \"/custom/path/to/ruff\"
#
# [[languages.python.servers]]
# id = \"mypy\"
# command = \"mypy\"
# args = [\"--strict\"]
# methods = [\"textDocument/diagnostic\"]
#
# Adding a brand-new language requires command + file_extensions
# at minimum. Either shape works:
#
# [languages.haskell]
# command = \"haskell-language-server-wrapper\"
# args = [\"--lsp\"]
# file_extensions = [\".hs\"]
# root_markers = [\"cabal.project\", \"stack.yaml\"]
# diagnostics_mode = \"push\"
#
# Or, equivalently, via the per-server array (useful when adding a
# brand-new language that ships multiple servers from day one):
#
# [languages.haskell]
# file_extensions = [\".hs\"]
# root_markers = [\"cabal.project\", \"stack.yaml\"]
#
# [[languages.haskell.servers]]
# id = \"hls\"
# command = \"haskell-language-server-wrapper\"
# args = [\"--lsp\"]
# diagnostics_mode = \"push\"

# [tool_config.<name>] — per-tool default_timeout_ms override.
# Every LSP-bound tool accepts `timeout_ms` per call; this is the
# fallback when the LLM does not pass one. Resolution order (later
# wins): compile-time default → this knob → per-tool x per-lang
# below → per-call `timeout_ms` argument.
#
# [tool_config.format_document]
# default_timeout_ms = 90000
#
# [tool_config.find_references]
# default_timeout_ms = 120000
#
# [tool_config.<name>.<lang>] — per-tool x per-language override.
# Same shape, narrower scope. Useful for heavy single-LSP cases
# without bumping defaults for everyone.
#
# [tool_config.find_references.java]
# default_timeout_ms = 120000
#
# [tool_config.workspace_symbols.go]
# default_timeout_ms = 90000
"
