//// Kept-warm LSP pool.
////
//// One actor owns a cache of `(language, workspace) -> Proc`. Tools
//// call `get/4` to fetch a Proc; on cache miss the pool spawns
//// a fresh `lsp_proc` (which itself runs the initialize handshake)
//// and stashes it. On cache hit the pool returns the existing
//// Proc immediately — cold-start cost is paid once per (language,
//// workspace) per session, not per tool call.
////
//// M9 Phase B: pool monitors each `Proc` via `process.monitor`. On
//// the proc's exit (DOWN), pool evicts the cache entry so the
//// next tool call respawns transparently. ADR-013 calls this
//// "structure-by-supervision, communication-by-monitoring."
////
//// At Milestone 4 the pool was in-process and lived for the
//// duration of `mix start`. Phase A's supervisor scaffolding does
//// not yet wrap the pool; Phase C adds tool-level retry that
//// transparently respawns on transport error in addition to the
//// auto-evict here.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import pharos/log
import pharos/lsp/proc.{type Proc}
import pharos/lsp/server_request_handlers

pub opaque type Pool {
  Pool(subject: Subject(Msg))
}

pub type SpawnSpec {
  SpawnSpec(
    command: String,
    args: List(String),
    init_params: json.Json,
    /// Optional `workspace/didChangeConfiguration` payload pushed
    /// post-`initialized`. Also used to answer the server's pull-style
    /// `workspace/configuration` requests via a per-language handler
    /// override on the Proc. Keyed by section name (e.g.
    /// `"typescript"`, `"javascript"`); each section's value is the
    /// JSON the server wants for that scope. `None` means the server
    /// gets neither push nor per-language pull-handler. See ADR-012.
    workspace_configuration: option.Option(dict.Dict(String, json.Json)),
  )
}

pub type GetError {
  ProcStartFailed(reason: String)
}

pub type StartError {
  StartFailedActor(actor.StartError)
}

pub opaque type Msg {
  Get(
    language: String,
    workspace: String,
    spec: SpawnSpec,
    reply_to: Subject(Result(Proc, GetError)),
  )
  Evict(language: String, workspace: String)
  CloseAll
  EnsureOpen(
    language: String,
    workspace: String,
    uri: String,
    language_id: String,
    content: String,
    reply_to: Subject(Result(Nil, EnsureOpenError)),
  )
  /// Sent to the pool actor when one of its monitored procs exits.
  /// `reason` is included for diagnostic logging; pool just evicts
  /// the cache entry regardless of why.
  ProcDown(monitor_ref: process.Monitor, reason: dynamic.Dynamic)
  /// Operator-requested kill via `kill_lsp/3`. Same mechanics as
  /// `Evict` but synchronous so the caller learns whether the
  /// (language, workspace) was cached.
  KillLsp(
    language: String,
    workspace: String,
    reply_to: Subject(KillStatus),
  )
}

pub type EnsureOpenError {
  /// No LSP cached for this (language, workspace) — caller must
  /// `get/4` first to spawn one.
  NoCachedClient
  /// `proc.send_notification` returned an error — the LSP
  /// subprocess is gone or its Port is closed.
  SendFailed
}

type State {
  State(
    cache: Dict(#(String, String), Proc),
    /// Reverse index from monitor ref to cache key, so when a
    /// `ProcDown` arrives we can find which entry to evict.
    monitors: Dict(process.Monitor, #(String, String)),
    opened: Set(#(String, String, String)),
  )
}

const initialize_timeout_ms: Int = 30_000

const default_call_timeout_ms: Int = 60_000

/// Spawn the pool. Returns a handle the rest of the program shares
/// for `get/4`, `evict/3`, and `close_all/1`.
///
/// The actor is built via `new_with_initialiser` so the selector
/// can be extended with `select_monitors`, routing Erlang `DOWN`
/// messages from `process.monitor/1` (set in `handle_get` for each
/// spawned proc) into the `ProcDown` variant. Without this hook
/// gleam_otp's outer loop discards DOWN messages as "unexpected"
/// and the cache never auto-evicts.
pub fn start() -> Result(Pool, StartError) {
  start_internal()
  |> result.map(fn(started) {
    let pool = Pool(subject: started.data)
    register_global(started.data)
    pool
  })
  |> result.map_error(StartFailedActor)
}

/// Supervised entry point — spawns the pool with the same wiring
/// as `start/0` but returns the `actor.Started` shape that
/// `static_supervisor.add(supervision.worker(...))` consumes
/// (ADR-017). Registers the Subject in `persistent_term` so
/// `pool.global/0` finds it.
pub fn start_supervised() -> Result(
  actor.Started(Subject(Msg)),
  actor.StartError,
) {
  case start_internal() {
    Ok(started) -> {
      register_global(started.data)
      Ok(started)
    }
    Error(e) -> Error(e)
  }
}

fn start_internal() -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  let initialise = fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(monitor: m, reason: r, ..) ->
            ProcDown(monitor_ref: m, reason: process_reason_as_dynamic(r))
          process.PortDown(monitor: m, reason: r, ..) ->
            ProcDown(monitor_ref: m, reason: process_reason_as_dynamic(r))
        }
      })
    Ok(
      actor.initialised(State(
        cache: dict.new(),
        monitors: dict.new(),
        opened: set.new(),
      ))
      |> actor.selecting(selector)
      |> actor.returning(self),
    )
  }

  actor.new_with_initialiser(default_call_timeout_ms, initialise)
  |> actor.on_message(handle_message)
  |> actor.start()
}

/// Read the supervised pool's Subject from persistent_term. Tool
/// callers use this in place of being passed the `Pool` from main
/// (ADR-017). Returns an error if the pool has not been started
/// yet (e.g. tests bypassing the supervisor entirely).
pub fn global() -> Result(Pool, Nil) {
  case lookup_global() {
    Ok(subject) -> Ok(Pool(subject: subject))
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "pharos_runtime_ffi", "pool_register")
fn register_global(subject: Subject(Msg)) -> Nil

@external(erlang, "pharos_runtime_ffi", "pool_lookup")
fn lookup_global() -> Result(Subject(Msg), Nil)

@external(erlang, "pharos_runtime_ffi", "as_dynamic")
fn coerce_to_dynamic(x: a) -> dynamic.Dynamic

fn process_reason_as_dynamic(reason: process.ExitReason) -> dynamic.Dynamic {
  // ExitReason is an opaque enum; coerce its term verbatim into
  // Dynamic so the existing ProcDown logging path can format it
  // without caring about the variant shape.
  coerce_to_dynamic(reason)
}

/// Fetch a `Proc` for the given language and workspace, spawning a
/// fresh LSP if none is cached.
pub fn get(
  pool: Pool,
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Proc, GetError) {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    Get(language, workspace, spec, reply)
  })
}

/// Drop the cached entry for one (language, workspace). Tool layer
/// can call this on transport error before retrying. The Proc is
/// closed (which kills its Port and the LSP child).
pub fn evict(pool: Pool, language: String, workspace: String) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, Evict(language, workspace))
}

pub type KillStatus {
  Killed
  NotFound
}

/// Operator-requested kill of one LSP. Identical mechanics to
/// `evict/3` (close the Proc, drop the cache entry) but routed
/// through a sync call so the caller can confirm whether anything
/// was actually killed. Used by the `runtime_kill_lsp` MCP tool;
/// the LLM gets a meaningful "killed" vs "no such cached LSP"
/// response instead of a fire-and-forget cast.
pub fn kill_lsp(
  pool: Pool,
  language: String,
  workspace: String,
) -> KillStatus {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    KillLsp(language, workspace, reply)
  })
}

/// Close every cached LSP. Called on graceful shutdown.
pub fn close_all(pool: Pool) -> Nil {
  let Pool(subject) = pool
  actor.send(subject, CloseAll)
}

/// Ensure the cached LSP for (language, workspace) has been told
/// about this document via `textDocument/didOpen`. Idempotent — if
/// the (language, workspace, uri) tuple has already been opened on
/// this LSP in this session, this is a no-op. Otherwise the pool
/// builds and sends a didOpen notification through the cached
/// Proc and records the URI as opened.
pub fn ensure_open(
  pool: Pool,
  language: String,
  workspace: String,
  uri: String,
  language_id: String,
  content: String,
) -> Result(Nil, EnsureOpenError) {
  let Pool(subject) = pool
  actor.call(subject, default_call_timeout_ms, fn(reply) {
    EnsureOpen(language, workspace, uri, language_id, content, reply)
  })
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Get(language, workspace, spec, reply) ->
      handle_get(state, language, workspace, spec, reply)

    Evict(language, workspace) ->
      handle_evict(state, language, workspace)

    CloseAll -> handle_close_all(state)

    EnsureOpen(language, workspace, uri, language_id, content, reply) ->
      handle_ensure_open(
        state,
        language,
        workspace,
        uri,
        language_id,
        content,
        reply,
      )

    ProcDown(monitor_ref:, reason: _reason) ->
      handle_proc_down(state, monitor_ref)

    KillLsp(language, workspace, reply_to) ->
      handle_kill_lsp(state, language, workspace, reply_to)
  }
}

fn handle_kill_lsp(
  state: State,
  language: String,
  workspace: String,
  reply: Subject(KillStatus),
) -> actor.Next(State, Msg) {
  let key = #(language, workspace)
  case dict.get(state.cache, key) {
    Error(_) -> {
      process.send(reply, NotFound)
      actor.continue(state)
    }
    Ok(spawned) -> {
      proc.close(spawned)
      proc.forget_subject(language, workspace)
      let cache = dict.delete(state.cache, key)
      let opened =
        set.filter(state.opened, fn(triple) {
          let #(l, w, _) = triple
          !{ l == language && w == workspace }
        })
      log.warn_at(
        "pharos/lsp/pool",
        "operator-requested kill of lsp_proc for "
        <> language
        <> " / "
        <> workspace,
      )
      process.send(reply, Killed)
      actor.continue(State(cache: cache, monitors: state.monitors, opened: opened))
    }
  }
}

fn handle_get(
  state: State,
  language: String,
  workspace: String,
  spec: SpawnSpec,
  reply: Subject(Result(Proc, GetError)),
) -> actor.Next(State, Msg) {
  let key = #(language, workspace)

  case dict.get(state.cache, key) {
    Ok(existing) -> {
      process.send(reply, Ok(existing))
      actor.continue(state)
    }

    Error(_) ->
      // ADR-017a: cache-miss path. Try the ETS bridge first —
      // a supervisor-driven restart of an existing worker would
      // have overwritten the row with a new Subject before our
      // monitor's DOWN message reached us, so reading it directly
      // avoids the duplicate-spawn race.
      case proc.recover_subject(language, workspace) {
        Ok(subject) -> {
          let recovered = proc.from_subject(subject)
          let monitor_ref = process.monitor(proc.pid(recovered))
          process.send(reply, Ok(recovered))
          let cache = dict.insert(state.cache, key, recovered)
          let monitors = dict.insert(state.monitors, monitor_ref, key)
          actor.continue(
            State(cache: cache, monitors: monitors, opened: state.opened),
          )
        }
        Error(_) ->
          case spawn_proc(language, workspace, spec) {
            Ok(spawned) -> {
              // Auto-evict on proc exit per ADR-013. Pool monitors
              // the proc actor's pid; on DOWN, lookup ref→key and
              // remove. Acts as belt-and-suspenders alongside the
              // supervisor's auto-restart.
              let monitor_ref = process.monitor(proc.pid(spawned))
              process.send(reply, Ok(spawned))
              let cache = dict.insert(state.cache, key, spawned)
              let monitors = dict.insert(state.monitors, monitor_ref, key)
              actor.continue(
                State(cache: cache, monitors: monitors, opened: state.opened),
              )
            }
            Error(err) -> {
              process.send(reply, Error(err))
              actor.continue(state)
            }
          }
      }
  }
}

fn handle_evict(
  state: State,
  language: String,
  workspace: String,
) -> actor.Next(State, Msg) {
  let key = #(language, workspace)
  case dict.get(state.cache, key) {
    Ok(spawned) -> {
      proc.close(spawned)
      proc.forget_subject(language, workspace)
      let cache = dict.delete(state.cache, key)
      // Drop opened-doc entries for this (language, workspace) — when
      // a fresh LSP spawns later it will not know about previously
      // opened documents.
      let opened =
        set.filter(state.opened, fn(triple) {
          let #(l, w, _) = triple
          !{ l == language && w == workspace }
        })
      // Monitor cleanup happens implicitly when ProcDown fires after
      // proc.close terminates the actor; no explicit demonitor here.
      actor.continue(State(cache: cache, monitors: state.monitors, opened: opened))
    }
    Error(_) -> actor.continue(state)
  }
}

fn handle_close_all(state: State) -> actor.Next(State, Msg) {
  state.cache
  |> dict.values
  |> close_each
  actor.continue(State(
    cache: dict.new(),
    monitors: dict.new(),
    opened: set.new(),
  ))
}

fn handle_proc_down(
  state: State,
  monitor_ref: process.Monitor,
) -> actor.Next(State, Msg) {
  case dict.get(state.monitors, monitor_ref) {
    Error(_) -> actor.continue(state)

    Ok(key) -> {
      let #(language, workspace) = key
      log.warn_at(
        "pharos/lsp/pool",
        "lsp_proc for "
        <> language
        <> " / "
        <> workspace
        <> " exited; evicting pool cache entry",
      )
      let cache = dict.delete(state.cache, key)
      let monitors = dict.delete(state.monitors, monitor_ref)
      let opened =
        set.filter(state.opened, fn(triple) {
          let #(l, w, _) = triple
          !{ l == language && w == workspace }
        })
      actor.continue(State(cache: cache, monitors: monitors, opened: opened))
    }
  }
}

fn handle_ensure_open(
  state: State,
  language: String,
  workspace: String,
  uri: String,
  language_id: String,
  content: String,
  reply: Subject(Result(Nil, EnsureOpenError)),
) -> actor.Next(State, Msg) {
  let doc_key = #(language, workspace, uri)
  case set.contains(state.opened, doc_key) {
    True -> {
      // Already opened on this LSP this session. didOpen-once.
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }

    False ->
      case dict.get(state.cache, #(language, workspace)) {
        Error(_) -> {
          process.send(reply, Error(NoCachedClient))
          actor.continue(state)
        }

        Ok(spawned) -> {
          let body =
            json.object([
              #("jsonrpc", json.string("2.0")),
              #("method", json.string("textDocument/didOpen")),
              #(
                "params",
                json.object([
                  #(
                    "textDocument",
                    json.object([
                      #("uri", json.string(uri)),
                      #("languageId", json.string(language_id)),
                      #("version", json.int(1)),
                      #("text", json.string(content)),
                    ]),
                  ),
                ]),
              ),
            ])
            |> json.to_string
            |> bit_array.from_string

          case proc.send_notification(spawned, body) {
            Ok(Nil) -> {
              process.send(reply, Ok(Nil))
              actor.continue(
                State(..state, opened: set.insert(state.opened, doc_key)),
              )
            }
            Error(_) -> {
              process.send(reply, Error(SendFailed))
              actor.continue(state)
            }
          }
        }
      }
  }
}

fn close_each(procs: List(Proc)) -> Nil {
  case procs {
    [] -> Nil
    [first, ..rest] -> {
      proc.close(first)
      close_each(rest)
    }
  }
}

fn spawn_proc(
  language: String,
  workspace: String,
  spec: SpawnSpec,
) -> Result(Proc, GetError) {
  // ADR-017a: spawn the lsp_proc actor as a child of the
  // `pharos_lsp_dyn_sup` simple_one_for_one supervisor. The
  // supervisor's start_child returns the actor's Pid; the
  // matching Subject is recovered from the
  // `pharos_lsp_proc_subjects` ETS bridge table the worker's
  // `start_link_supervised` wrapper populated keyed by
  // (language, workspace) before returning to the supervisor.
  use _spawned_pid <- result.try(case
    dyn_sup_start_child(
      language,
      workspace,
      spec.command,
      spec.args,
      spec.init_params,
      initialize_timeout_ms,
    )
  {
    Ok(p) -> Ok(p)
    Error(reason) ->
      Error(ProcStartFailed("lsp_dyn_sup.start_child failed: " <> reason))
  })

  use subject <- result.try(case proc.recover_subject(language, workspace) {
    Ok(s) -> Ok(s)
    Error(_) ->
      Error(ProcStartFailed(
        "ETS bridge missing entry for spawned lsp_proc; "
        <> "(ADR-017a invariant violation)",
      ))
  })

  let spawned = proc.from_subject(subject)

  // Per-language workspace_configuration (Stage 0C). Install a
  // workspace/configuration handler on the proc and push
  // workspace/didChangeConfiguration. Push failure is logged and
  // swallowed per ADR-012 decision 4.
  case spec.workspace_configuration {
    option.None -> Nil

    option.Some(settings) -> {
      proc.add_handler(
        spawned,
        "workspace/configuration",
        server_request_handlers.workspace_configuration_handler(settings),
      )

      case proc.push_configuration(spawned, settings_to_json(settings)) {
        Ok(Nil) -> Nil
        Error(_err) ->
          log.warn_at(
            "pharos/lsp/pool",
            "workspace/didChangeConfiguration push failed; "
            <> "server may run with degraded settings",
          )
      }
    }
  }

  Ok(spawned)
}

@external(erlang, "pharos_lsp_dyn_sup", "start_child")
fn dyn_sup_start_child(
  language: String,
  workspace: String,
  command: String,
  args: List(String),
  init_params: json.Json,
  initialize_timeout_ms: Int,
) -> Result(process.Pid, String)

fn settings_to_json(settings: Dict(String, json.Json)) -> json.Json {
  settings
  |> dict.to_list
  |> json.object
}
