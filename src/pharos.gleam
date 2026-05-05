//// Library entry / facade for `pharos`.
////
//// `main/0` is the CLI entrypoint — invoked from Mix via the `start`
//// alias defined in mix.exs (`mix start`). Reads transport
//// configuration from environment variables and brings up the
//// requested transports, sharing one `Pool` across both:
////
////   - `PHAROS_TRANSPORT` — `stdio` | `http` | `both`
////     (default: `stdio`).
////   - `PHAROS_HTTP_PORT` — TCP port for the HTTP transport
////     (default: 3535). Ignored unless transport includes `http`.
////   - `PHAROS_HTTP_BIND` — interface to bind on (default:
////     `127.0.0.1`). Localhost-only by default; binding to a
////     non-loopback interface deliberately requires a config
////     change.
////
//// CLI-flag parsing is deferred to M9 — env vars cover the M5 use
//// cases and avoid taking a position on argv interpretation while
//// the binary still runs under `mix start` rather than its eventual
//// Burrito wrapper.

import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import pharos/env
import pharos/log
import pharos/lsp/diagnostics_cache
import pharos/lsp/pool.{type Pool}
import pharos/mcp/http
import pharos/mcp/server
import pharos/mcp/sessions
import pharos/mcp/stdio

const default_http_port: Int = 3535

const default_http_bind: String = "127.0.0.1"

type Transport {
  Stdio
  Http
  Both
}

pub fn main() -> Nil {
  let _writer = log.start_default()
  let transport = read_transport()
  log.info("pharos starting (transport=" <> transport_label(transport) <> ")")
  diagnostics_cache.init()
  case pool.start() {
    Error(_) -> {
      log.error("failed to start LSP pool; exiting")
      Nil
    }
    Ok(p) -> {
      log.info("LSP pool started")
      run(p, transport)
    }
  }
}

fn run(pool: Pool, transport: Transport) -> Nil {
  case transport {
    Stdio -> stdio_loop(pool)

    Http ->
      case start_http(pool) {
        Error(reason) -> {
          log.error("HTTP transport failed to start: " <> reason)
          pool.close_all(pool)
          Nil
        }
        Ok(_) -> {
          log.info("HTTP transport ready; idling main process")
          process.sleep_forever()
        }
      }

    Both ->
      case start_http(pool) {
        Error(reason) -> {
          log.error(
            "HTTP transport failed to start; falling back to stdio only: "
            <> reason,
          )
          stdio_loop(pool)
        }
        Ok(_) -> {
          log.info("HTTP transport ready; entering stdio loop")
          stdio_loop(pool)
        }
      }
  }
}

fn start_http(pool: Pool) -> Result(Nil, String) {
  let port = read_http_port()
  let bind = read_http_bind()
  log.info(
    "HTTP transport binding " <> bind <> ":" <> int.to_string(port),
  )

  case sessions.start() {
    Error(_) ->
      Error("failed to start MCP session table")

    Ok(sessions_handle) ->
      case http.start(pool, sessions_handle, port, bind) {
        Error(http.ListenFailed(reason)) -> Error(reason)
        Ok(_started) -> Ok(Nil)
      }
  }
}

fn stdio_loop(pool: Pool) -> Nil {
  case stdio.read_line() {
    stdio.StdinEof -> {
      log.info("stdin closed; shutting down LSP pool")
      pool.close_all(pool)
      Nil
    }

    stdio.StdinError(reason) -> {
      log.error("stdin read error: " <> reason)
      pool.close_all(pool)
      Nil
    }

    stdio.StdinLine(line) -> {
      let trimmed = stdio.trim_trailing_newline(line)
      case trimmed {
        "" -> Nil
        body ->
          case server.handle_line(pool, body) {
            server.Reply(json) -> stdio.write(json)
            server.NoReply -> Nil
            server.ProtocolError(json) -> stdio.write(json)
          }
      }
      stdio_loop(pool)
    }
  }
}

// -- Configuration reading ----------------------------------------------

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

fn transport_label(transport: Transport) -> String {
  case transport {
    Stdio -> "stdio"
    Http -> "http"
    Both -> "both"
  }
}
