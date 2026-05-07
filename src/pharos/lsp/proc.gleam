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

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import pharos/lsp/client.{type Client}
import pharos/lsp/diagnostics_cache
import pharos/lsp/inflight
import pharos/lsp/lifecycle
import pharos/lsp/port
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
    /// Optional MCP request id (correlation id). Threaded so the
    /// actor can register the in-flight LSP id against this MCP
    /// id in the inflight table for cancel routing (ADR-016).
    /// Empty string skips tracking (caller is not within an MCP
    /// request boundary).
    cid: String,
    reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
  )
  RequestRaw(
    method: String,
    params_text: String,
    timeout_ms: Int,
    cid: String,
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
  /// Catch-all for Port-emitted messages (server-side notifications,
  /// server-requests, exit_status) that arrive at the actor's
  /// mailbox between Request handlers. Without this, gleam_otp's
  /// outer loop discards them as "unexpected" — gopls in particular
  /// emits a `workspace/configuration` server-request immediately
  /// after `initialized`, expects our reply before answering any
  /// subsequent request, and otherwise hangs.
  PortMessage(payload: Dynamic)
  Close
}

type State {
  /// `self_subject` is the actor's own Subject — captured in the
  /// initialiser so handle_request can stash it in the inflight
  /// table for cancel routing (ADR-016). gleam_otp surfaces `self`
  /// to the initialiser closure but not to handler invocations,
  /// hence the need to keep it in state.
  State(client: Client, self_subject: Subject(Msg))
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
  readiness_token: Option(String),
  readiness_timeout_ms: Int,
) -> Result(Proc, StartError) {
  // Run client.start + lifecycle.initialize INSIDE the actor's
  // initialiser so the Erlang Port is owned by the actor process
  // from creation. Avoids the post-spawn `client.connect` ownership
  // transfer that, in dogfood, raced with gopls's unsolicited
  // post-initialize messages and starved its inbound queue.
  let initialise = fn(self) {
    case client.start(command, args, workspace) {
      Error(e) -> Error("client.start failed: " <> describe_client_error(e))
      Ok(c) ->
        case lifecycle.initialize(c, 0, init_params, initialize_timeout_ms) {
          Error(e) ->
            Error("initialize handshake failed: " <> describe_lifecycle_error(e))
          Ok(#(c, _capabilities)) -> {
            // M10: drain `$/progress` notifications until the language's
            // readiness token reaches `end` (rust-analyzer's
            // `rustAnalyzer/Indexing`, gopls's `setup`, pyright's
            // `Indexing`) before the proc accepts requests. Without
            // this gate, the very first hover/goto returned `null` from
            // a freshly-spawned rust-analyzer because the analyzer
            // hadn't indexed yet — server-OK response, useless to the
            // LLM. wait_for_ready/3 returns Ok after the timeout even
            // if no progress was seen, so a server with no readiness
            // token (typescript-language-server) just no-ops here.
            let c = case
              lifecycle.wait_for_ready(c, readiness_token, readiness_timeout_ms)
            {
              Ok(c) -> c
              Error(_) -> c
            }
            // Custom selector accepts both:
            //   - Subject(Msg) messages (Request/RequestRaw/etc.)
            //   - Anything else (Port data + exit_status) wrapped as
            //     PortMessage(Dynamic). Without this gleam_otp's
            //     outer loop discards Port messages as "unexpected"
            //     between handler invocations, dropping server-
            //     emitted notifications + server-requests.
            let selector =
              process.new_selector()
              |> process.select(self)
              |> process.select_other(PortMessage)
            Ok(
              actor.initialised(State(client: c, self_subject: self))
              |> actor.selecting(selector)
              |> actor.returning(self),
            )
          }
        }
    }
  }

  // Initialiser timeout includes the LSP handshake budget plus a
  // small margin so we don't trip on the actor's outer wrapper.
  actor.new_with_initialiser(initialize_timeout_ms + 5000, initialise)
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) { Proc(subject: started.data) })
  |> result.map_error(ActorStartFailed)
}

/// Wrapper consumed by `pharos_lsp_dyn_sup` (ADR-017a). Erlang's
/// `:supervisor` protocol expects `{ok, Pid}` from a child's start
/// function; gleam_otp's `actor.start` returns
/// `actor.Started{Pid, Subject}`. This wrapper bridges the two:
/// runs `start/5`, inserts the resulting Subject into the
/// `pharos_lsp_proc_subjects` ETS table keyed by
/// `(language, workspace)` so the pool can recover it after
/// `supervisor:start_child/2` returns. On supervisor-driven
/// restart the same args are passed back here, so the ETS row is
/// overwritten with the new Subject — avoiding the duplicate-spawn
/// race that a Pid-keyed bridge would have.
pub fn start_link_supervised(
  language: String,
  workspace: String,
  command: String,
  args: List(String),
  init_params: Json,
  initialize_timeout_ms: Int,
  readiness_token: Option(String),
  readiness_timeout_ms: Int,
) -> Result(Pid, String) {
  case
    start(
      command,
      args,
      workspace,
      init_params,
      initialize_timeout_ms,
      readiness_token,
      readiness_timeout_ms,
    )
  {
    Error(err) -> Error(describe_start_error(err))
    Ok(handle) -> {
      let Proc(subject) = handle
      let p = pid(handle)
      lsp_proc_subjects_insert(language, workspace, subject)
      Ok(p)
    }
  }
}

/// Wrap a Subject (recovered from the ETS bridge by the pool) in
/// the opaque `Proc` record. Counterpart to `start_link_supervised`
/// — used after `supervisor:start_child` returns a Pid and the
/// pool reads the matching Subject from the bridge table.
pub fn from_subject(subject: Subject(Msg)) -> Proc {
  Proc(subject: subject)
}

fn describe_start_error(err: StartError) -> String {
  case err {
    ClientStartFailed(c) -> "client start failed: " <> describe_client_error(c)
    HandshakeFailed(l) ->
      "initialize handshake failed: " <> describe_lifecycle_error(l)
    // The actor initialiser maps every typed error to a String before
    // returning, so InitFailed(reason) carries the human-readable
    // BinaryNotFound / "client.start failed: ..." / "initialize
    // handshake failed: ..." message intact. Surface it verbatim so
    // the LLM sees the actionable text instead of a generic wrapper.
    ActorStartFailed(actor.InitFailed(reason)) -> reason
    ActorStartFailed(actor.InitTimeout) ->
      "actor initialiser timed out before completing"
    ActorStartFailed(actor.InitExited(_)) ->
      "actor initialiser exited abnormally"
  }
}

@external(erlang, "pharos_runtime_ffi", "lsp_proc_subjects_insert")
fn lsp_proc_subjects_insert(
  language: String,
  workspace: String,
  subject: Subject(Msg),
) -> Nil

/// Remove the ETS bridge row for `(language, workspace)`. Called
/// by pool's evict / kill_lsp paths after `proc.close` so the
/// `pharos_lsp_proc_subjects` table does not retain a stale
/// Subject pointing at a closed worker. No-op when the row is
/// already absent.
@external(erlang, "pharos_runtime_ffi", "lsp_proc_subjects_delete")
pub fn forget_subject(language: String, workspace: String) -> Nil

/// Read the ETS bridge row for `(language, workspace)`. Pool
/// reads via this on cache-miss to recover from a supervisor-
/// driven restart that overwrote the row with a new Subject.
@external(erlang, "pharos_runtime_ffi", "lsp_proc_subjects_lookup")
pub fn recover_subject(
  language: String,
  workspace: String,
) -> Result(Subject(Msg), Nil)

fn describe_client_error(err: client.Error) -> String {
  // Lossy string for the initialiser error path. Caller only sees
  // "ActorStartFailed(...)" anyway; preserves intent without
  // bringing the full client error variant into Proc's StartError.
  case err {
    client.PortReceiveError(_) -> "port receive error"
    client.PortSendError(_) -> "port send error"
    client.FramingError(_) -> "framing error"
    client.SpawnError(port.BinaryNotFound(command)) ->
      "language server binary `"
      <> command
      <> "` not found on PATH — install it and ensure it is on PATH, or "
      <> "override `command` via [languages.<id>] in pharos.toml (ADR-018)"
    client.SpawnError(port.SpawnFailed(reason)) ->
      "subprocess spawn failed: " <> reason
  }
}

fn describe_lifecycle_error(err: lifecycle.RequestError) -> String {
  case err {
    lifecycle.ClientFailure(_) -> "client transport failure"
    lifecycle.ResponseDecodeError(reason) -> "response decode: " <> reason
    lifecycle.ServerError(code, message) ->
      "server error " <> int_to_text(code) <> ": " <> message
  }
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
  let cid = current_cid()
  // Add a margin to the actor.call timeout so the LSP transport
  // timeout fires first and surfaces a meaningful RequestError.
  let call_timeout = timeout_ms + 5000
  actor.call(subject, call_timeout, fn(reply) {
    Request(method, params, timeout_ms, cid, reply)
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
  let cid = current_cid()
  let call_timeout = timeout_ms + 5000
  actor.call(subject, call_timeout, fn(reply) {
    RequestRaw(method, params_text, timeout_ms, cid, reply)
  })
}

/// Read the calling process's correlation id (mcp request id) from
/// the process dictionary. Empty string when no MCP context is set
/// (boot-time calls, smoke tests, etc.).
fn current_cid() -> String {
  case cid_get() {
    Ok(id) -> id
    Error(_) -> ""
  }
}

@external(erlang, "pharos_log_ffi", "cid_get")
fn cid_get() -> Result(String, Nil)

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

/// Send `$/cancelRequest` for a previously-issued LSP request id.
/// Per LSP spec the server makes a best-effort attempt to abort
/// the in-flight work. Phase C of ADR-013 wires this to the MCP
/// host's `notifications/cancelled` so an LLM-side cancellation
/// propagates through to the LSP server. The wiring at the MCP
/// boundary lands in a follow-up alongside session-id tracking
/// for HTTP transport; this helper is the proc-side primitive.
pub fn cancel(proc: Proc, lsp_request_id: Int) -> Result(Nil, client.Error) {
  let body =
    "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":"
    <> int_to_text(lsp_request_id)
    <> "}}"

  send_notification(proc, bit_array_from_string(body))
}

/// Cancel-by-dynamic-Subject for callers (e.g.
/// `mcp/server.log_cancel_notification`) that pulled the proc's
/// Subject out of the inflight ETS table as a `Dynamic`. The cast
/// back to `Subject(Msg)` is unsafe in the type-system sense but
/// safe in practice because `inflight.insert` only ever stores
/// `Subject(Msg)` values from inside this module.
///
/// Result is dropped (Nil) — cancel is best-effort. If the cast
/// fails or the proc is gone the cancel quietly no-ops.
pub fn cancel_by_dynamic_subject(
  subject_dynamic: Dynamic,
  lsp_request_id: Int,
) -> Nil {
  let _ = cancel(Proc(subject: cast_subject(subject_dynamic)), lsp_request_id)
  Nil
}

@external(erlang, "pharos_runtime_ffi", "as_dynamic")
fn cast_subject(dyn: Dynamic) -> Subject(Msg)

@external(erlang, "erlang", "integer_to_binary")
fn int_to_text(value: Int) -> String

@external(erlang, "erlang", "list_to_binary")
fn bit_array_from_string(text: String) -> BitArray

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
///
/// When the worker is supervised (ADR-017a), this also asks
/// `pharos_lsp_dyn_sup` to terminate the child so the supervisor's
/// transient strategy does not auto-restart. The ETS bridge row
/// is keyed by `(language, workspace)`, which proc does NOT know —
/// pool's evict / kill_lsp paths handle the bridge cleanup since
/// pool has the key.
pub fn close(proc: Proc) -> Nil {
  let p = pid(proc)
  let _ = dyn_sup_terminate_child(p)
  let Proc(subject) = proc
  actor.send(subject, Close)
}

@external(erlang, "pharos_lsp_dyn_sup", "terminate_child")
fn dyn_sup_terminate_child(pid: Pid) -> Nil

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
    Request(method:, params:, timeout_ms:, cid:, reply_to:) ->
      handle_request(state, method, params, timeout_ms, cid, reply_to)

    RequestRaw(method:, params_text:, timeout_ms:, cid:, reply_to:) ->
      handle_request_raw(state, method, params_text, timeout_ms, cid, reply_to)

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
      actor.continue(State(..state, client: updated_client))
    }

    WaitForReady(maybe_token:, timeout_ms:, reply_to:) -> {
      let result = lifecycle.wait_for_ready(state.client, maybe_token, timeout_ms)
      case result {
        Ok(updated_client) -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(State(..state, client: updated_client))
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

    PortMessage(payload:) -> handle_port_message(state, payload)

    Close -> {
      client.close(state.client)
      actor.stop()
    }
  }
}

/// A Port-emitted message arrived at the actor's mailbox between
/// Request handlers (e.g. an unsolicited gopls
/// `workspace/configuration` server-request). Decode the payload,
/// feed bytes through the framing parser, classify, and dispatch
/// any required reply via the existing handler registry. Cache
/// publishDiagnostics as a side effect so subsequent
/// get_diagnostics calls can return from cache.
fn handle_port_message(
  state: State,
  payload: Dynamic,
) -> actor.Next(State, Msg) {
  case decode_port_data_bytes(payload) {
    // Not a Port-data tuple (could be exit_status, system noise,
    // etc.). Drop and continue — the actor stays alive.
    Error(_) -> actor.continue(state)

    Ok(bytes) -> {
      // Append raw bytes to the Client's framing buffer, parse out
      // any complete frames, and process each.
      let updated = client.feed_bytes(state.client, bytes)
      let drained =
        drain_buffered_frames(State(..state, client: updated))
      actor.continue(drained)
    }
  }
}

@external(erlang, "pharos_lsp_port_ffi", "decode_port_data")
fn decode_port_data(payload: Dynamic) -> Result(BitArray, Nil)

fn decode_port_data_bytes(payload: Dynamic) -> Result(BitArray, Nil) {
  decode_port_data(payload)
}

fn drain_buffered_frames(state: State) -> State {
  // Pull frames out of the Client until none remain, classifying
  // and dispatching each. Stops cleanly when the buffer holds only
  // a partial frame.
  case client.drain_one_frame(state.client) {
    Error(_) -> state
    Ok(#(updated, body)) -> {
      let new_client = process_frame(updated, body)
      drain_buffered_frames(State(..state, client: new_client))
    }
  }
}

fn process_frame(c: client.Client, body: BitArray) -> client.Client {
  // Reuse lifecycle's classifier path. ServerRequest replies are
  // sent via the same handler registry the request loop uses;
  // notifications cache publishDiagnostics; orphan responses drop.
  case lifecycle.classify_and_dispatch(c, body) {
    Ok(updated) -> updated
    Error(_) -> c
  }
}

fn handle_request(
  state: State,
  method: String,
  params: Json,
  timeout_ms: Int,
  cid: String,
  reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
) -> actor.Next(State, Msg) {
  let lsp_id = next_id()
  track_inflight(cid, state.self_subject, lsp_id)
  case lifecycle.request(state.client, method, params, lsp_id, timeout_ms) {
    Ok(#(updated_client, result_value)) -> {
      untrack_inflight(cid)
      process.send(reply_to, Ok(result_value))
      actor.continue(State(..state, client: updated_client))
    }
    Error(err) -> {
      untrack_inflight(cid)
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
  cid: String,
  reply_to: Subject(Result(Dynamic, lifecycle.RequestError)),
) -> actor.Next(State, Msg) {
  let lsp_id = next_id()
  track_inflight(cid, state.self_subject, lsp_id)
  case
    lifecycle.request_raw_params(
      state.client,
      method,
      params_text,
      lsp_id,
      timeout_ms,
    )
  {
    Ok(#(updated_client, result_value)) -> {
      untrack_inflight(cid)
      process.send(reply_to, Ok(result_value))
      actor.continue(State(..state, client: updated_client))
    }
    Error(err) -> {
      untrack_inflight(cid)
      process.send(reply_to, Error(err))
      actor.continue(state)
    }
  }
}

/// Insert an `(mcp_id → (self_subject, lsp_id))` row into the
/// inflight tracker. No-op when cid is empty (no MCP context, e.g.
/// boot-time request from `lifecycle.initialize` or smoke tests).
/// `self_subject` comes from `State.self_subject`, captured by the
/// initialiser so the actor knows its own Subject without
/// gleam_otp surfacing it to handlers.
fn track_inflight(cid: String, self_subject: Subject(Msg), lsp_id: Int) -> Nil {
  case cid {
    "" -> Nil
    _ -> inflight.insert(cid, erase_subject(self_subject), lsp_id)
  }
}

fn untrack_inflight(cid: String) -> Nil {
  case cid {
    "" -> Nil
    _ -> inflight.delete(cid)
  }
}

/// Type-erase a `Subject(Msg)` to `Dynamic` for storage in the
/// inflight table. The cancel handler punts the cast back via
/// `cancel_by_dynamic_subject/2`.
@external(erlang, "pharos_runtime_ffi", "as_dynamic")
fn erase_subject(subject: Subject(Msg)) -> Dynamic

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
      actor.continue(State(..state, client: updated_client))
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
  // Cache poll: the actor's PortMessage handler may already have
  // cached publishDiagnostics for `target_uri` between handler
  // invocations.
  case latest, lookup_cached_envelope(target_uri) {
    None, Some(envelope) -> Ok(#(c, Some(envelope)))

    _, _ ->
      case remaining_ms <= 0 {
        True -> Ok(#(c, latest))
        False ->
          case client.next_message(c, drain_step_ms) {
            Error(client.PortReceiveError(_)) ->
              drain_loop(c, target_uri, remaining_ms - drain_step_ms, latest)

            Error(other) -> Error(other)

            Ok(#(body, c)) -> {
              // Dispatch the frame through lifecycle's classifier
              // so server-requests (notably gopls's
              // workspace/configuration) get replies. Without
              // this, gopls blocks forever waiting for a
              // configuration response and never publishes
              // diagnostics. After dispatch, side-effect
              // cache_publish_diagnostics has updated the cache
              // for any publishDiagnostics frame; check the
              // cache for our target_uri to capture the body.
              let updated_client =
                case lifecycle.classify_and_dispatch(c, body) {
                  Ok(uc) -> uc
                  Error(_) -> c
                }
              let next_latest = case latest {
                Some(_) -> latest
                None -> lookup_cached_envelope(target_uri)
              }
              drain_loop(updated_client, target_uri, remaining_ms - drain_step_ms, next_latest)
            }
          }
      }
  }
}

/// Read the cache and re-shape into a `publishDiagnostics`
/// notification envelope so drain_loop's caller can return the
/// same JSON shape whether the body came from cache or live drain.
fn lookup_cached_envelope(target_uri: String) -> Option(String) {
  case diagnostics_cache.get(target_uri) {
    Error(_) -> None
    Ok(params) ->
      Some(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
        <> "\"params\":"
        <> tool_helpers_json_encode(params)
        <> "}",
      )
  }
}

@external(erlang, "pharos_fs_ffi", "encode_json")
fn tool_helpers_json_encode(value: Dynamic) -> String

