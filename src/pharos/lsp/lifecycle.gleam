//// LSP lifecycle: the `initialize` handshake.
////
//// Encapsulates the fixed sequence every LSP server expects:
////
////   client → server : initialize  (request, has id)
////   server → client : <response with matching id, includes capabilities>
////   client → server : initialized (notification, no id)
////
//// During the wait for the initialize response, the server may emit
//// progress notifications, log messages, etc. They are silently
//// drained — the loop only resolves when a response with the matching
//// id arrives or the read times out.
////
//// Per-LSP `initializationOptions` quirks (rust-analyzer's `cargo`
//// settings, tsserver's `typescript.tsdk`, etc.) will be merged into
//// the params object once `lsp/languages` lands; for Milestone 2 the
//// caller passes a pre-built params object directly.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{None, Some}
import gleam/result
import pharos/lsp/client.{type Client}
import pharos/lsp/server_request_handlers.{ErrorReply, Reply}

pub type RequestError {
  ClientFailure(client.Error)
  ResponseDecodeError(reason: String)
  ServerError(code: Int, message: String)
}

/// Backwards-compat alias — initialize was the first user of the
/// request/response correlation logic and named its error type
/// after itself. Keep the name available so older callers compile.
pub type InitializeError =
  RequestError

/// Run the initialize → initialized handshake against an LSP that has
/// just been spawned by `client.start`. Returns the same client (with
/// its buffer state advanced past the handshake messages) plus the
/// raw `result` value the server responded with — typically the
/// server's capabilities object.
///
/// `request_id` should be a number the caller knows is unused. v0.1
/// senders pass 0 because no other request has been sent on the
/// connection yet.
///
/// `init_params` is the JSON object to send as `params`. Build it
/// with `gleam/json.object(...)` to include `processId`, `rootUri`,
/// `capabilities`, `clientInfo`, and per-server
/// `initializationOptions`.
pub fn initialize(
  client: Client,
  request_id: Int,
  init_params: Json,
  timeout_ms: Int,
) -> Result(#(Client, Dynamic), RequestError) {
  use Nil <- result.try(send_initialize_request(
    client,
    request_id,
    init_params,
  ))

  use #(client, result_value) <- result.try(wait_for_response(
    client,
    request_id,
    timeout_ms,
  ))

  use Nil <- result.try(send_initialized_notification(client))

  Ok(#(client, result_value))
}

/// Generic JSON-RPC request: send method + params with the given id,
/// drain notifications and out-of-order responses, return the result
/// when a response with the matching id arrives. Caller is
/// responsible for picking unique request ids (a simple monotonic
/// counter is sufficient since the kept-warm pool is single-process
/// per workspace).
pub fn request(
  client: Client,
  method: String,
  params: Json,
  request_id: Int,
  timeout_ms: Int,
) -> Result(#(Client, Dynamic), RequestError) {
  use Nil <- result.try(send_method_request(
    client,
    method,
    params,
    request_id,
  ))

  wait_for_response(client, request_id, timeout_ms)
}

fn send_initialize_request(
  client: Client,
  id: Int,
  params: Json,
) -> Result(Nil, RequestError) {
  send_method_request(client, "initialize", params, id)
}

fn send_method_request(
  client: Client,
  method: String,
  params: Json,
  id: Int,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(id)),
      #("method", json.string(method)),
      #("params", params),
    ])
    |> json.to_string
    |> bit_array.from_string

  client.send_body(client, body)
  |> result.map_error(ClientFailure)
}

fn send_initialized_notification(
  client: Client,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("initialized")),
      #("params", json.object([])),
    ])
    |> json.to_string
    |> bit_array.from_string

  client.send_body(client, body)
  |> result.map_error(ClientFailure)
}

fn wait_for_response(
  client: Client,
  expected_id: Int,
  timeout_ms: Int,
) -> Result(#(Client, Dynamic), RequestError) {
  use #(body, client) <- result.try(
    client.next_message(client, timeout_ms)
    |> result.map_error(ClientFailure),
  )

  case classify(body) {
    ResponseOk(id: id, result: result_value) if id == expected_id ->
      Ok(#(client, result_value))

    ResponseErr(id: id, code: code, message: message) if id == expected_id ->
      Error(ServerError(code, message))

    ResponseOk(..) | ResponseErr(..) ->
      // Wrong id — almost certainly a stale or out-of-order response.
      // Keep looping; the matching one should arrive.
      wait_for_response(client, expected_id, timeout_ms)

    ServerRequest(id: id, method: method, params: params) -> {
      // Server-initiated request. Look up a handler in the Client's
      // registry; if found, send its reply. If not, reply with the
      // spec-default `-32601 Method not found` so the server proceeds
      // (degraded but not hung). Either way, continue waiting for the
      // response we were originally after.
      let _ = dispatch_server_request(client, id, method, params)
      wait_for_response(client, expected_id, timeout_ms)
    }

    Notification(method: _, params: _) ->
      // Server-side notification (progress, log, $/showMessage,
      // publishDiagnostics, etc.). Stage 0F starts tracking $/progress
      // tokens here. For now: drain and keep looking.
      wait_for_response(client, expected_id, timeout_ms)

    DecodeFailure(reason) -> Error(ResponseDecodeError(reason))
  }
}

/// Look up a handler for the inbound server-initiated request and
/// send its reply. If no handler is registered, reply with the
/// spec-default `-32601` (Method not found) per ADR-012 decision 2.
/// Either way, the original `wait_for_response` loop continues — the
/// server's request has been answered (or rejected); the response we
/// were originally waiting for should still arrive.
fn dispatch_server_request(
  client: Client,
  id: Int,
  method: String,
  params: Dynamic,
) -> Result(Nil, RequestError) {
  let registry = client.handlers(client)

  case server_request_handlers.lookup(registry, method) {
    Some(handler) -> send_handler_result(client, id, handler(id, params))
    None -> send_error_response(client, id, -32_601, "Method not found")
  }
}

fn send_handler_result(
  client: Client,
  id: Int,
  result: server_request_handlers.HandlerResult,
) -> Result(Nil, RequestError) {
  case result {
    Reply(payload) -> send_result_response(client, id, payload)
    ErrorReply(code: code, message: message) ->
      send_error_response(client, id, code, message)
  }
}

fn send_result_response(
  client: Client,
  id: Int,
  result: Json,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(id)),
      #("result", result),
    ])
    |> json.to_string
    |> bit_array.from_string

  client.send_body(client, body)
  |> result.map_error(ClientFailure)
}

fn send_error_response(
  client: Client,
  id: Int,
  code: Int,
  message: String,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(id)),
      #(
        "error",
        json.object([
          #("code", json.int(code)),
          #("message", json.string(message)),
        ]),
      ),
    ])
    |> json.to_string
    |> bit_array.from_string

  client.send_body(client, body)
  |> result.map_error(ClientFailure)
}

// -- Inbound message classification --------------------------------------

type Classified {
  ResponseOk(id: Int, result: Dynamic)
  ResponseErr(id: Int, code: Int, message: String)
  /// Server-initiated request: has both `id` and `method`. Server
  /// expects a response with the same id. Examples:
  /// `workspace/configuration`, `workspace/applyEdit`,
  /// `client/registerCapability`. See ADR-012.
  ServerRequest(id: Int, method: String, params: Dynamic)
  /// Server-side notification: has `method` but no `id`. Fire-and-
  /// forget; no response expected. Examples:
  /// `textDocument/publishDiagnostics`, `$/progress`,
  /// `window/logMessage`.
  Notification(method: String, params: Dynamic)
  DecodeFailure(reason: String)
}

fn classify(body: BitArray) -> Classified {
  case bit_array.to_string(body) {
    Error(Nil) -> DecodeFailure("body is not valid UTF-8")

    Ok(text) ->
      case json.parse(text, decode.dynamic) {
        Error(_) -> DecodeFailure("body is not valid JSON")
        Ok(value) -> classify_dynamic(value)
      }
  }
}

fn classify_dynamic(value: Dynamic) -> Classified {
  case decode.run(value, message_decoder()) {
    Ok(classified) -> classified
    // Decoder failure means none of the four shapes matched. Fall
    // through to a synthetic notification with no method so the
    // wait_for_response loop drains it as it would any other
    // unrecognized server message.
    Error(_) ->
      Notification(method: "", params: dynamic.nil())
  }
}

/// Classifies inbound JSON-RPC messages from the LSP into one of four
/// shapes per the JSON-RPC 2.0 spec:
///
/// | id present | method present | result/error present | shape           |
/// |------------|----------------|----------------------|-----------------|
/// | yes        | no             | yes                  | response (ok/err) |
/// | yes        | yes            | no                   | server-initiated request |
/// | no         | yes            | no                   | notification    |
///
/// Anything else is treated as a notification with an empty method
/// (drained by the receive loop).
fn message_decoder() -> decode.Decoder(Classified) {
  use maybe_id <- decode.optional_field("id", None, decode.optional(decode.int))
  use maybe_method <- decode.optional_field(
    "method",
    None,
    decode.optional(decode.string),
  )
  use maybe_result <- decode.optional_field(
    "result",
    None,
    decode.optional(decode.dynamic),
  )
  use maybe_error <- decode.optional_field(
    "error",
    None,
    decode.optional(error_object_decoder()),
  )
  use maybe_params <- decode.optional_field(
    "params",
    None,
    decode.optional(decode.dynamic),
  )

  let params = option.unwrap(maybe_params, dynamic.nil())

  case maybe_id, maybe_method, maybe_result, maybe_error {
    // Response (success): id + result, no method.
    Some(id), None, Some(result_value), _ ->
      decode.success(ResponseOk(id: id, result: result_value))

    // Response (error): id + error, no method.
    Some(id), None, _, Some(#(code, message)) ->
      decode.success(ResponseErr(id: id, code: code, message: message))

    // Server-initiated request: id + method.
    Some(id), Some(method), _, _ ->
      decode.success(ServerRequest(id: id, method: method, params: params))

    // Notification: method, no id.
    None, Some(method), _, _ ->
      decode.success(Notification(method: method, params: params))

    // Anything else: treat as notification with empty method.
    _, _, _, _ -> decode.success(Notification(method: "", params: params))
  }
}

fn error_object_decoder() -> decode.Decoder(#(Int, String)) {
  use code <- decode.field("code", decode.int)
  use message <- decode.field("message", decode.string)
  decode.success(#(code, message))
}
