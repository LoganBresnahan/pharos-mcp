//// LSP client wrapper: subprocess + framing + buffered I/O.
////
//// Combines `lsp/port` (raw byte I/O over an Erlang Port) with
//// `lsp/framing` (Content-Length parser) into a stream-oriented
//// API. Caller asks `next_message` for the next decoded JSON-RPC
//// body, send `send_body` for outgoing requests/notifications.
////
//// This module is the *frame-level* surface. JSON encoding/decoding
//// and request-response correlation by id live above (see
//// `lsp/lifecycle` for the initialize handshake; `lsp/pending` for
//// id tracking when actors land).
////
//// API is synchronous at Milestone 2. Caller blocks on
//// `next_message` with an explicit timeout. The buffered-message
//// queue ensures that a single port read returning multiple coalesced
//// frames is consumed one frame per call.

import gleam/bit_array
import llm_lsp_mcp/lsp/framing
import llm_lsp_mcp/lsp/port

pub opaque type Client {
  Client(
    port: port.Port,
    buffer: BitArray,
    queue: List(BitArray),
  )
}

pub type Error {
  PortReceiveError(port.ReceiveError)
  PortSendError(port.SendError)
  FramingError(framing.ParseError)
  SpawnError(port.SpawnError)
}

/// Spawn an LSP subprocess and prepare a client.
pub fn start(
  command: String,
  args: List(String),
  cwd: String,
) -> Result(Client, Error) {
  case port.spawn(command, args, cwd) {
    Ok(p) ->
      Ok(Client(port: p, buffer: <<>>, queue: []))
    Error(spawn_err) ->
      Error(SpawnError(spawn_err))
  }
}

/// Send a JSON-RPC body to the subprocess. Body is wrapped in
/// Content-Length framing automatically.
pub fn send_body(client: Client, body: BitArray) -> Result(Nil, Error) {
  let framed = framing.encode(body)
  case port.send(client.port, framed) {
    Ok(Nil) -> Ok(Nil)
    Error(send_err) -> Error(PortSendError(send_err))
  }
}

/// Block up to `timeout_ms` for the next complete frame from the
/// subprocess. Returns the decoded body (no framing headers) plus the
/// updated client. If a previous read returned multiple coalesced
/// frames, subsequent calls drain the queue before issuing a new read.
pub fn next_message(
  client: Client,
  timeout_ms: Int,
) -> Result(#(BitArray, Client), Error) {
  case client.queue {
    [first, ..rest] ->
      Ok(#(first, Client(..client, queue: rest)))

    [] -> read_until_message(client, timeout_ms)
  }
}

fn read_until_message(
  client: Client,
  timeout_ms: Int,
) -> Result(#(BitArray, Client), Error) {
  case port.receive_data(client.port, timeout_ms) {
    Error(receive_err) -> Error(PortReceiveError(receive_err))

    Ok(bytes) -> {
      let new_buffer = bit_array.append(client.buffer, bytes)
      case framing.parse(new_buffer) {
        Error(framing_err) -> Error(FramingError(framing_err))

        Ok(framing.Parsed(messages: [], buffer: leftover)) -> {
          // Got bytes but no complete frame yet. Keep buffering and
          // recurse — port may have more bytes ready, or this read
          // will time out and propagate the error up.
          let updated = Client(..client, buffer: leftover)
          read_until_message(updated, timeout_ms)
        }

        Ok(framing.Parsed(messages: [first, ..rest], buffer: leftover)) ->
          Ok(#(
            first,
            Client(..client, buffer: leftover, queue: rest),
          ))
      }
    }
  }
}

/// Tear down the subprocess. Idempotent.
pub fn close(client: Client) -> Nil {
  port.close(client.port)
}
