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
import gleam/erlang/process.{type Pid}
import pharos/lsp/framing
import pharos/lsp/instance_track
import pharos/lsp/port
import pharos/lsp/server_request_handlers.{type Registry}
import pharos/lsp/trace

pub opaque type Client {
  Client(
    port: port.Port,
    buffer: BitArray,
    queue: List(BitArray),
    handlers: Registry,
    /// Identifier of the LSP server this client speaks to. 1:1 with
    /// the subprocess; used by lifecycle's diagnostics-cache writer
    /// to key publishDiagnostics by `(uri, server_id)` so multi-LSP
    /// languages do not cross-overwrite each other in the cache.
    server_id: String,
    /// OS PID of the spawned LSP subprocess, captured at `start/4`
    /// via `pharos_instance_track_ffi:register_lsp/4`. Used by
    /// `close/1` to remove the corresponding tracking file under
    /// `~/.local/share/pharos/instances/<pharos-pid>/`. 0 indicates
    /// the PID could not be read (port already closed or test
    /// construction path); deregister is a no-op in that case.
    lsp_pid: Int,
  )
}

/// Read the LSP server id this client is bound to.
pub fn server_id(c: Client) -> String {
  c.server_id
}

/// Update the LSP server id on the client. Used by callers that
/// recover a Client without server_id available at construction
/// time and want to backfill it before lifecycle wires the cache.
pub fn set_server_id(c: Client, id: String) -> Client {
  Client(..c, server_id: id)
}

pub type Error {
  PortReceiveError(port.ReceiveError)
  PortSendError(port.SendError)
  FramingError(framing.ParseError)
  SpawnError(port.SpawnError)
}

/// Spawn an LSP subprocess and prepare a client. `server_id` is
/// the LSP id from the language registry (e.g. `"pyright"`,
/// `"ruff"`); lifecycle's diagnostics-cache writer keys
/// publishDiagnostics by `(uri, server_id)` so it must reach the
/// Client at construction. When the caller does not yet know it
/// (legacy paths), pass an empty string and backfill via
/// `set_server_id/2` before any frame is dispatched.
pub fn start(
  command: String,
  args: List(String),
  cwd: String,
  server_id: String,
) -> Result(Client, Error) {
  case port.spawn(command, args, cwd) {
    Ok(p) -> {
      // ADR-030 S3: drop a tracking file under
      // `~/.local/share/pharos/instances/<pharos-pid>/` so the
      // `pharos cleanup` subcommand can reap this LSP if pharos
      // exits non-gracefully. Best-effort — returns 0 if port_info
      // cannot read the os_pid, in which case `close/1` will
      // no-op the deregister.
      let lsp_pid = instance_track.register_lsp(p, server_id, command, cwd)
      Ok(Client(
        port: p,
        buffer: <<>>,
        queue: [],
        handlers: server_request_handlers.defaults(),
        server_id: server_id,
        lsp_pid: lsp_pid,
      ))
    }
    Error(spawn_err) ->
      Error(SpawnError(spawn_err))
  }
}

/// Replace the client's server-request handler registry. Used by the
/// language registry to attach per-language defaults (Stage 0C) and
/// by tools that want process-wide overrides. Per-call scoped
/// overrides are added separately in Stage 0E.
pub fn with_handlers(client: Client, handlers: Registry) -> Client {
  Client(..client, handlers: handlers)
}

/// Read access for the lifecycle inbound classifier. Internal-ish but
/// public so `pharos/lsp/lifecycle` can dispatch ServerRequest
/// classifications without reaching into the opaque struct's fields.
pub fn handlers(client: Client) -> Registry {
  client.handlers
}

/// Send a JSON-RPC body to the subprocess. Body is wrapped in
/// Content-Length framing automatically.
pub fn send_body(client: Client, body: BitArray) -> Result(Nil, Error) {
  let framed = framing.encode(body)
  trace.out(framed)
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
      trace.incoming(bytes)
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

/// Append externally-received bytes to the framing buffer without
/// blocking on a port read. Used by the proc actor when raw Port
/// messages arrive via its mailbox selector instead of through the
/// blocking `next_message` path. Returns the updated Client; any
/// complete frames now sit in `queue` ready for `drain_one_frame`.
pub fn feed_bytes(client: Client, bytes: BitArray) -> Client {
  trace.incoming(bytes)
  let new_buffer = bit_array.append(client.buffer, bytes)
  case framing.parse(new_buffer) {
    Error(_) ->
      // Malformed bytes mid-stream. Keep accumulating; the next
      // chunk may complete the frame, or the parser stays unhappy
      // and we let drain_one_frame surface it later.
      Client(..client, buffer: new_buffer)

    Ok(framing.Parsed(messages: messages, buffer: leftover)) -> {
      let combined_queue = list_append(client.queue, messages)
      Client(..client, buffer: leftover, queue: combined_queue)
    }
  }
}

@external(erlang, "lists", "append")
fn list_append(a: List(a), b: List(a)) -> List(a)

/// Pop one fully-buffered frame off the queue without doing any
/// Port I/O. Companion to `feed_bytes` for the actor's
/// inbound-message dispatch loop. Returns `Error(Nil)` when no
/// complete frame is currently buffered.
pub fn drain_one_frame(client: Client) -> Result(#(Client, BitArray), Nil) {
  case client.queue {
    [first, ..rest] -> Ok(#(Client(..client, queue: rest), first))
    [] -> Error(Nil)
  }
}

/// Tear down the subprocess. Idempotent. Also removes the
/// `~/.local/share/pharos/instances/<pharos-pid>/<lsp-pid>.pid`
/// tracking file written by `instance_track.register_lsp` so a
/// subsequent `pharos cleanup` does not see this LSP as an orphan.
pub fn close(client: Client) -> Nil {
  instance_track.deregister_lsp(client.lsp_pid)
  port.close(client.port)
}

/// Transfer the underlying Port's ownership to `new_owner`. After
/// this call, the new owner receives all `{Port, {data, _}}` and
/// `{Port, {exit_status, _}}` messages — `next_message/2` invoked by
/// the new owner will succeed; invoked by anyone else, it will hang
/// until timeout.
///
/// Must be called by the current owner (the process that called
/// `start/3` or the previous owner of a transferred Port). Used by
/// the LSP pool to hand a Client over to the tool process that will
/// consume from it.
pub fn connect(client: Client, new_owner: Pid) -> Result(Nil, Nil) {
  port.connect(client.port, new_owner)
}
