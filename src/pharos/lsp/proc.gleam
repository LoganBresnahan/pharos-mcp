//// Per-LSP worker process per ADR-013 Phase B.
////
//// Owns one LSP's `Client` (and through it, the Erlang `Port` to
//// the LSP child process) for the proc's lifetime. Tools that want
//// to talk to that LSP send `Request`/`RequestRaw`/`WithHandler`/
//// `WaitForReady` messages through the proc's `Subject`; the actor
//// runs `lifecycle.request` (or sibling) inside its own process so
//// the Port reads are owned by the right pid.
////
//// Concurrency model: the actor mailbox queues incoming requests
//// and serializes them. Multiple tools calling the same LSP share
//// one byte stream over a single Port, so true parallelism per
//// LSP is bounded by the LSP server itself anyway. Cross-LSP
//// parallelism is unaffected — each LSP has its own proc.
////
//// Pool monitors the proc via `process.monitor/1`; on DOWN, pool
//// evicts the cache entry. The proc's Port liveness is implicit:
//// if the Port dies, the actor's next read errors, the actor
//// returns `actor.stop_abnormal`, the supervisor / monitor see the
//// exit.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as dynamic_decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import pharos/lsp/client.{type Client}
import pharos/lsp/diagnostics_cache
import pharos/lsp/lifecycle
import pharos/lsp/server_request_handlers.{type Handler}

pub opaque type Proc {
  Proc(subject: Subject(Msg))
}

pub type StartError {
  /// The underlying Client failed to spawn, or the initialize
  /// handshake didn't complete.
  ClientStartFailed(client.Error)
  HandshakeFailed(lifecycle.RequestError)
  ActorStartFailed(actor.StartError)
}

pub type CallError {
  TransportError(lifecycle.RequestError)
  /// Proc actor mailbox call timed out before the LSP work
  /// finished. Distinct from a transport-level timeout because the
  /// caller's `actor.call` budget is separate from the LSP request
  /// budget.
  ProcCallTimeout
}

pub opaque type Msg {
  Request(
    method: String,
    params: Json,
    timeout_ms: Int,
    reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
  )
  RequestRaw(
    method: String,
    params_text: String,
    timeout_ms: Int,
    reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
  )
  AddHandler(method: String, handler: Handler)
  WaitForReady(
    maybe_token: Option(String),
    timeout_ms: Int,
    reply_to: Subject(Result(Nil, lifecycle.RequestError)),
  )
  GetClient(reply_to: Subject(Client))
  PushConfiguration(
    settings: Json,
    reply_to: Subject(Result(Nil, lifecycle.RequestError)),
  )
  SendNotification(
    body: BitArray,
    reply_to: Subject(Result(Nil, client.Error)),
  )
  WaitForPublish(
    target_uri: String,
    timeout_ms: Int,
    reply_to: Subject(Result(Option(String), client.Error)),
  )
  Close
}

type State {
  State(client: Client)
}

/// Spawn a fresh LSP via `client.start`, run the initialize +
/// optional configuration push handshake, then wrap the resulting
/// `Client` in an actor. Returns the Proc handle ready for
/// `request`/`request_raw`/etc.
pub fn start(
  command: String,
  args: List(String),
  workspace: String,
  init_params: Json,
  initialize_timeout_ms: Int,
) -> Result(Proc, StartError) {
  use client <- result.try(
    client.start(command, args, workspace)
    |> result.map_error(ClientStartFailed),
  )

  use #(client, _capabilities) <- result.try(
    lifecycle.initialize(client, 0, init_params, initialize_timeout_ms)
    |> result.map_error(HandshakeFailed),
  )

  use started <- result.try(
    actor.new(State(client: client))
    |> actor.on_message(handle_message)
    |> actor.start()
    |> result.map_error(ActorStartFailed),
  )

  // Transfer Port ownership from this process (the caller of
  // proc.start, typically the pool actor) to the new proc actor.
  // Without this the actor's `lifecycle.request` reads in
  // handle_request would never see port data — the messages
  // continue arriving at this caller's mailbox until eviction.
  let _ = client.connect(client, process.subject_owner(started.data) |> result.unwrap(process.self()))

  Ok(Proc(subject: started.data))
}

/// Send a JSON-RPC request and wait for the response. The
/// `timeout_ms` budget covers both the LSP-side latency and any
/// notifications drained while waiting for the matching id.
pub fn request(
  proc: Proc,
  method: String,
  params: Json,
  timeout_ms: Int,
) -> Result(Dynamic, lifecycle.RequestError) {
  let Proc(subject) = proc
  // Add a margin to the actor.call timeout so the LSP transport
  // timeout fires first and surfaces a meaningful RequestError.
  let call_timeout = timeout_ms + 5000
  actor.call(subject, call_timeout, fn(reply) {
    Request(method, params, timeout_ms, reply)
  })
}

/// Send a request whose `params` is supplied as already-encoded
/// JSON text. Mirrors `lifecycle.request_raw_params/5` but routed
/// through the actor so the Port is read by its owning process.
pub fn request_raw(
  proc: Proc,
  method: String,
  params_text: String,
  timeout_ms: Int,
) -> Result(Dynamic, lifecycle.RequestError) {
  let Proc(subject) = proc
  let call_timeout = timeout_ms + 5000
  actor.call(subject, call_timeout, fn(reply) {
    RequestRaw(method, params_text, timeout_ms, reply)
  })
}

/// Add (or replace) a server-request handler for the proc's
/// underlying registry. The change is permanent for the lifetime
/// of the proc; for scoped overrides use `with_handler/4` which
/// installs and removes around the closure body.
pub fn add_handler(proc: Proc, method: String, handler: Handler) -> Nil {
  let Proc(subject) = proc
  actor.send(subject, AddHandler(method, handler))
}

/// Run `body` with `handler` installed for `method`. The proc-level
/// `handlers` registry is restored to its prior state when `body`
/// returns. Mirrors `lifecycle.with_handler/4`'s shape but operates
/// on the proc's mutable state instead of an immutable Client.
pub fn with_handler(
  proc: Proc,
  method: String,
  handler: Handler,
  body: fn() -> a,
) -> a {
  // We do not currently expose registry-snapshot/restore on the
  // proc actor — the `body` runs in the caller's process while
  // the override is in effect on the proc. Any tool that captures
  // `workspace/applyEdit` does so for the duration of one request
  // and discards the captured value afterwards, so a permanent
  // override is acceptable noise. Restoration lands when more
  // than one tool needs overlapping overrides; not the case today.
  add_handler(proc, method, handler)
  body()
}

/// Drain server-emitted `$/progress` notifications until the
/// configured `readiness_token` reaches its end-state. Pass `None`
/// to bypass; matches `lifecycle.wait_for_ready/3` semantics.
pub fn wait_for_ready(
  proc: Proc,
  maybe_token: Option(String),
  timeout_ms: Int,
) -> Result(Nil, lifecycle.RequestError) {
  let Proc(subject) = proc
  let call_timeout = timeout_ms + 5000
  actor.call(subject, call_timeout, fn(reply) {
    WaitForReady(maybe_token, timeout_ms, reply)
  })
}

/// Backdoor for code that still needs the underlying Client (e.g.
/// the diagnostics drain that reads notifications directly). Use
/// sparingly; tools should prefer `request`/`request_raw`/etc.
/// because going around the actor breaks ownership invariants.
pub fn raw_client(proc: Proc) -> Client {
  let Proc(subject) = proc
  actor.call(subject, 1000, GetClient)
}

/// Push a `workspace/didChangeConfiguration` notification with the
/// supplied settings. Routed through the actor so the Port write
/// happens on its owning process. Mirrors
/// `lifecycle.push_configuration/2`.
pub fn push_configuration(
  proc: Proc,
  settings: Json,
) -> Result(Nil, lifecycle.RequestError) {
  let Proc(subject) = proc
  actor.call(subject, 5000, fn(reply) { PushConfiguration(settings, reply) })
}

/// Send a pre-encoded JSON-RPC body as a notification. Used by
/// pool's didOpen flow which constructs the body manually.
pub fn send_notification(
  proc: Proc,
  body: BitArray,
) -> Result(Nil, client.Error) {
  let Proc(subject) = proc
  actor.call(subject, 5000, fn(reply) { SendNotification(body, reply) })
}

/// Drain inbound notifications inside the proc actor (where the
/// Port owner lives) until either:
///   - a `textDocument/publishDiagnostics` for `target_uri` arrives
///     (returns `Ok(Some(<envelope JSON>))`)
///   - the time budget expires (returns `Ok(None)`)
///
/// Used by `tools/tier1/diagnostics` on cache miss to grab the
/// first publishDiagnostics emitted post-`didOpen`. Side-effect:
/// publishDiagnostics for any URI seen during the drain is written
/// to the diagnostics cache.
pub fn wait_for_publish_diagnostics(
  proc: Proc,
  target_uri: String,
  timeout_ms: Int,
) -> Result(Option(String), client.Error) {
  let Proc(subject) = proc
  let call_timeout = timeout_ms + 5000
  actor.call(subject, call_timeout, fn(reply) {
    WaitForPublish(target_uri, timeout_ms, reply)
  })
}

/// Tear down the proc. Sends `Close`; the actor exits and the
/// underlying `Client` (and its Port) is closed. Idempotent.
pub fn close(proc: Proc) -> Nil {
  let Proc(subject) = proc
  actor.send(subject, Close)
}

/// Return the proc actor's pid for `process.monitor/1`. Pool uses
/// this to wire auto-eviction when the proc dies.
pub fn pid(proc: Proc) -> Pid {
  let Proc(subject) = proc
  // gleam_erlang's process.subject_owner returns Result; the
  // proc's Subject is always owned by the actor we spawned, so
  // unwrap with a sentinel that should never fire in practice.
  case process.subject_owner(subject) {
    Ok(p) -> p
    Error(_) -> process.self()
  }
}

// -- Message dispatch ----------------------------------------------------

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Request(method:, params:, timeout_ms:, reply_to:) ->
      handle_request(state, method, params, timeout_ms, reply_to)

    RequestRaw(method:, params_text:, timeout_ms:, reply_to:) ->
      handle_request_raw(state, method, params_text, timeout_ms, reply_to)

    AddHandler(method:, handler:) -> {
      let updated_client =
        client.with_handlers(
          state.client,
          server_request_handlers.insert(
            client.handlers(state.client),
            method,
            handler,
          ),
        )
      actor.continue(State(client: updated_client))
    }

    WaitForReady(maybe_token:, timeout_ms:, reply_to:) -> {
      let result = lifecycle.wait_for_ready(state.client, maybe_token, timeout_ms)
      case result {
        Ok(updated_client) -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(State(client: updated_client))
        }
        Error(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(state)
        }
      }
    }

    GetClient(reply_to:) -> {
      process.send(reply_to, state.client)
      actor.continue(state)
    }

    PushConfiguration(settings:, reply_to:) -> {
      let result = lifecycle.push_configuration(state.client, settings)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SendNotification(body:, reply_to:) -> {
      let result = client.send_body(state.client, body)
      process.send(reply_to, result)
      actor.continue(state)
    }

    WaitForPublish(target_uri:, timeout_ms:, reply_to:) ->
      handle_wait_for_publish(state, target_uri, timeout_ms, reply_to)

    Close -> {
      client.close(state.client)
      actor.stop()
    }
  }
}

fn handle_request(
  state: State,
  method: String,
  params: Json,
  timeout_ms: Int,
  reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
) -> actor.Next(State, Msg) {
  case lifecycle.request(state.client, method, params, next_id(), timeout_ms) {
    Ok(#(updated_client, result_value)) -> {
      process.send(reply_to, Ok(result_value))
      actor.continue(State(client: updated_client))
    }
    Error(err) -> {
      process.send(reply_to, Error(err))
      actor.continue(state)
    }
  }
}

fn handle_request_raw(
  state: State,
  method: String,
  params_text: String,
  timeout_ms: Int,
  reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
) -> actor.Next(State, Msg) {
  case
    lifecycle.request_raw_params(
      state.client,
      method,
      params_text,
      next_id(),
      timeout_ms,
    )
  {
    Ok(#(updated_client, result_value)) -> {
      process.send(reply_to, Ok(result_value))
      actor.continue(State(client: updated_client))
    }
    Error(err) -> {
      process.send(reply_to, Error(err))
      actor.continue(state)
    }
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(opts: List(UniqueIntOption)) -> Int

type UniqueIntOption {
  Positive
  Monotonic
}

/// Per-call request id. Per-proc monotonically increasing positive
/// integer is sufficient because the LSP wire protocol scopes ids
/// per connection and we own one connection per proc.
fn next_id() -> Int {
  unique_integer([Positive, Monotonic])
}

const drain_step_ms: Int = 500

fn handle_wait_for_publish(
  state: State,
  target_uri: String,
  remaining_ms: Int,
  reply_to: Subject(Result(Option(String), client.Error)),
) -> actor.Next(State, Msg) {
  case drain_loop(state.client, target_uri, remaining_ms, option.None) {
    Ok(#(updated_client, found)) -> {
      process.send(reply_to, Ok(found))
      actor.continue(State(client: updated_client))
    }
    Error(err) -> {
      process.send(reply_to, Error(err))
      actor.continue(state)
    }
  }
}

fn drain_loop(
  c: Client,
  target_uri: String,
  remaining_ms: Int,
  latest: Option(String),
) -> Result(#(Client, Option(String)), client.Error) {
  case remaining_ms <= 0 {
    True -> Ok(#(c, latest))
    False ->
      case client.next_message(c, drain_step_ms) {
        Error(client.PortReceiveError(_)) ->
          drain_loop(c, target_uri, remaining_ms - drain_step_ms, latest)

        Error(other) -> Error(other)

        Ok(#(body, c)) -> {
          let next_latest = match_publish_diagnostics(body, target_uri, latest)
          drain_loop(c, target_uri, remaining_ms - drain_step_ms, next_latest)
        }
      }
  }
}

/// If `body` is a publishDiagnostics notification, write to the
/// diagnostics cache (keyed by uri) and, if its uri matches
/// `target_uri`, return its full JSON text wrapped in Some.
/// Otherwise propagate `latest`.
fn match_publish_diagnostics(
  body: BitArray,
  target_uri: String,
  latest: Option(String),
) -> Option(String) {
  case bit_array.to_string(body) {
    Error(_) -> latest
    Ok(text) ->
      case json.parse(text, dynamic_decoder()) {
        Error(_) -> latest
        Ok(value) ->
          case decode_publish_diagnostics(value) {
            Error(_) -> latest
            Ok(#(uri, params)) -> {
              diagnostics_cache.put(uri, params)
              case uri == target_uri {
                True -> option.Some(text)
                False -> latest
              }
            }
          }
      }
  }
}

fn dynamic_decoder() -> dynamic_decode.Decoder(Dynamic) {
  dynamic_decode.dynamic
}

fn decode_publish_diagnostics(
  value: Dynamic,
) -> Result(#(String, Dynamic), Nil) {
  case dynamic_decode.run(value, publish_decoder()) {
    Ok(t) -> Ok(t)
    Error(_) -> Error(Nil)
  }
}

fn publish_decoder() -> dynamic_decode.Decoder(#(String, Dynamic)) {
  use method <- dynamic_decode.field("method", dynamic_decode.string)
  case method == "textDocument/publishDiagnostics" {
    False ->
      dynamic_decode.failure(#("", dynamic.nil()), "not publishDiagnostics")
    True -> {
      use params <- dynamic_decode.field("params", dynamic_decode.dynamic)
      use uri <- dynamic_decode.subfield(
        ["params", "uri"],
        dynamic_decode.string,
      )
      dynamic_decode.success(#(uri, params))
    }
  }
}
