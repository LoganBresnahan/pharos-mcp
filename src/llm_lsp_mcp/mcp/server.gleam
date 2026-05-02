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
    json.object([#("tools", json.array([echo_tool_definition()], of: fn(t) { t }))])
  })
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

    Ok(#(name, _)) ->
      error_response(Some(id), -32_602, "Unknown tool: " <> name)

    Error(reason) ->
      error_response(Some(id), -32_602, "Invalid tools/call params: " <> reason)
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

