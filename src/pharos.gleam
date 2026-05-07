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

import gleam/erlang/process.{type Pid}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import pharos/cli
import pharos/config.{type Config}
import pharos/log
import pharos/log/entry
import pharos/log/filter
import pharos/lsp/diagnostics_cache
import pharos/lsp/dyn_sup
import pharos/lsp/inflight
import pharos/lsp/registry
import pharos/mcp/request_workers
import pharos/supervisor as root_supervisor

const server_version: String = "0.0.1"

pub fn main() -> Nil {
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
          // Stdio/Both: stdio_worker drives termination via stdin
          // EOF. Http only: no stdio termination signal; sleep
          // until SIGTERM.
          process.sleep_forever()
        }
      }
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
  registry.init()
  inflight.init()
  request_workers.init()
  dyn_sup.init_subjects_bridge()

  let supervisor_config =
    root_supervisor.Config(
      transport: map_transport(cfg.transport),
      log_filter: build_log_filter(cfg),
      log_ring_enabled: cfg.log.ring_enabled,
      log_stderr_enabled: cfg.log.stderr_enabled,
      log_file_path: cfg.log.file,
      http_port: cfg.http.port,
      http_bind: cfg.http.bind,
    )

  case root_supervisor.start(supervisor_config) {
    Error(_) -> Error("root_supervisor.start returned an error")
    Ok(started) -> {
      register_root_supervisor(started.pid)
      Ok(started.pid)
    }
  }
}

@external(erlang, "pharos_runtime_ffi", "register_root_supervisor")
fn register_root_supervisor(pid: Pid) -> Nil

@external(erlang, "pharos_runtime_ffi", "find_root_supervisor")
fn find_root_supervisor() -> Result(Pid, Nil)

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
    Some(Doctor) -> {
      let _exit = cli.doctor()
      Handled
    }
    Some(PurgeCache) -> {
      let _exit = cli.purge_cache()
      Handled
    }
  }
}

type MetaFlag {
  VersionRequested
  HelpRequested
  PrintDefaultConfig
  Doctor
  PurgeCache
}

fn match_meta(args: List(String)) -> Option(MetaFlag) {
  list.fold_until(args, None, fn(_acc, arg) {
    case arg {
      "--version" | "-V" -> list.Stop(Some(VersionRequested))
      "--help" | "-h" -> list.Stop(Some(HelpRequested))
      "--print-default-config" -> list.Stop(Some(PrintDefaultConfig))
      "--doctor" -> list.Stop(Some(Doctor))
      "--purge-cache" -> list.Stop(Some(PurgeCache))
      _ -> list.Continue(None)
    }
  })
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
#   \"read\"  — non-mutating LSP queries (12 tools):
#     hover, goto_definition, goto_type_definition,
#     goto_implementation, find_references, document_symbols,
#     workspace_symbols, signature_help,
#     call_hierarchy_prepare, call_hierarchy_incoming_calls,
#     call_hierarchy_outgoing_calls, get_diagnostics
#
#   \"write\" — edit-producing LSP tools (3 tools, all return
#             WorkspaceEdit data; never auto-apply to disk):
#     rename_preview, format_document, code_actions
#
#   \"debug\" — pharos runtime introspection (14 tools incl. echo):
#     echo, runtime_processes, runtime_supervision_tree,
#     runtime_ets_tables, runtime_memory, runtime_applications,
#     runtime_scheduler_util, runtime_pid_info,
#     runtime_log_tail, runtime_log_clear, runtime_log_level,
#     runtime_trace_lsp, runtime_trace_calls, runtime_kill_lsp
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

# [languages.<id>] — per-language overrides. Replaces the legacy
# JSON registry. Only the fields you want to override need values.
#
# [languages.rust]
# command = \"/opt/custom/rust-analyzer-nightly\"
#
# [languages.python]
# command = \"pyright-langserver\"
# args = [\"--stdio\"]
#
# Adding a brand-new language requires command + file_extensions
# at minimum:
#
# [languages.haskell]
# command = \"haskell-language-server-wrapper\"
# args = [\"--lsp\"]
# file_extensions = [\".hs\"]
# root_markers = [\"cabal.project\", \"stack.yaml\"]
# diagnostics_mode = \"push\"
"
