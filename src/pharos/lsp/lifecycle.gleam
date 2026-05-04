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

    NotificationOrOther ->
      // Server-side notification (progress, log, $/showMessage, etc.).
      // Drain and keep looking.
      wait_for_response(client, expected_id, timeout_ms)

    DecodeFailure(reason) -> Error(ResponseDecodeError(reason))
  }
}

// -- Inbound message classification --------------------------------------

type Classified {
  ResponseOk(id: Int, result: Dynamic)
  ResponseErr(id: Int, code: Int, message: String)
  NotificationOrOther
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
  case decode.run(value, response_or_notification_decoder()) {
    Ok(classified) -> classified
    Error(_) -> NotificationOrOther
  }
}

fn response_or_notification_decoder() -> decode.Decoder(Classified) {
  use maybe_id <- decode.optional_field("id", None, decode.optional(decode.int))
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

  case maybe_id, maybe_result, maybe_error {
    Some(id), Some(result_value), _ ->
      decode.success(ResponseOk(id: id, result: result_value))

    Some(id), _, Some(#(code, message)) ->
      decode.success(ResponseErr(id: id, code: code, message: message))

    _, _, _ -> decode.success(NotificationOrOther)
  }
}

fn error_object_decoder() -> decode.Decoder(#(Int, String)) {
  use code <- decode.field("code", decode.int)
  use message <- decode.field("message", decode.string)
  decode.success(#(code, message))
}
