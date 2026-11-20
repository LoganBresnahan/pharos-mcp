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
import gleam/erlang/atom
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pharos/log
import pharos/lsp/client.{type Client}
import pharos/lsp/diagnostics_cache
import pharos/lsp/port
import pharos/lsp/server_request_handlers.{
  type Handler, type LspId, ErrorReply, LspIdInt, LspIdString, Reply,
  lsp_id_to_json,
}

pub type RequestError {
  ClientFailure(client.Error)
  ResponseDecodeError(reason: String)
  ServerError(code: Int, message: String)
  /// The underlying `actor.call` panicked — typically because the
  /// callee `lsp_proc` died between pool returning a cached `Proc`
  /// and this tool worker dispatching its request. Recoverable: the
  /// tool layer evicts and respawns via
  /// `session.with_session_and_retry`. Without this typed error the
  /// tool worker exits abnormally and (under HTTP transport) mist
  /// returns 500 to the client. M14 follow-up.
  ActorCallPanic(reason: String)
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
/// `request_id` should be a number the caller knows is unused.
/// Callers typically pass 0 because `initialize` is the first
/// request on the connection; any id the caller knows is unused
/// works.
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
  use Nil <- result.try(send_initialize_request(client, request_id, init_params))

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
  use Nil <- result.try(send_method_request(client, method, params, request_id))

  wait_for_response(client, request_id, timeout_ms)
}

/// `request`, returning the client whatever the outcome, so a caller
/// that keeps the client (the proc) doesn't drop what was read behind an
/// error reply (#31).
pub fn request_keeping_client(
  client: Client,
  method: String,
  params: Json,
  request_id: Int,
  timeout_ms: Int,
) -> #(Client, Result(Dynamic, RequestError)) {
  case send_method_request(client, method, params, request_id) {
    Error(err) -> #(client, Error(err))
    Ok(Nil) ->
      wait_for_response_keeping(client, request_id, monotonic_ms() + timeout_ms)
  }
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

fn send_initialized_notification(client: Client) -> Result(Nil, RequestError) {
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

/// Wait until the server is ready to answer, before the proc accepts
/// requests (ADR-024, M10): a freshly spawned rust-analyzer answered the
/// first hover with `null` because it hadn't indexed yet.
///
/// Ready means one of:
/// - the configured `token` reports `end`;
/// - some progress was seen, nothing is still running (every token that
///   began has ended), and the server has been quiet for `settle_ms`;
/// - no progress arrived within `pre_begin_grace_ms` (an idle or already
///   indexed server sends none);
/// - `timeout_ms` ran out ("good enough": the request surfaces its own
///   error if not).
///
/// Every token counts, not only the configured one: rust-analyzer renamed
/// its indexing token to `rustAnalyzer/cachePriming`, and gopls names its
/// tokens per run. The old wait matched only the configured name, and its
/// grace check read the remaining budget, so with no match it waited out
/// the whole budget: about 59 s for every cold rust-analyzer, gopls and
/// pyright (#12). Notifications that arrive meanwhile take the normal path,
/// so a `publishDiagnostics` sent during the wait is cached instead of
/// dropped. Server requests are answered as usual.
pub fn wait_for_ready(
  client: Client,
  maybe_token: Option(String),
  timeout_ms: Int,
) -> Result(Client, RequestError) {
  case maybe_token {
    None -> Ok(client)
    Some(token) -> {
      let start = monotonic_ms()
      drain_until_ready(
        client,
        Readiness(
          token: token,
          start: start,
          deadline: start + timeout_ms,
          active: [],
          seen: False,
          last_change: start,
        ),
      )
    }
  }
}

/// The readiness wait's state: which progress tokens are running, whether
/// any was seen, and when the last one changed.
type Readiness {
  Readiness(
    token: String,
    start: Int,
    deadline: Int,
    active: List(String),
    seen: Bool,
    last_change: Int,
  )
}

const read_window_ms: Int = 200

const pre_begin_grace_ms: Int = 1500

const settle_ms: Int = 1000

fn drain_until_ready(
  client: Client,
  r: Readiness,
) -> Result(Client, RequestError) {
  let now = monotonic_ms()
  case now >= r.deadline || quiet_enough(r, now) {
    True -> Ok(client)
    False ->
      // The client comes back with a timeout too: a frame split across
      // read windows keeps its first part (#33).
      case client.next_message_keeping(client, read_window_ms) {
        #(client, Error(client.PortReceiveError(port.Timeout))) ->
          drain_until_ready(client, r)

        #(_, Error(other)) ->
          // Port closed or some other fatal transport error. Surface
          // it so the caller can give up cleanly instead of looping
          // through the whole timeout budget.
          Error(ClientFailure(other))

        #(client, Ok(body)) ->
          case classify(body) {
            Notification(method: method, params: params)
              if method == "$/progress"
            -> on_progress(client, r, params)

            Notification(method: method, params: params) -> {
              cache_publish_diagnostics(client, method, params)
              drain_until_ready(client, r)
            }

            ServerRequest(id: id, method: method, params: params) -> {
              let _ = dispatch_server_request(client, id, method, params)
              drain_until_ready(client, r)
            }

            _ -> drain_until_ready(client, r)
          }
      }
  }
}

fn quiet_enough(r: Readiness, now: Int) -> Bool {
  case r.seen {
    False -> now - r.start >= pre_begin_grace_ms
    True -> r.active == [] && now - r.last_change >= settle_ms
  }
}

fn on_progress(
  client: Client,
  r: Readiness,
  params: Dynamic,
) -> Result(Client, RequestError) {
  let now = monotonic_ms()
  // #30: recorded here too, so get_diagnostics knows this server reports
  // progress from its first sync on.
  record_progress(params)
  case decode.run(params, progress_token_and_kind_decoder()) {
    Ok(#(t, "end")) if t == r.token -> Ok(client)
    Ok(#(t, kind)) -> {
      let others = list.filter(r.active, fn(x) { x != t })
      let active = case kind {
        "begin" -> [t, ..others]
        "end" -> others
        _ -> r.active
      }
      drain_until_ready(
        client,
        Readiness(..r, active: active, seen: True, last_change: now),
      )
    }
    Error(_) -> drain_until_ready(client, r)
  }
}

/// A progress notification's token (a string or an integer, per the
/// spec) and its `value.kind`.
fn progress_token_and_kind_decoder() -> decode.Decoder(#(String, String)) {
  use token <- decode.field(
    "token",
    decode.one_of(decode.string, [decode.int |> decode.map(int.to_string)]),
  )
  use kind <- decode.subfield(["value", "kind"], decode.string)
  decode.success(#(token, kind))
}

fn monotonic_ms() -> Int {
  erlang_monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn erlang_monotonic_time(unit: atom.Atom) -> Int

/// Classify one frame body and dispatch any required reply. Used
/// by `pharos/lsp/proc`'s actor when raw Port messages arrive
/// outside of an in-flight `request` — the actor still needs to
/// answer server-emitted requests (workspace/configuration etc.)
/// and update the diagnostics cache, just without blocking on a
/// specific response id.
///
/// Returns the (possibly mutated) Client; never errors, because
/// classification failures and orphan responses are simply dropped.
pub fn classify_and_dispatch(
  client: Client,
  body: BitArray,
) -> Result(Client, RequestError) {
  case classify(body) {
    ServerRequest(id: id, method: method, params: params) -> {
      let _ = dispatch_server_request(client, id, method, params)
      Ok(client)
    }

    Notification(method: method, params: params) -> {
      cache_publish_diagnostics(client, method, params)
      Ok(client)
    }

    // Orphan responses (no in-flight request) and decode failures
    // drop silently. The actor just continues processing.
    _ -> Ok(client)
  }
}

/// Side-effect for `Notification` classifications: when the server
/// emits `textDocument/publishDiagnostics`, store the params keyed
/// by `(uri, server_id)` so the get_diagnostics tool can read them
/// on subsequent calls instead of waiting for a re-emit that may
/// never come (a server publishes when it has something new to say).
/// The `server_id` lives on the `Client` itself (1:1 with the LSP
/// subprocess) so multi-LSP languages (python = pyright + ruff)
/// cache each server's items independently without cross-overwrites.
/// A publish whose `version` is older than the text last synced is
/// not stored (ADR-038). Runs in the proc actor, the same process
/// that stamps each sync, so entry and sync stamps order exactly.
/// All other notification methods are dropped here; the caller's
/// loop continues draining.
fn cache_publish_diagnostics(
  client: Client,
  method: String,
  params: Dynamic,
) -> Nil {
  case method {
    "textDocument/publishDiagnostics" ->
      case decode.run(params, publish_diagnostics_key_decoder()) {
        Ok(#(uri, version)) ->
          diagnostics_cache.put_publish(
            uri,
            client.server_id(client),
            version,
            params,
          )
        Error(_) -> Nil
      }
    // #30: progress is recorded, so get_diagnostics can wait while the
    // server still works on a sync (cargo check after a save).
    "$/progress" -> record_progress(params)
    _ -> Nil
  }
}

fn record_progress(params: Dynamic) -> Nil {
  case decode.run(params, progress_token_and_kind_decoder()) {
    Ok(#(token, kind)) -> diagnostics_cache.progress(token, kind)
    Error(_) -> Nil
  }
}

fn publish_diagnostics_key_decoder() -> decode.Decoder(
  #(String, option.Option(Int)),
) {
  use uri <- decode.field("uri", decode.string)
  use version <- decode.optional_field(
    "version",
    option.None,
    decode.optional(decode.int),
  )
  decode.success(#(uri, version))
}

/// Send a JSON-RPC request whose `params` field is supplied as
/// already-encoded JSON text, await the matching response, and
/// return the verbatim result Dynamic. Used by the
/// `lsp_request_raw` escape hatch (Stage 1C) and by any future tool
/// that needs to round-trip an LSP-server-returned value (such as a
/// `CallHierarchyItem`) without re-decoding all its fields into a
/// typed `Json`.
pub fn request_raw_params(
  client: Client,
  method: String,
  params_json: String,
  request_id: Int,
  timeout_ms: Int,
) -> Result(#(Client, Dynamic), RequestError) {
  use Nil <- result.try(send_raw_method_request(
    client,
    method,
    params_json,
    request_id,
  ))

  wait_for_response(client, request_id, timeout_ms)
}

/// `request_raw_params`, returning the client whatever the outcome (#31).
pub fn request_raw_params_keeping_client(
  client: Client,
  method: String,
  params_json: String,
  request_id: Int,
  timeout_ms: Int,
) -> #(Client, Result(Dynamic, RequestError)) {
  case send_raw_method_request(client, method, params_json, request_id) {
    Error(err) -> #(client, Error(err))
    Ok(Nil) ->
      wait_for_response_keeping(client, request_id, monotonic_ms() + timeout_ms)
  }
}

fn send_raw_method_request(
  client: Client,
  method: String,
  params_json: String,
  id: Int,
) -> Result(Nil, RequestError) {
  // Build the JSON-RPC envelope as text so `params_json` (already-
  // encoded JSON) can pass through verbatim.
  let body_text =
    "{\"jsonrpc\":\"2.0\",\"id\":"
    <> int_to_string(id)
    <> ",\"method\":"
    <> json.to_string(json.string(method))
    <> ",\"params\":"
    <> params_json
    <> "}"

  client.send_body(client, bit_array.from_string(body_text))
  |> result.map_error(ClientFailure)
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(value: Int) -> String

/// Run `body` with `handler` installed for `method` in the Client's
/// server-request registry, then return whatever `body` produced.
/// Per ADR-012 decision 5 the override is scoped to the closure
/// body — Gleam's immutability does the popping automatically: the
/// `client` parameter visible to the caller still has its original
/// registry, and the `Client` value the body operated on is the
/// only one that carries the override.
///
/// Used by Tier 2 tools (e.g. `rename_preview`) to install a
/// capture handler for `workspace/applyEdit` while the
/// `textDocument/rename` LSP request is in flight, without polluting
/// the Client's persistent default registry.
///
/// Example:
///
/// ```gleam
/// let captured = process.new_subject()
/// let capture = fn(_id, params) {
///   process.send(captured, params)
///   server_request_handlers.Reply(applied_response_json())
/// }
///
/// lifecycle.with_handler(client, "workspace/applyEdit", capture, fn(c) {
///   lifecycle.request(c, "textDocument/rename", params, id, timeout)
/// })
/// ```
pub fn with_handler(
  client: Client,
  method: String,
  handler: Handler,
  body: fn(Client) -> a,
) -> a {
  let extended =
    client.handlers(client)
    |> server_request_handlers.insert(method, handler)

  body(client.with_handlers(client, extended))
}

/// Push a `workspace/didChangeConfiguration` notification with the
/// supplied settings as the `params.settings` payload. Per ADR-012
/// stage 0C, this is sent after `initialized` when the LanguageConfig
/// has a `workspace_configuration` populated. The notification has
/// no response (LSP-spec: notifications never get one), so the caller
/// continues immediately on success or surfaces a transport error.
pub fn push_configuration(
  client: Client,
  settings: Json,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("workspace/didChangeConfiguration")),
      #("params", json.object([#("settings", settings)])),
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
  let #(client, outcome) =
    wait_for_response_keeping(client, expected_id, monotonic_ms() + timeout_ms)
  result.map(outcome, fn(value) { #(client, value) })
}

/// `wait_for_response`, returning the client whatever the outcome: the
/// frames read behind an error reply (a publish, half a frame) live in
/// that client's buffer, and continuing with the client from before the
/// request dropped them (#31); so does half a frame read before a timeout
/// (#33). One `deadline` bounds the whole wait, so a server sending other
/// messages meanwhile can't extend it.
fn wait_for_response_keeping(
  client: Client,
  expected_id: Int,
  deadline: Int,
) -> #(Client, Result(Dynamic, RequestError)) {
  let left = int.max(deadline - monotonic_ms(), 0)
  case client.next_message_keeping(client, left) {
    #(client, Error(err)) -> #(client, Error(ClientFailure(err)))
    #(client, Ok(body)) ->
      case classify(body) {
        ResponseOk(id: id, result: result_value) if id == expected_id -> #(
          client,
          Ok(result_value),
        )

        ResponseErr(id: id, code: code, message: message)
          if id == expected_id
        -> #(client, Error(ServerError(code, message)))

        ResponseOk(..) | ResponseErr(..) ->
          // Wrong id — almost certainly a stale or out-of-order response
          // (the late reply to a request that timed out). Keep looping;
          // the matching one should arrive.
          wait_for_response_keeping(client, expected_id, deadline)

        ServerRequest(id: id, method: method, params: params) -> {
          let _ = dispatch_server_request(client, id, method, params)
          wait_for_response_keeping(client, expected_id, deadline)
        }

        Notification(method: method, params: params) -> {
          // Side-effect: cache publishDiagnostics so subsequent
          // get_diagnostics calls can return immediately even when the
          // server does not re-emit (ADR-038).
          cache_publish_diagnostics(client, method, params)
          wait_for_response_keeping(client, expected_id, deadline)
        }

        DecodeFailure(reason) -> #(client, Error(ResponseDecodeError(reason)))
      }
  }
}

fn dispatch_server_request(
  client: Client,
  id: LspId,
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
  id: LspId,
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
  id: LspId,
  result: Json,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", lsp_id_to_json(id)),
      #("result", result),
    ])
    |> json.to_string
    |> bit_array.from_string

  client.send_body(client, body)
  |> result.map_error(ClientFailure)
}

fn send_error_response(
  client: Client,
  id: LspId,
  code: Int,
  message: String,
) -> Result(Nil, RequestError) {
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", lsp_id_to_json(id)),
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
  /// expects a response with the same id (string OR integer per
  /// JSON-RPC 2.0). Examples: `workspace/configuration`,
  /// `workspace/applyEdit`, `client/registerCapability`,
  /// `window/workDoneProgress/create` (gleam-lsp issues this with
  /// a string id like `"create-token--downloading-dependencies"`).
  /// See ADR-012.
  ServerRequest(id: LspId, method: String, params: Dynamic)
  /// Server-side notification: has `method` but no `id`. Fire-and-
  /// forget; no response expected. Examples:
  /// `textDocument/publishDiagnostics`, `$/progress`,
  /// `window/logMessage`.
  Notification(method: String, params: Dynamic)
  DecodeFailure(reason: String)
}

fn classify(body: BitArray) -> Classified {
  case bit_array.to_string(body) {
    Ok(text) -> classify_text(text)
    // JSON-RPC mandates UTF-8 but some real-world LSP servers
    // (lua-language-server when filesystem paths include Latin-1
    // bytes; older PLS builds) emit responses with stray non-UTF-8
    // bytes inside JSON string fields. Strict rejection costs more
    // than spec compliance gains — fall back to a Latin-1
    // interpretation (always succeeds, every byte is a valid
    // codepoint) and retry the JSON parse. The first time this
    // fires for a given LSP, a warning is logged so the operator
    // knows their server is non-compliant.
    Error(Nil) ->
      case latin1_to_utf8(body) {
        Ok(text) -> {
          log_latin1_fallback_once()
          classify_text(text)
        }
        Error(_) -> DecodeFailure("body is not valid UTF-8 or Latin-1")
      }
  }
}

fn classify_text(text: String) -> Classified {
  case json.parse(text, decode.dynamic) {
    Error(_) -> DecodeFailure("body is not valid JSON")
    Ok(value) -> classify_dynamic(value)
  }
}

fn log_latin1_fallback_once() -> Nil {
  // Single-shot warning per BEAM lifetime (good enough — operators
  // see the gist; we don't spam logs on every response from a
  // chatty non-compliant LSP). Tracking per-LSP would require
  // threading proc identity through classify, which is invasive.
  case latin1_warned() {
    True -> Nil
    False -> {
      mark_latin1_warned()
      log.warn_at(
        "pharos/lsp/lifecycle",
        "LSP emitted non-UTF-8 response; falling back to Latin-1 (subsequent occurrences silenced)",
      )
    }
  }
}

@external(erlang, "pharos_runtime_ffi", "latin1_to_utf8")
fn latin1_to_utf8(body: BitArray) -> Result(String, Nil)

@external(erlang, "pharos_runtime_ffi", "latin1_warned_p")
fn latin1_warned() -> Bool

@external(erlang, "pharos_runtime_ffi", "mark_latin1_warned")
fn mark_latin1_warned() -> Nil

fn classify_dynamic(value: Dynamic) -> Classified {
  case decode.run(value, message_decoder()) {
    Ok(classified) -> classified
    // Decoder failure means none of the four shapes matched. Fall
    // through to a synthetic notification with no method so the
    // wait_for_response loop drains it as it would any other
    // unrecognized server message.
    Error(_) -> Notification(method: "", params: dynamic.nil())
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
fn lsp_id_decoder() -> decode.Decoder(LspId) {
  decode.one_of(decode.int |> decode.map(LspIdInt), [
    decode.string |> decode.map(LspIdString),
  ])
}

fn message_decoder() -> decode.Decoder(Classified) {
  use maybe_id <- decode.optional_field(
    "id",
    None,
    decode.optional(lsp_id_decoder()),
  )
  use maybe_method <- decode.optional_field(
    "method",
    None,
    decode.optional(decode.string),
  )
  // `result` key absent => None (request or notification, no
  // response). Key present with ANY value (including null) =>
  // Some(...). Wrapping with `decode.optional` would collapse
  // `result: null` into None, mis-classifying valid void
  // responses (e.g. textDocument/formatting with no edits) as
  // notifications and starving wait_for_response.
  use maybe_result <- decode.optional_field(
    "result",
    None,
    decode.map(decode.dynamic, Some),
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
    // Response (success): integer id + result, no method.
    // Pharos only ever sends integer ids on outbound requests, so a
    // response with a string id is anomalous; drop as notification.
    Some(LspIdInt(n)), None, Some(result_value), _ ->
      decode.success(ResponseOk(id: n, result: result_value))

    // Response (error): integer id + error, no method.
    Some(LspIdInt(n)), None, _, Some(#(code, message)) ->
      decode.success(ResponseErr(id: n, code: code, message: message))

    // Server-initiated request: id (int OR string) + method.
    Some(id), Some(method), _, _ ->
      decode.success(ServerRequest(id: id, method: method, params: params))

    // Notification: method, no id.
    None, Some(method), _, _ ->
      decode.success(Notification(method: method, params: params))

    // Anything else (including string-id responses, which we never
    // generate so should not see in practice): treat as
    // notification with empty method.
    _, _, _, _ -> decode.success(Notification(method: "", params: params))
  }
}

fn error_object_decoder() -> decode.Decoder(#(Int, String)) {
  use code <- decode.field("code", decode.int)
  use message <- decode.field("message", decode.string)
  decode.success(#(code, message))
}
