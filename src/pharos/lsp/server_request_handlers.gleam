//// Server-initiated LSP request handlers.
////
//// LSP servers send their own JSON-RPC requests to the client (us)
//// for things like `workspace/configuration` (ask the client for
//// settings), `client/registerCapability` (announce a capability the
//// server now supports dynamically), `workspace/applyEdit` (request
//// the client write changes to files), and a handful of others. The
//// inbound classifier in `pharos/lsp/lifecycle` dispatches such
//// requests through this registry.
////
//// See ADR-012 for the design decisions:
////
////   - Per-LSP-Client default registry; per-call override stack
////   - Unknown method default: JSON-RPC `-32601` (Method not found)
////   - `workspace/applyEdit` default: decline (`{applied: false}`);
////     tools that need the edit override per-call
////
//// Stage 0E adds the `with_handler/4` scoped override API. Until
//// then, the registry is read-only after construction.
////
//// Handler signature:
////
////   fn(request_id, params) -> HandlerResult
////
//// The id is included even though most handlers ignore it because a
//// few (`window/showMessageRequest`) may want to use it for logging.
//// Params is the raw `Dynamic` from the JSON-RPC `params` field; each
//// handler decodes whichever sub-fields it cares about.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// Handler signature: the request id (rarely needed) and the raw
/// `params` Dynamic. Handlers return either a success `Reply` whose
/// JSON becomes the response's `result`, or an `ErrorReply` whose
/// fields populate the JSON-RPC error object.
pub type Handler =
  fn(Int, Dynamic) -> HandlerResult

pub type HandlerResult {
  Reply(Json)
  ErrorReply(code: Int, message: String)
}

/// Opaque so the registry's internal shape can change without
/// breaking callers. Use `new/0`, `defaults/0`, `insert/3`, and
/// `lookup/2` to interact with it.
pub opaque type Registry {
  Registry(handlers: Dict(String, Handler))
}

/// Empty registry. Useful for tests and for callers that explicitly
/// want no defaults.
pub fn new() -> Registry {
  Registry(handlers: dict.new())
}

/// Registry pre-populated with the six known server-request methods,
/// each pointing at the conservative default behavior for that method
/// per ADR-012:
///
///   - `workspace/configuration` → array of nulls, one per requested
///     item. Stage 0C overrides per-language to return real config.
///   - `client/registerCapability` → accept-noop (null result).
///   - `client/unregisterCapability` → accept-noop.
///   - `window/showMessageRequest` → null (no user available to ask).
///   - `window/workDoneProgress/create` → accept-noop. The actual
///     progress notifications still flow through the Notification
///     classifier branch; this handler just acknowledges that the
///     server may use the token.
///   - `workspace/applyEdit` → decline with
///     `{applied: false, failureReason: "not_supported"}`. Tools that
///     want to capture the edit override per-call.
pub fn defaults() -> Registry {
  new()
  |> insert("workspace/configuration", default_workspace_configuration)
  |> insert("client/registerCapability", default_accept_noop)
  |> insert("client/unregisterCapability", default_accept_noop)
  |> insert("window/showMessageRequest", default_accept_noop)
  |> insert("window/workDoneProgress/create", default_accept_noop)
  |> insert("workspace/applyEdit", default_decline_apply_edit)
}

pub fn insert(registry: Registry, method: String, handler: Handler) -> Registry {
  Registry(handlers: dict.insert(registry.handlers, method, handler))
}

pub fn lookup(registry: Registry, method: String) -> Option(Handler) {
  case dict.get(registry.handlers, method) {
    Ok(handler) -> Some(handler)
    Error(_) -> None
  }
}

// -- Default handlers ----------------------------------------------------

/// `client/registerCapability`, `client/unregisterCapability`,
/// `window/showMessageRequest`, `window/workDoneProgress/create` all
/// accept a null result as a valid acknowledgement. Used as the
/// default handler for each of those methods until a tool needs
/// finer-grained behavior.
fn default_accept_noop(_id: Int, _params: Dynamic) -> HandlerResult {
  Reply(json.null())
}

/// `workspace/applyEdit` default per ADR-012 decision 7. pharos is an
/// LLM bridge, not an autonomous editor — a server-initiated edit
/// reaching this default is one nobody asked for. Refuse explicitly.
/// Tools that want the edit (`rename_preview`, `code_actions`)
/// install a capture handler via Stage 0E's `with_handler` API.
fn default_decline_apply_edit(_id: Int, _params: Dynamic) -> HandlerResult {
  Reply(
    json.object([
      #("applied", json.bool(False)),
      #("failureReason", json.string("not_supported")),
    ]),
  )
}

/// `workspace/configuration` default. Server requests an array of
/// configuration values, one per item in `params.items`. Without a
/// per-language config (Stage 0C), reply with an array of nulls of
/// the same length so the spec's `result.length == items.length`
/// invariant holds.
fn default_workspace_configuration(_id: Int, params: Dynamic) -> HandlerResult {
  let item_count = case decode.run(params, configuration_items_decoder()) {
    Ok(items) -> list.length(items)
    Error(_) -> 0
  }

  let nulls = list.repeat(json.null(), item_count)
  Reply(json.preprocessed_array(nulls))
}

fn configuration_items_decoder() -> decode.Decoder(List(Dynamic)) {
  decode.field("items", decode.list(decode.dynamic), decode.success)
}

/// Build a `workspace/configuration` handler that answers each
/// requested item by looking up its `section` in the supplied
/// settings dict. Sections not present in the dict get `null`.
/// Stage 0C uses this to override the no-op default with real
/// per-language config (e.g. tsserver's `typescript` and `javascript`
/// section payloads). Suitable for `Registry.insert` after
/// `defaults/0` to keep the other defaults intact.
pub fn workspace_configuration_handler(
  settings: Dict(String, Json),
) -> Handler {
  fn(_id, params) -> HandlerResult {
    let sections = case decode.run(params, configuration_sections_decoder()) {
      Ok(s) -> s
      Error(_) -> []
    }

    let values =
      list.map(sections, fn(section) {
        case dict.get(settings, section) {
          Ok(value) -> value
          Error(_) -> json.null()
        }
      })

    Reply(json.preprocessed_array(values))
  }
}

fn configuration_sections_decoder() -> decode.Decoder(List(String)) {
  decode.field(
    "items",
    decode.list({
      use section <- decode.optional_field("section", "", decode.string)
      decode.success(section)
    }),
    decode.success,
  )
}
