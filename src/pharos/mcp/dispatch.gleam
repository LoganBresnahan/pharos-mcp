//// Per-line dispatch, shared by every MCP connection: the stdio
//// worker (direct mode) and each daemon connection (ADR-034).
////
//// Each inbound JSON-RPC line runs on its own unlinked process bound
//// to the connection's session, so `notifications/cancelled` is read
//// while the request it cancels is still in flight (M10), and every
//// lookup the request makes resolves through its own session.

import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json
import pharos/lsp/pool.{type Pool}
import pharos/mcp/request_workers.{type WriterMsg, WorkerDone, WriteResponse}
import pharos/mcp/server
import pharos/session_ctx.{type SessionCtx}

/// Spawn a dispatcher process for one inbound JSON-RPC line and
/// return immediately. The dispatcher registers its pid in the
/// `pharos_request_workers` ETS table keyed by the request's MCP id
/// (or the anonymous sentinel for parse errors / notifications),
/// runs `server.handle_line/2`, sends the reply back via the writer
/// Subject, and deregisters itself.
///
/// Returns the dispatcher's pid. The caller monitors it and counts
/// the request as finished on its DOWN, not on its reply: a cancel
/// kills the dispatcher before it can send anything.
pub fn spawn(
  pool_handle: Pool,
  session: SessionCtx,
  writer: Subject(WriterMsg),
  body: String,
) -> Pid {
  let mcp_id = peek_mcp_id(body)
  process.spawn_unlinked(fn() {
    session_ctx.bind(session)
    let worker_key = session_ctx.scoped(mcp_id)
    let self_pid = process.self()
    request_workers.insert(worker_key, self_pid)
    let result = server.handle_line(pool_handle, body)
    case result {
      server.Reply(json) ->
        request_workers.send_reply(writer, WriteResponse(json))
      server.ProtocolError(json) ->
        request_workers.send_reply(writer, WriteResponse(json))
      server.NoReply -> request_workers.send_reply(writer, WorkerDone)
    }
    request_workers.delete(worker_key)
  })
}

/// Decode just the `id` field out of an inbound JSON-RPC line. Used
/// to key the request-workers table so a follow-up
/// `notifications/cancelled` can find the dispatcher. Returns the
/// anonymous sentinel for parse errors and for notifications (no
/// `id` field).
fn peek_mcp_id(body: String) -> String {
  let decoder = {
    use id <- decode.optional_field("id", PeekNone, peek_id_decoder())
    decode.success(id)
  }
  case json.parse(body, decoder) {
    Ok(PeekInt(n)) -> int_to_text(n)
    Ok(PeekString(s)) -> s
    _ -> request_workers.anonymous_id
  }
}

type PeekedId {
  PeekInt(Int)
  PeekString(String)
  PeekNone
}

fn peek_id_decoder() -> decode.Decoder(PeekedId) {
  let int_dec = decode.int |> decode.map(PeekInt)
  let str_dec = decode.string |> decode.map(PeekString)
  decode.one_of(int_dec, [str_dec])
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_text(n: Int) -> String
