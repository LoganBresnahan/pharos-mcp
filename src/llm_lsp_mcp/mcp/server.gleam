//// MCP protocol dispatch.
////
//// Pure-function dispatch for the milestone-1 echo server. Takes a
//// raw NDJSON line, decodes it, dispatches by method, returns the
//// JSON string to write back to stdout (or `Nil` for notifications,
//// which produce no response).
////
//// Tool registry is hardcoded inline — only `echo` exists. Real tool
//// dispatch with a registry abstraction lands in Milestone 4.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import llm_lsp_mcp/mcp/content_block
import llm_lsp_mcp/tools/tier1/diagnostics

const protocol_version: String = "2024-11-05"

const server_name: String = "llm_lsp_mcp"

const server_version: String = "0.0.1"

/// JSON-RPC request id — string or integer per spec.
pub type Id {
  IntId(Int)
  StringId(String)
}

/// Outcome of dispatching one inbound NDJSON line.
pub type DispatchResult {
  /// Send this JSON string back as a response on stdout.
  Reply(json: String)
  /// No reply — the inbound message was a notification.
  NoReply
  /// Inbound message was malformed; reply with a JSON-RPC error.
  ProtocolError(json: String)
}

/// Top-level entry: parse one inbound line and dispatch.
pub fn handle_line(line: String) -> DispatchResult {
  case json.parse(line, message_decoder()) {
    Ok(message) -> dispatch(message)
    Error(_) -> ProtocolError(error_response(None, -32_700, "Parse error"))
  }
}

// -- Inbound message classification --------------------------------------

type Message {
  RequestMessage(id: Id, method: String, params: Option(Dynamic))
  NotificationMessage(method: String, params: Option(Dynamic))
}

fn message_decoder() -> decode.Decoder(Message) {
  use method <- decode.field("method", decode.string)
  use maybe_id <- decode.optional_field("id", None, decode.optional(id_decoder()))
  use maybe_params <- decode.optional_field("params", None, decode.optional(decode.dynamic))
  case maybe_id {
    Some(id) -> decode.success(RequestMessage(id, method, maybe_params))
    None -> decode.success(NotificationMessage(method, maybe_params))
  }
}

fn id_decoder() -> decode.Decoder(Id) {
  decode.one_of(decode.int |> decode.map(IntId), [
    decode.string |> decode.map(StringId),
  ])
}

// -- Dispatch ------------------------------------------------------------

fn dispatch(message: Message) -> DispatchResult {
  case message {
    RequestMessage(id, "initialize", _params) -> Reply(initialize_response(id))
    RequestMessage(id, "tools/list", _params) -> Reply(tools_list_response(id))
    RequestMessage(id, "tools/call", params) ->
      Reply(handle_tool_call(id, params))
    RequestMessage(id, method, _) ->
      Reply(error_response(
        Some(id),
        -32_601,
        "Method not found: " <> method,
      ))

    NotificationMessage("initialized", _) -> NoReply
    NotificationMessage("notifications/cancelled", _) -> NoReply
    NotificationMessage(_, _) -> NoReply
  }
}

// -- initialize ----------------------------------------------------------

fn initialize_response(id: Id) -> String {
  success_response(id, fn() {
    json.object([
      #("protocolVersion", json.string(protocol_version)),
      #("capabilities", server_capabilities()),
      #(
        "serverInfo",
        json.object([
          #("name", json.string(server_name)),
          #("version", json.string(server_version)),
        ]),
      ),
    ])
  })
}

fn server_capabilities() -> Json {
  json.object([
    #("tools", json.object([#("listChanged", json.bool(False))])),
  ])
}

// -- tools/list ----------------------------------------------------------

fn tools_list_response(id: Id) -> String {
  success_response(id, fn() {
    json.object([
      #(
        "tools",
        json.array(
          [echo_tool_definition(), get_diagnostics_tool_definition()],
          of: fn(t) { t },
        ),
      ),
    ])
  })
}

fn get_diagnostics_tool_definition() -> Json {
  json.object([
    #("name", json.string("get_diagnostics")),
    #(
      "description",
      json.string(
        "Return LSP diagnostics (errors and warnings) for a Rust source file. "
          <> "Spawns rust-analyzer against the workspace containing the file "
          <> "(by walking up to the nearest Cargo.toml), opens the file, and "
          <> "returns the verbatim textDocument/publishDiagnostics body the "
          <> "server emits. Cold start is ~5-15 seconds for the LSP to index "
          <> "the project. Only Rust (.rs) files are supported in v0.1.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "uri",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "file:// URI of the Rust source file to inspect. "
                      <> "Example: file:///home/user/project/src/main.rs",
                  ),
                ),
              ]),
            ),
            #(
              "timeout_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Optional. How long to wait for diagnostics after the "
                      <> "LSP initialize handshake. Defaults to 8000ms.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["uri"], of: json.string)),
      ]),
    ),
  ])
}

fn echo_tool_definition() -> Json {
  json.object([
    #("name", json.string("echo")),
    #(
      "description",
      json.string(
        "Echo the supplied message back as a text content block. "
          <> "Smoke-test tool used to verify MCP plumbing.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "message",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("The message to echo back verbatim."),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["message"], of: json.string)),
      ]),
    ),
  ])
}

// -- tools/call ----------------------------------------------------------

fn handle_tool_call(id: Id, params: Option(Dynamic)) -> String {
  case decode_tool_call(params) {
    Ok(#("echo", arguments)) ->
      case decode_echo_arguments(arguments) {
        Ok(message) ->
          success_response(id, fn() { tool_text_result(message, False) })
        Error(reason) ->
          error_response(
            Some(id),
            -32_602,
            "Invalid params for echo: " <> reason,
          )
      }

    Ok(#("get_diagnostics", arguments)) -> handle_get_diagnostics(id, arguments)

    Ok(#(name, _)) ->
      error_response(Some(id), -32_602, "Unknown tool: " <> name)

    Error(reason) ->
      error_response(Some(id), -32_602, "Invalid tools/call params: " <> reason)
  }
}

fn handle_get_diagnostics(id: Id, arguments: Option(Dynamic)) -> String {
  case decode_get_diagnostics_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid params for get_diagnostics: " <> reason,
      )

    Ok(#(uri, timeout_ms)) ->
      case diagnostics.handle(uri, timeout_ms) {
        Ok(diagnostics.Diagnostics(uri: _, body_json: body)) ->
          success_response(id, fn() { tool_text_result(body, False) })

        Ok(diagnostics.NoDiagnosticsObserved(uri: u)) ->
          success_response(
            id,
            fn() {
              tool_text_result(
                "No textDocument/publishDiagnostics notification was received "
                  <> "for "
                  <> u
                  <> " within the timeout. The LSP may still be indexing, "
                  <> "or the file may have no diagnostics.",
                False,
              )
            },
          )

        Error(err) ->
          success_response(
            id,
            fn() { tool_text_result(describe_diagnostics_error(err), True) },
          )
      }
  }
}

fn decode_get_diagnostics_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use timeout_ms <- decode.optional_field(
      "timeout_ms",
      8000,
      decode.int,
    )
    decode.success(#(uri, timeout_ms))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `uri: string` (and optional `timeout_ms: int`)" })
}

fn describe_diagnostics_error(err: diagnostics.DiagnosticsError) -> String {
  case err {
    diagnostics.NotAFileUri(uri) -> "uri must start with file:// — got: " <> uri
    diagnostics.WorkspaceNotFound(uri) ->
      "no Cargo.toml found ascending from " <> uri
    diagnostics.SpawnFailed(reason) ->
      "rust-analyzer failed to spawn: " <> reason
    diagnostics.HandshakeFailed(reason) ->
      "LSP initialize handshake failed: " <> reason
    diagnostics.TransportFailed(reason) ->
      "LSP transport error: " <> reason
    diagnostics.UnsupportedFileType(uri) ->
      "v0.1 only supports .rs files; got: " <> uri
  }
}

fn decode_tool_call(
  params: Option(Dynamic),
) -> Result(#(String, Option(Dynamic)), String) {
  use raw <- result.try(option.to_result(params, "missing params"))
  let decoder = {
    use name <- decode.field("name", decode.string)
    use args <- decode.optional_field(
      "arguments",
      None,
      decode.optional(decode.dynamic),
    )
    decode.success(#(name, args))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "params shape did not match tools/call schema" })
}

fn decode_echo_arguments(args: Option(Dynamic)) -> Result(String, String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use message <- decode.field("message", decode.string)
    decode.success(message)
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `message: string` in arguments" })
}

fn tool_text_result(message: String, is_error: Bool) -> Json {
  let block = content_block.to_json(content_block.text(message))
  json.object([
    #("content", json.array([block], of: fn(b) { b })),
    #("isError", json.bool(is_error)),
  ])
}

// -- response building ---------------------------------------------------

fn success_response(id: Id, build_result: fn() -> Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_to_json(id)),
    #("result", build_result()),
  ])
  |> json.to_string
}

fn error_response(id: Option(Id), code: Int, message: String) -> String {
  let id_value = case id {
    Some(value) -> id_to_json(value)
    None -> json.null()
  }
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_value),
    #(
      "error",
      json.object([
        #("code", json.int(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json.to_string
}

fn id_to_json(id: Id) -> Json {
  case id {
    IntId(n) -> json.int(n)
    StringId(s) -> json.string(s)
  }
}

