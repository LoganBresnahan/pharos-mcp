//// Library entry / facade for `pharos`.
////
//// `main/0` is the CLI entrypoint — invoked from Mix via the `start`
//// alias defined in mix.exs (`mix start`). Reads transport
//// configuration from environment variables and brings up the
//// requested transports under a supervised tree (ADR-017):
////
////   - `PHAROS_TRANSPORT` — `stdio` | `http` | `both`
////     (default: `stdio`).
////   - `PHAROS_HTTP_PORT` — TCP port for the HTTP transport
////     (default: 3535; `0` = OS-assigns). Ignored unless transport
////     includes `http`.
////   - `PHAROS_HTTP_BIND` — interface to bind on (default:
////     `127.0.0.1`). Localhost-only by default; binding to a
////     non-loopback interface deliberately requires a config
////     change.
////
//// Supervisor handles every long-lived subsystem: log writer,
//// LSP pool, MCP sessions, HTTP listener, stdio worker. Crashes
//// in any one recover via the OTP restart strategy in
//// `pharos/supervisor.gleam` instead of taking down the BEAM.
////
//// CLI-flag parsing is deferred to M10 — env vars cover the M9
//// use cases and avoid taking a position on argv interpretation
//// while the binary still runs under `mix start` rather than its
//// eventual Burrito wrapper.

import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import pharos/env
import pharos/log
import pharos/log/entry
import pharos/log/filter
import pharos/lsp/diagnostics_cache
import pharos/lsp/dyn_sup
import pharos/lsp/inflight
import pharos/lsp/registry
import pharos/supervisor as root_supervisor

const default_http_port: Int = 3535

const default_http_bind: String = "127.0.0.1"

pub fn main() -> Nil {
  // Pre-supervisor init: idempotent ETS tables that supervised
  // children read or write. Order does not matter beyond "before
  // root_supervisor.start".
  diagnostics_cache.init()
  registry.init()
  inflight.init()
  dyn_sup.init_subjects_bridge()

  let transport = read_transport()
  let config =
    root_supervisor.Config(
      transport: map_transport(transport),
      log_filter: read_log_filter(),
      log_ring_enabled: read_bool_env("PHAROS_LOG_RING", default_value: True),
      log_stderr_enabled: read_bool_env("PHAROS_LOG_STDERR", default_value: True),
      log_file_path: read_optional_env("PHAROS_LOG_FILE"),
      http_port: read_http_port(),
      http_bind: read_http_bind(),
    )

  case root_supervisor.start(config) {
    Error(_) -> {
      log.error("root supervisor failed to start; exiting")
      Nil
    }
    Ok(_root) -> {
      log.info("pharos starting (transport=" <> transport_label(transport) <> ")")
      // Stdio/Both: stdio_worker drives termination via stdin
      // EOF. The supervisor's `transient` restart strategy on
      // stdio_worker means the worker exiting (clean EOF) does
      // NOT restart it; the root supervisor stays up but with
      // no driving process. Sleep_forever blocks main here;
      // either external SIGTERM or the supervisor itself shutting
      // down resolves the exit.
      //
      // Http only: no stdio termination signal; sleep_forever
      // until SIGTERM.
      process.sleep_forever()
    }
  }
}

fn map_transport(t: Transport) -> root_supervisor.Transport {
  case t {
    Stdio -> root_supervisor.Stdio
    Http -> root_supervisor.Http
    Both -> root_supervisor.Both
  }
}

// -- Configuration reading ----------------------------------------------

type Transport {
  Stdio
  Http
  Both
}

fn read_transport() -> Transport {
  case env.get("PHAROS_TRANSPORT") {
    None -> Stdio
    Some(raw) ->
      case string.lowercase(string.trim(raw)) {
        "stdio" -> Stdio
        "http" -> Http
        "both" -> Both
        other -> {
          log.warn(
            "unrecognized PHAROS_TRANSPORT=\""
            <> other
            <> "\"; falling back to stdio",
          )
          Stdio
        }
      }
  }
}

fn read_http_port() -> Int {
  case env.get("PHAROS_HTTP_PORT") {
    None -> default_http_port
    Some(raw) ->
      case int.parse(string.trim(raw)) {
        Ok(port) -> port
        Error(_) -> {
          log.warn(
            "PHAROS_HTTP_PORT=\""
            <> raw
            <> "\" is not a valid integer; using default "
            <> int.to_string(default_http_port),
          )
          default_http_port
        }
      }
  }
}

fn read_http_bind() -> String {
  case env.get("PHAROS_HTTP_BIND") {
    None -> default_http_bind
    Some(raw) -> {
      let trimmed = string.trim(raw)
      case trimmed {
        "" -> default_http_bind
        bind -> bind
      }
    }
  }
}

fn read_log_filter() -> filter.Filter {
  let spec = case env.get("PHAROS_LOG") {
    None -> ""
    Some(value) -> value
  }
  let parsed = filter.parse_spec(spec)
  case read_bool_env("PHAROS_TRACE_LSP", default_value: False) {
    False -> parsed
    True ->
      filter.Filter(
        default: parsed.default,
        overrides: [
          filter.Override("pharos/lsp/trace", Some(log_debug_level())),
          ..parsed.overrides
        ],
      )
  }
}

fn log_debug_level() -> entry.Level {
  entry.Debug
}

fn read_bool_env(name: String, default_value default: Bool) -> Bool {
  case env.get(name) {
    None -> default
    Some(raw) ->
      case raw {
        "0" -> False
        "off" -> False
        "false" -> False
        "no" -> False
        _ -> True
      }
  }
}

fn read_optional_env(name: String) -> Option(String) {
  case env.get(name) {
    None -> None
    Some("") -> None
    Some(value) -> Some(value)
  }
}

fn transport_label(transport: Transport) -> String {
  case transport {
    Stdio -> "stdio"
    Http -> "http"
    Both -> "both"
  }
}
