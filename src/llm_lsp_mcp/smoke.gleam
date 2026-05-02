//// Manual smoke test: run an LSP end-to-end against a real workspace.
////
//// This is the developer-facing verification that the Milestone 2
//// stack — Erlang Port, Content-Length framing, buffered client,
//// initialize handshake — actually works against a production LSP
//// server, not just /bin/cat. CI does not run this (rust-analyzer
//// cold start would push CI runtime past useful bounds and require
//// installing a Cargo workspace into the runner image); developers
//// run it locally to confirm a milestone before close.
////
//// Usage from the project root:
////
////     mix smoke -- /path/to/cargo/project
////
//// (or `mix run -e ":llm_lsp_mcp@smoke.run(\"/path/to/cargo/project\")"`)
////
//// The function spawns rust-analyzer with the workspace as cwd, runs
//// the initialize handshake, prints the server's capabilities to
//// stderr, drains incoming notifications for a few seconds (so you
//// can see `window/logMessage` and `$/progress` from rust-analyzer's
//// indexing), then sends shutdown + exit and tears down.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/json
import gleam/string
import llm_lsp_mcp/lsp/client
import llm_lsp_mcp/lsp/lifecycle
import llm_lsp_mcp/log

const rust_analyzer_path: String = "/home/oof/.cargo/bin/rust-analyzer"

const initialize_timeout_ms: Int = 30_000

const drain_window_ms: Int = 5000

pub fn run(workspace_path: String) -> Nil {
  log.info("smoke: spawning rust-analyzer for workspace " <> workspace_path)

  case client.start(rust_analyzer_path, [], workspace_path) {
    Error(err) -> {
      log.error("smoke: spawn failed: " <> describe_error(err))
      Nil
    }

    Ok(client) -> {
      log.info("smoke: subprocess up; sending initialize")
      let params = build_initialize_params(workspace_path)

      case lifecycle.initialize(client, 0, params, initialize_timeout_ms) {
        Error(lifecycle.ClientFailure(err)) -> {
          log.error(
            "smoke: initialize handshake transport error: "
            <> describe_error(err),
          )
          client.close(client)
        }

        Error(lifecycle.ResponseDecodeError(reason)) -> {
          log.error("smoke: initialize response decode error: " <> reason)
          client.close(client)
        }

        Error(lifecycle.ServerError(code, message)) -> {
          log.error(
            "smoke: server returned error during initialize: code="
            <> int.to_string(code)
            <> " message="
            <> message,
          )
          client.close(client)
        }

        Ok(#(client, capabilities)) -> {
          log.info("smoke: initialize OK")
          log.info(
            "smoke: server capabilities = "
            <> dynamic_to_string(capabilities),
          )
          drain_notifications(client, drain_window_ms)
          client.close(client)
          log.info("smoke: shut down")
        }
      }
    }
  }
}

fn build_initialize_params(workspace_path: String) -> json.Json {
  let root_uri = "file://" <> workspace_path

  json.object([
    #("processId", json.null()),
    #("rootUri", json.string(root_uri)),
    #(
      "rootPath",
      json.string(workspace_path),
    ),
    #("capabilities", json.object([])),
    #(
      "clientInfo",
      json.object([
        #("name", json.string("llm_lsp_mcp-smoke")),
        #("version", json.string("0.0.1")),
      ]),
    ),
    #("initializationOptions", json.object([])),
  ])
}

fn drain_notifications(client: client.Client, ms: Int) -> Nil {
  case ms <= 0 {
    True -> Nil
    False ->
      case client.next_message(client, 500) {
        Ok(#(body, client)) -> {
          log.info("smoke: notification: " <> body_preview(body))
          drain_notifications(client, ms - 500)
        }

        Error(client.PortReceiveError(_)) ->
          // Timeout in this 500ms window is fine; keep going.
          drain_notifications(client, ms - 500)

        Error(other) -> {
          log.warn("smoke: drain stopped: " <> describe_error(other))
          Nil
        }
      }
  }
}

fn body_preview(body: BitArray) -> String {
  case bit_array.to_string(body) {
    Ok(text) ->
      case string.length(text) > 200 {
        True -> string.slice(text, 0, 200) <> "..."
        False -> text
      }
    Error(Nil) -> "<binary body>"
  }
}

fn describe_error(err: client.Error) -> String {
  case err {
    client.PortReceiveError(_) -> "port receive error"
    client.PortSendError(_) -> "port send error"
    client.FramingError(_) -> "framing parse error"
    client.SpawnError(_) -> "spawn error"
  }
}

fn dynamic_to_string(value: Dynamic) -> String {
  string.inspect(value)
}
