//// MCP HTTP transport.
////
//// Single endpoint at `POST /mcp`. Body is one JSON-RPC 2.0 message;
//// response body is the corresponding reply (or an empty 204 for
//// notifications that produce no reply). No SSE, no batching, no
//// `Mcp-Session-Id` — Tier 1 is pure request/response and stateless,
//// so the simpler subset of MCP's Streamable HTTP transport is
//// sufficient. Server-initiated requests, sessions, and SSE arrive
//// alongside the bidirectional LSP dispatch in M8 stage 0
//// (see [adr/010-defer-server-request-handling.md]).
////
//// Coexists with `mcp/stdio` — the same `Pool` instance is shared
//// between both transports, so a tool call over HTTP and one over
//// stdio land on the same kept-warm LSP cache.
////
//// Origin-header validation is enabled to mitigate DNS-rebinding
//// attacks per the MCP spec. Default policy: allow no-Origin requests
//// (curl, native MCP clients), allow http(s)://localhost and
//// 127.0.0.1 / [::1] with any port, deny everything else.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import pharos/log
import pharos/lsp/pool.{type Pool}
import pharos/mcp/server
import pharos/mcp/sessions.{type Sessions}
import mist

/// Cap incoming bodies. A JSON-RPC message larger than this would
/// represent either a misbehaving client or an attempted resource
/// exhaustion; either way we refuse to read past the cap.
const max_body_bytes: Int = 4_194_304

pub type StartError {
  ListenFailed(reason: String)
}

/// Start a mist HTTP listener bound to `bind`:`port` that dispatches
/// `POST /mcp` to the shared MCP server with `pool`. The `sessions`
/// table issues a session id on the first `initialize` POST and
/// validates `Mcp-Session-Id` on every subsequent request.
pub fn start(
  pool: Pool,
  sessions: Sessions,
  port: Int,
  bind: String,
) -> Result(actor.Started(supervisor.Supervisor), StartError) {
  let handler = fn(req) { route(req, pool, sessions) }
  mist.new(handler)
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.start()
  |> result.map_error(fn(err) {
    ListenFailed("mist listener failed to start: " <> string.inspect(err))
  })
}

fn route(
  req: Request(mist.Connection),
  pool: Pool,
  sessions: Sessions,
) -> Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    Post, ["mcp"] -> handle_post(req, pool, sessions)
    Get, ["mcp"] -> method_not_allowed()
    _, _ -> not_found()
  }
}

fn handle_post(
  req: Request(mist.Connection),
  pool: Pool,
  sessions: Sessions,
) -> Response(mist.ResponseData) {
  case origin_allowed(req) {
    False -> {
      log.warn("rejecting POST /mcp with disallowed Origin header")
      forbidden()
    }
    True -> {
      case mist.read_body(req, max_body_bytes) {
        Error(_) -> bad_request("could not read request body")
        Ok(loaded) ->
          case bit_array.to_string(loaded.body) {
            Error(_) -> bad_request("body is not valid utf-8")
            Ok(body_text) -> handle_session(req, pool, sessions, body_text)
          }
      }
    }
  }
}

/// Decide whether this POST should issue a fresh session id (first
/// `initialize`) or be validated against an existing one. Per ADR-012
/// decision 3 the header is required from the second request onward;
/// missing or unknown id → 400.
fn handle_session(
  req: Request(mist.Connection),
  pool: Pool,
  sessions: Sessions,
  body_text: String,
) -> Response(mist.ResponseData) {
  case is_initialize(body_text) {
    True -> {
      let id = sessions.issue(sessions)
      log.info("issued session " <> id)
      with_session_id(dispatch(pool, body_text), id)
    }

    False ->
      case request.get_header(req, "mcp-session-id") {
        Error(_) -> bad_request("missing Mcp-Session-Id header")
        Ok(id) ->
          case sessions.validate(sessions, id) {
            False -> {
              log.warn("rejecting unknown Mcp-Session-Id " <> id)
              bad_request("unknown Mcp-Session-Id")
            }
            True -> dispatch(pool, body_text)
          }
      }
  }
}

fn dispatch(pool: Pool, body_text: String) -> Response(mist.ResponseData) {
  case server.handle_line(pool, body_text) {
    server.Reply(json) -> json_response(200, json)
    server.ProtocolError(json) -> json_response(200, json)
    server.NoReply -> empty_response(204)
  }
}

fn with_session_id(
  resp: Response(mist.ResponseData),
  id: String,
) -> Response(mist.ResponseData) {
  Response(..resp, headers: [#("mcp-session-id", id), ..resp.headers])
}

/// Fast pre-dispatch parse of just the JSON-RPC `method` field. Used
/// to gate session issuance on the protocol's `initialize` handshake
/// without parsing the full request twice (the MCP server below does
/// its own complete parse).
fn is_initialize(body_text: String) -> Bool {
  case json.parse(body_text, method_decoder()) {
    Ok(method) -> method == "initialize"
    Error(_) -> False
  }
}

fn method_decoder() -> decode.Decoder(String) {
  use method <- decode.optional_field("method", "", decode.string)
  decode.success(method)
}

// -- Origin validation ---------------------------------------------------

fn origin_allowed(req: Request(mist.Connection)) -> Bool {
  case request.get_header(req, "origin") {
    Error(_) -> True
    Ok(origin) -> is_local_origin(string.lowercase(origin))
  }
}

fn is_local_origin(origin: String) -> Bool {
  list.any(local_origin_prefixes(), fn(prefix) {
    string.starts_with(origin, prefix)
  })
}

fn local_origin_prefixes() -> List(String) {
  [
    "http://localhost", "https://localhost",
    "http://127.0.0.1", "https://127.0.0.1",
    "http://[::1]", "https://[::1]",
  ]
}

// -- Response builders ---------------------------------------------------

fn json_response(status: Int, body: String) -> Response(mist.ResponseData) {
  Response(
    status: status,
    headers: [#("content-type", "application/json")],
    body: mist.Bytes(bytes_tree.from_string(body)),
  )
}

fn empty_response(status: Int) -> Response(mist.ResponseData) {
  Response(status: status, headers: [], body: mist.Bytes(bytes_tree.new()))
}

fn bad_request(message: String) -> Response(mist.ResponseData) {
  Response(
    status: 400,
    headers: [#("content-type", "text/plain; charset=utf-8")],
    body: mist.Bytes(bytes_tree.from_string(message)),
  )
}

fn forbidden() -> Response(mist.ResponseData) {
  Response(
    status: 403,
    headers: [#("content-type", "text/plain; charset=utf-8")],
    body: mist.Bytes(bytes_tree.from_string("origin not allowed")),
  )
}

fn method_not_allowed() -> Response(mist.ResponseData) {
  Response(
    status: 405,
    headers: [#("allow", "POST"), #("content-type", "text/plain; charset=utf-8")],
    body: mist.Bytes(bytes_tree.from_string("method not allowed")),
  )
}

fn not_found() -> Response(mist.ResponseData) {
  Response(
    status: 404,
    headers: [#("content-type", "text/plain; charset=utf-8")],
    body: mist.Bytes(bytes_tree.from_string("not found")),
  )
}

// -- Used by the main entry to keep the BEAM alive when no stdio loop
// is running but the HTTP listener is. Mist's listener supervisor
// stays alive on its own; the entry process still needs something to
// block on.
pub fn block_forever() -> Nil {
  process.sleep_forever()
}
