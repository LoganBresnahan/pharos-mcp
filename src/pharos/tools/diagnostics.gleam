//// MCP tool: `get_diagnostics`.
////
//// Returns LSP diagnostics (errors and warnings) for a file URI.
//// Implementation branches on how many servers in the language
//// claim `textDocument/diagnostic` and on each server's
//// `diagnostics_mode`:
////
//// - **Single-server.** Use the language's primary server with
////   `Push` (read the server's last `textDocument/publishDiagnostics`
////   from `pharos_diagnostics_cache`, waiting for one if needed),
////   `Pull` (`textDocument/diagnostic` request), or `Tsserver` (ask
////   tsserver through `typescript.tsserverRequest`, falling back to
////   Push; ADR-039).
////
//// - **Multi-server (M10 / ADR-019 Stage 3 follow-up).** Every
////   server whose scope COVERS `textDocument/diagnostic` runs its
////   own per-mode fetch in turn; the resulting `diagnostics`
////   arrays are concatenated into one synthesized
////   publishDiagnostics envelope. Used today by python (pyright
////   type-errors + ruff lint violations) and by any future
////   multi-server language declaration.
////
//// ADR-038: preparing the session re-syncs the file from disk, so a
//// push entry is either fresh (published about the text the server
//// has now), carried over (published before the last sync), or
//// missing. A carried-over entry gets a short settle window to be
//// replaced, then is answered from and marked. Every wait polls the
//// cache from this process; none runs inside the proc actor, so a
//// wait never holds up other sessions' requests to the server. A
//// server that reports nothing in time is named in the result, never
//// counted as clean.
////
//// In every case the result body is shaped as a synthetic
//// `textDocument/publishDiagnostics` envelope so the MCP caller
//// reads identical JSON structure regardless of how many servers
//// answered. Notes about the answer go in a top-level `pharos`
//// member of that envelope.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/diagnostics_cache
import pharos/lsp/languages.{
  type LanguageConfig, type ServerConfig, Pull, Push, Tsserver,
}
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc
import pharos/lsp/tsserver_diagnostics
import pharos/tools/session
import pharos/tools/tool_helpers

const default_drain_window_ms: Int = 8000

const poll_step_ms: Int = 50

const diagnostic_method: String = "textDocument/diagnostic"

pub type DiagnosticsError {
  /// File URI did not have a `file://` prefix.
  NotAFileUri(uri: String)
  /// Walked the directory tree without finding any registered root
  /// marker for the language.
  WorkspaceNotFound(uri: String)
  /// LSP subprocess could not be spawned.
  SpawnFailed(reason: String)
  /// Initialize handshake failed.
  HandshakeFailed(reason: String)
  /// I/O error while waiting for diagnostics.
  TransportFailed(reason: String)
  /// Tool was called on a file with an unsupported extension.
  UnsupportedFileType(uri: String)
  /// ADR-029: URI used a non-file scheme that no language declared.
  UnknownCustomUriScheme(uri: String)
  /// ADR-029: custom URI's language has no Ready session in the pool.
  NoActiveSessionForLanguage(uri: String, language: String)
  /// ADR-029: custom URI's language has multiple Ready workspaces.
  AmbiguousSessionForLanguage(
    uri: String,
    language: String,
    workspaces: List(String),
  )
}

pub type DiagnosticsResult {
  /// At least one server published or returned diagnostics for the
  /// file (possibly none). `body_json` is a
  /// `textDocument/publishDiagnostics`-shaped envelope: the server's
  /// own params in single-server push mode, synthesized otherwise.
  Diagnostics(uri: String, body_json: String)
  /// No contributing server reported within the timeout.
  NoDiagnosticsObserved(uri: String)
}

/// Run get_diagnostics for one URI. Branches on per-language
/// server count; falls through to the single-server path with cache
/// when only one server claims `textDocument/diagnostic`.
pub fn handle(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.config_for_uri(file_uri) {
    Error(err) -> Error(map_session_error(err))
    Ok(config) -> {
      let covering =
        languages.servers_covering_method(config, diagnostic_method)
      // Every wait below comes out of this call's own budget.
      let deadline_ms = now_ms() + timeout_ms
      case covering {
        [_single] ->
          attempt_single(
            pool,
            file_uri,
            config,
            timeout_ms,
            deadline_ms,
            retries_left: 1,
          )
        _ ->
          attempt_merge(
            pool,
            file_uri,
            config,
            covering,
            timeout_ms,
            deadline_ms,
          )
      }
    }
  }
}

pub fn handle_with_default_timeout(
  pool: Pool,
  file_uri: String,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  handle(pool, file_uri, default_drain_window_ms)
}

// -- Single-server path (cache + retry) ----------------------------------

/// Single-server attempt. On `TransportFailed`, evict the pool
/// entry for this language+workspace and recurse once with a fresh
/// session.
fn attempt_single(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
  timeout_ms: Int,
  deadline_ms: Int,
  retries_left retries_left: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(map_session_error(err))
    Ok(lsp) -> {
      let primary = languages.primary_server(config)
      let #(server_id, mode) = case primary {
        Ok(server) -> #(server.id, server.diagnostics_mode)
        Error(_) -> #("", Push)
      }
      let result = case mode {
        Push -> Ok(push_result(file_uri, server_id, proc.pid(lsp), deadline_ms))
        Pull -> pull_diagnostics(lsp, file_uri, timeout_ms)
        Tsserver -> {
          let ignored = case primary {
            Ok(server) -> tsserver_diagnostics.ignored_codes(server)
            Error(_) -> []
          }
          Ok(tsserver_result(lsp, file_uri, server_id, ignored, deadline_ms))
        }
      }
      case result, retries_left > 0 {
        Error(TransportFailed(_)), True -> {
          log.warn_at(
            "pharos/tools/diagnostics",
            "transport error during diagnostics; evicting and retrying once",
          )
          evict_for_uri(pool, file_uri, config)
          attempt_single(
            pool,
            file_uri,
            config,
            timeout_ms,
            deadline_ms,
            retries_left: retries_left - 1,
          )
        }
        _, _ -> result
      }
    }
  }
}

// -- Multi-server merge path --------------------------------------------

/// Multi-server attempt. Every server whose scope covers
/// `textDocument/diagnostic` runs its own fetch sequentially; their
/// items concatenate. A server that fails or reports nothing in time
/// contributes no items and is named under `pharos.not_reported`: its
/// diagnostics are unknown, which is not the same as none. When no
/// server reported, the answer is `NoDiagnosticsObserved`. No
/// transport-error retry on this path — partial results are
/// preferable to all-or-nothing failure.
fn attempt_merge(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
  _covering: List(ServerConfig),
  timeout_ms: Int,
  deadline_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.prepare_all_covering_method(pool, file_uri, diagnostic_method) {
    Error(err) -> Error(map_session_error(err))
    Ok([]) -> Ok(NoDiagnosticsObserved(uri: file_uri))
    Ok(prepared) -> {
      let reports =
        list.map(prepared, fn(entry) {
          let #(server, lsp) = entry
          #(
            server.id,
            server_report(server, lsp, file_uri, timeout_ms, deadline_ms),
          )
        })
      let _ = config
      let _ = pool
      let reported =
        list.filter_map(reports, fn(r) {
          case r.1 {
            Reported(items:, carried_over: _) -> Ok(#(r.0, items))
            Silent -> Error(Nil)
          }
        })
      let carried =
        list.filter_map(reports, fn(r) {
          case r.1 {
            Reported(items: _, carried_over: True) -> Ok(r.0)
            _ -> Error(Nil)
          }
        })
      let silent =
        list.filter_map(reports, fn(r) {
          case r.1 {
            Silent -> Ok(r.0)
            _ -> Error(Nil)
          }
        })
      case reported {
        [] -> Ok(NoDiagnosticsObserved(uri: file_uri))
        _ ->
          Ok(Diagnostics(
            uri: file_uri,
            body_json: publish_envelope(
              synthesized_params(file_uri, merge_items_arrays(reported)),
              carried,
              silent,
            ),
          ))
      }
    }
  }
}

/// One server's contribution to a merged answer.
type ServerReport {
  Reported(items: String, carried_over: Bool)
  Silent
}

fn server_report(
  server: ServerConfig,
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
  deadline_ms: Int,
) -> ServerReport {
  let fetched = case server.diagnostics_mode {
    Push ->
      case resolve_push(file_uri, server.id, proc.pid(lsp), deadline_ms) {
        FreshEntry(params) ->
          items_from_params(params) |> result_map(fn(i) { #(i, False) })
        CarriedEntry(params) ->
          items_from_params(params) |> result_map(fn(i) { #(i, True) })
        NotReported -> Error("no publishDiagnostics within the timeout")
      }
    Pull ->
      pull_items(lsp, file_uri, timeout_ms)
      |> result_map(fn(i) { #(i, False) })
    Tsserver ->
      case
        tsserver_items(
          lsp,
          file_uri,
          tsserver_diagnostics.ignored_codes(server),
          deadline_ms,
        )
      {
        Ok(items) -> Ok(#(items, False))
        Error(reason) -> {
          log_tsserver_fallback(server.id, reason)
          // A publish carries no version: never fresh in this mode.
          case resolve_push(file_uri, server.id, proc.pid(lsp), deadline_ms) {
            FreshEntry(params) | CarriedEntry(params) ->
              items_from_params(params) |> result_map(fn(i) { #(i, True) })
            NotReported -> Error("no publishDiagnostics within the timeout")
          }
        }
      }
  }
  case fetched {
    Ok(#(items, carried_over)) -> Reported(items:, carried_over:)
    Error(reason) -> {
      log.fields_at(
        "pharos/tools/diagnostics",
        log_entry.Warn,
        "server reported no diagnostics; naming it as not reported",
        [#("server", server.id), #("reason", reason)],
      )
      Silent
    }
  }
}

fn result_map(r: Result(a, e), f: fn(a) -> b) -> Result(b, e) {
  case r {
    Ok(v) -> Ok(f(v))
    Error(e) -> Error(e)
  }
}

fn pull_items(
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> Result(String, String) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])

  case
    session.request_with_content_modified_retry(fn() {
      proc.request(lsp, diagnostic_method, params, timeout_ms)
    })
  {
    Error(err) -> Error(tool_helpers.describe_request_error(err))
    Ok(result_value) ->
      case decode.run(result_value, full_report_items_decoder()) {
        Error(decode_errs) ->
          Error(
            "diagnostic response decode: "
            <> describe_decode_errors(decode_errs),
          )
        Ok(items_json) -> Ok(items_json)
      }
  }
}

// -- Push: the cache, freshness and waits (ADR-038) ----------------------

type PushEntry {
  FreshEntry(params: Dynamic)
  CarriedEntry(params: Dynamic)
  NotReported
}

/// The diagnostics the proc `pid` cached for `file_uri`:
/// - fresh: answer now;
/// - carried over: wait out what is left of the last sync's settle
///   window (`diagnostics_cache.settle_ms`, run from when the sync was
///   written, so a later question does not wait again) for a publish
///   about the new text. Once the window has passed, an entry carried
///   over only by other documents' changes is fresh (the server left
///   this file's set as it was); one from before this document's own
///   latest sync is answered marked as carried over. If the call's
///   deadline ends the wait first, the entry is answered marked;
/// - missing (nothing cached, or only from before pharos closed the
///   document): wait until the call's deadline for a first publish.
fn resolve_push(
  file_uri: String,
  server_id: String,
  pid: Pid,
  deadline_ms: Int,
) -> PushEntry {
  // #30: while the server is still working on this document's sync (a
  // progress that began after it is running), what's cached can be from
  // before it: rust-analyzer republishes cargo check's old results at the
  // new version until the check it reruns on save ends. Wait for that,
  // within the call's deadline. If the deadline comes first, an entry
  // that looks fresh is answered as carried over (unsure), never as
  // fresh.
  case await_progress_quiet(file_uri, server_id, pid, deadline_ms) {
    True -> resolve_push_now(file_uri, server_id, pid, deadline_ms)
    False ->
      case resolve_push_now(file_uri, server_id, pid, now_ms()) {
        FreshEntry(params) -> CarriedEntry(params)
        other -> other
      }
  }
}

/// A progress begin can land just after the sync (cargo check starts on
/// the save that followed the change); this long a sync waits for one,
/// on a server that has reported progress before (rust-analyzer always
/// has, from its startup indexing).
const progress_grace_ms = 500

/// A progress running longer than this is taken as stuck, and no longer
/// holds answers back.
const progress_stuck_ms = 30_000

/// True once nothing the server reports is still working on `file_uri`'s
/// latest sync; False if `deadline_ms` comes first.
fn await_progress_quiet(
  file_uri: String,
  server_id: String,
  pid: Pid,
  deadline_ms: Int,
) -> Bool {
  case
    diagnostics_cache.progress_quiet(
      file_uri,
      server_id,
      pid,
      progress_grace_ms,
      progress_stuck_ms,
    )
  {
    True -> True
    False ->
      case now_ms() >= deadline_ms {
        True -> False
        False -> {
          process.sleep(poll_step_ms)
          await_progress_quiet(file_uri, server_id, pid, deadline_ms)
        }
      }
  }
}

fn resolve_push_now(
  file_uri: String,
  server_id: String,
  pid: Pid,
  deadline_ms: Int,
) -> PushEntry {
  case diagnostics_cache.lookup(file_uri, server_id, pid) {
    diagnostics_cache.Fresh(params) -> FreshEntry(params)
    diagnostics_cache.CarriedOver(params) ->
      case
        await_lookup(
          file_uri,
          server_id,
          pid,
          int.min(now_ms() + diagnostics_cache.settle_left_ms(pid), deadline_ms),
          fresh_only: True,
        )
      {
        diagnostics_cache.Fresh(newer) -> FreshEntry(newer)
        diagnostics_cache.CarriedOver(latest) -> CarriedEntry(latest)
        diagnostics_cache.Missing -> CarriedEntry(params)
      }
    diagnostics_cache.Missing ->
      case
        await_lookup(file_uri, server_id, pid, deadline_ms, fresh_only: False)
      {
        diagnostics_cache.Fresh(params) -> FreshEntry(params)
        diagnostics_cache.CarriedOver(params) -> CarriedEntry(params)
        diagnostics_cache.Missing -> NotReported
      }
  }
}

/// Poll the cache from the calling process until the entry is what we
/// want or the budget runs out; return the last lookup. The proc actor
/// caches publishes as they arrive, idle or mid-request, so nothing
/// needs to drain inside it.
fn await_lookup(
  file_uri: String,
  server_id: String,
  pid: Pid,
  until_ms: Int,
  fresh_only fresh_only: Bool,
) -> diagnostics_cache.Lookup {
  poll_lookup(file_uri, server_id, pid, until_ms, fresh_only)
}

fn poll_lookup(
  file_uri: String,
  server_id: String,
  pid: Pid,
  deadline_ms: Int,
  fresh_only: Bool,
) -> diagnostics_cache.Lookup {
  // The clock is read before the lookup, so the last lookup comes after
  // the deadline: when the deadline is the end of a settle window, that
  // lookup already counts the window as passed.
  let expired = now_ms() >= deadline_ms
  let current = diagnostics_cache.lookup(file_uri, server_id, pid)
  let wanted = case current, fresh_only {
    diagnostics_cache.Fresh(_), _ -> True
    diagnostics_cache.CarriedOver(_), False -> True
    _, _ -> False
  }
  case wanted || expired {
    True -> current
    False -> {
      process.sleep(poll_step_ms)
      poll_lookup(file_uri, server_id, pid, deadline_ms, fresh_only)
    }
  }
}

fn now_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

fn push_result(
  file_uri: String,
  server_id: String,
  pid: Pid,
  deadline_ms: Int,
) -> DiagnosticsResult {
  case resolve_push(file_uri, server_id, pid, deadline_ms) {
    FreshEntry(params) ->
      Diagnostics(
        uri: file_uri,
        body_json: publish_envelope(tool_helpers.json_encode(params), [], []),
      )
    CarriedEntry(params) ->
      Diagnostics(
        uri: file_uri,
        body_json: publish_envelope(
          tool_helpers.json_encode(params),
          [server_id],
          [],
        ),
      )
    NotReported -> NoDiagnosticsObserved(uri: file_uri)
  }
}

fn items_from_params(params: Dynamic) -> Result(String, String) {
  case decode.run(params, params_with_diagnostics_decoder()) {
    Ok(items) -> Ok(items)
    Error(_) -> Error("publishDiagnostics params decode failed")
  }
}

/// A `textDocument/publishDiagnostics` envelope around `params_json`,
/// plus a `pharos` member when the answer needs a note.
fn publish_envelope(
  params_json: String,
  carried_over: List(String),
  not_reported: List(String),
) -> String {
  let base =
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
    <> "\"params\":"
    <> params_json
  case carried_over, not_reported {
    [], [] -> base <> "}"
    _, _ ->
      base
      <> ",\"pharos\":"
      <> json.to_string(answer_note(carried_over, not_reported))
      <> "}"
  }
}

fn answer_note(
  carried_over: List(String),
  not_reported: List(String),
) -> json.Json {
  let carried = case carried_over {
    [] -> []
    ids -> [
      #("carried_over", json.array(ids, json.string)),
      #(
        "carried_over_note",
        json.string(
          "This is the server's last published set, which may describe the "
          <> "text before a change: it hasn't published since this file, or "
          <> "another file it has open, last changed, or pharos couldn't ask "
          <> "it directly. It still holds if the change left the diagnostics "
          <> "as they were; ask again if the server may still be analysing.",
        ),
      ),
    ]
  }
  let silent = case not_reported {
    [] -> []
    ids -> [
      #("not_reported", json.array(ids, json.string)),
      #(
        "not_reported_note",
        json.string(
          "These servers reported nothing in time: their diagnostics are "
          <> "unknown, not empty.",
        ),
      ),
    ]
  }
  json.object(list.append(carried, silent))
}

fn synthesized_params(uri: String, items_json: String) -> String {
  "{\"uri\":"
  <> json.to_string(json.string(uri))
  <> ",\"diagnostics\":"
  <> items_json
  <> "}"
}

fn params_with_diagnostics_decoder() -> decode.Decoder(String) {
  use diagnostics <- decode.field("diagnostics", decode.dynamic)
  decode.success(tool_helpers.json_encode(diagnostics))
}

/// Concatenate the JSON-string items arrays returned by each server
/// into a single JSON array string. Strips outer brackets, joins by
/// commas, re-brackets. Empty inputs become `"[]"`. Order: each
/// server's items appear in declaration order; within a server,
/// LSP order is preserved.
fn merge_items_arrays(server_results: List(#(String, String))) -> String {
  let item_chunks =
    list.filter_map(server_results, fn(entry) {
      let #(_id, items) = entry
      case strip_brackets(items) {
        "" -> Error(Nil)
        inner -> Ok(inner)
      }
    })
  case item_chunks {
    [] -> "[]"
    chunks -> "[" <> string_join(chunks, ",") <> "]"
  }
}

/// Strip the outer `[`...`]` of a JSON array string and trim
/// whitespace from the body. Operates on BYTES — `string:length/1`
/// counts codepoints, but `binary:part/3` uses byte offsets, and
/// JSON arrays containing multi-byte UTF-8 (e.g. pyright messages
/// with `\xc2\xa0` NBSP pairs) have byte length > codepoint length.
/// Mixing the two indexing schemes silently corrupts the suffix
/// check and drops the array — surfaced in M11 dogfood Run 4 as
/// pyright's items vanishing from the merged python diagnostic
/// result. Bytes only here.
fn strip_brackets(json_array: String) -> String {
  let trimmed = string_trim(json_array)
  let n = byte_size(trimmed)
  case n >= 2 && byte_at(trimmed, 0) == 91 && byte_at(trimmed, n - 1) == 93 {
    True -> string_trim(binary_part(trimmed, 1, n - 2))
    False -> ""
  }
}

@external(erlang, "string", "trim")
fn string_trim(s: String) -> String

@external(erlang, "binary", "part")
fn binary_part(bin: String, start: Int, len: Int) -> String

@external(erlang, "erlang", "byte_size")
fn byte_size(s: String) -> Int

@external(erlang, "binary", "at")
fn byte_at(s: String, idx: Int) -> Int

fn string_join(parts: List(String), sep: String) -> String {
  case parts {
    [] -> ""
    [first, ..rest] -> list.fold(rest, first, fn(acc, p) { acc <> sep <> p })
  }
}

// -- tsserver, asked directly (ADR-039) -----------------------------------

/// The file's diagnostics from tsserver itself, through
/// typescript-language-server's `typescript.tsserverRequest`. The
/// session's sync was written before this request, and tsserver
/// handles requests in order, so the answer is about the text it has
/// now. If the requests fail or time out, answer from the push cache,
/// always marked carried over: a publish carries no version, so it may
/// describe the text before a change (ADR-038 F4).
fn tsserver_result(
  lsp: proc.Proc,
  file_uri: String,
  server_id: String,
  ignored: List(Int),
  deadline_ms: Int,
) -> DiagnosticsResult {
  // The diagnostics first, then projectInfo with whatever is left. tsserver
  // answers in order, and the first request after an edit waits for the
  // program update (seconds, in a large project), so whichever
  // goes first absorbs it. projectInfo went first under a 2 s cap, ran out
  // whenever tsserver was busy, and a hook then read every such file as
  // unsure (#7's dry run: 11 checks). After the diagnostics the program
  // is current and projectInfo costs milliseconds; a reserve (a quarter, at
  // most 2 s) keeps the diagnostics from leaving it nothing.
  let reserve = int.min(2000, int.max({ deadline_ms - now_ms() } / 4, 1))
  let items = tsserver_items(lsp, file_uri, ignored, deadline_ms - reserve)
  case items {
    Ok(items_json) ->
      Diagnostics(
        uri: file_uri,
        body_json: with_project(
          publish_envelope(synthesized_params(file_uri, items_json), [], []),
          tsserver_project(lsp, file_uri, deadline_ms),
        ),
      )
    Error(reason) -> {
      log_tsserver_fallback(server_id, reason)
      case resolve_push(file_uri, server_id, proc.pid(lsp), deadline_ms) {
        FreshEntry(params) | CarriedEntry(params) ->
          Diagnostics(
            uri: file_uri,
            body_json: publish_envelope(
              tool_helpers.json_encode(params),
              [server_id],
              [],
            ),
          )
        NotReported -> NoDiagnosticsObserved(uri: file_uri)
      }
    }
  }
}

/// syntactic, semantic and suggestion diagnostics, in that order, as a
/// JSON array.
fn tsserver_items(
  lsp: proc.Proc,
  file_uri: String,
  ignored: List(Int),
  deadline_ms: Int,
) -> Result(String, String) {
  list.try_fold(tsserver_diagnostics.requests, [], fn(acc, request) {
    let timeout_ms = int.max(deadline_ms - now_ms(), 1)
    case
      session.request_with_content_modified_retry(fn() {
        proc.request(
          lsp,
          "workspace/executeCommand",
          tsserver_diagnostics.execute_params(request, file_uri),
          timeout_ms,
        )
      })
    {
      Error(err) -> Error(tool_helpers.describe_request_error(err))
      Ok(value) ->
        case tsserver_diagnostics.diagnostics_from_response(value, ignored) {
          Ok(found) -> Ok(list.append(acc, found))
          Error(reason) -> Error(reason)
        }
    }
  })
  |> result_map(fn(found) { json.to_string(json.preprocessed_array(found)) })
}

/// The file's project, from tsserver's `projectInfo` (#6: a hook keeps
/// to the files of one tsconfig's program). Best-effort: a failure or a
/// timeout is `pharos.project_unknown`, never an error.
fn tsserver_project(
  lsp: proc.Proc,
  file_uri: String,
  deadline_ms: Int,
) -> Result(String, Nil) {
  case
    proc.request(
      lsp,
      "workspace/executeCommand",
      tsserver_diagnostics.project_params(file_uri),
      int.max(deadline_ms - now_ms(), 1),
    )
  {
    Ok(value) ->
      tsserver_diagnostics.project_from_response(value)
      |> result_map_error(fn(_) { Nil })
    Error(_) -> Error(Nil)
  }
}

/// Add `pharos.project` to an envelope built by `publish_envelope`, or,
/// when tsserver couldn't name it, `pharos.project_unknown`: a hook keeping
/// to one program can't tell whether the file is in scope, so it must not
/// treat it as out (ADR-040).
fn with_project(envelope: String, project: Result(String, Nil)) -> String {
  let member = case project {
    Ok(name) -> "\"project\":" <> json.to_string(json.string(name))
    Error(Nil) -> "\"project_unknown\":true"
  }
  let assert True = string.ends_with(envelope, "}")
  let body = string.drop_end(envelope, 1)
  case string.contains(envelope, "\"pharos\":{") {
    // The notes object is last: add the member inside it.
    True -> string.drop_end(body, 1) <> "," <> member <> "}}"
    False -> body <> ",\"pharos\":{" <> member <> "}}"
  }
}

fn result_map_error(r: Result(a, e), f: fn(e) -> f) -> Result(a, f) {
  case r {
    Ok(v) -> Ok(v)
    Error(e) -> Error(f(e))
  }
}

fn log_tsserver_fallback(server_id: String, reason: String) -> Nil {
  log.fields_at(
    "pharos/tools/diagnostics",
    log_entry.Warn,
    "tsserver diagnostics request failed; answering from the push cache",
    [#("server", server_id), #("reason", reason)],
  )
}

// -- Single-server pull -------------------------------------------------

fn pull_diagnostics(
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])

  case
    session.request_with_content_modified_retry(fn() {
      proc.request(lsp, diagnostic_method, params, timeout_ms)
    })
  {
    Error(err) ->
      Error(TransportFailed(tool_helpers.describe_request_error(err)))

    Ok(result_value) ->
      case decode.run(result_value, full_report_items_decoder()) {
        Error(decode_errs) ->
          Error(TransportFailed(
            "diagnostic response decode failed: "
            <> describe_decode_errors(decode_errs),
          ))

        // The server answered, so an empty list means clean, not
        // "nothing observed".
        Ok(items_json) ->
          Ok(Diagnostics(
            uri: file_uri,
            body_json: publish_envelope(
              synthesized_params(file_uri, items_json),
              [],
              [],
            ),
          ))
      }
  }
}

/// Decoder for the LSP `DocumentDiagnosticReport` (3.17+).
fn full_report_items_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "full" -> {
      use items <- decode.field("items", decode.dynamic)
      decode.success(tool_helpers.json_encode(items))
    }
    "unchanged" -> decode.success("[]")
    _ -> decode.failure("[]", "unknown report kind: " <> kind)
  }
}

// -- Eviction ------------------------------------------------------------

/// Evict every server for the workspace owning `file_uri`.
///
/// Resolution goes through `session.resolve_workspace` (ADR-032 step 2),
/// not a local ascent. This used to hand-inline its own copy of the
/// promotion `case`, which made it the ADR's headline example of a
/// silent-failure trap: once routing sends a dependency path somewhere
/// other than plain ascent, a local copy computes a key no session lives
/// under, so eviction quietly evicts nothing while still appearing to
/// run — and the retry-after-evict path stops working with no error
/// anywhere.
fn evict_for_uri(pool: Pool, file_uri: String, config: LanguageConfig) -> Nil {
  case session.resolve_workspace(pool, file_uri, config) {
    Error(_) -> Nil
    Ok(workspace) -> pool.evict_all_servers(pool, config.id, workspace)
  }
}

// -- Error description helpers -------------------------------------------

fn map_session_error(err: session.SessionError) -> DiagnosticsError {
  case err {
    session.NotAFileUri(uri) -> NotAFileUri(uri)
    session.WorkspaceNotFound(uri) -> WorkspaceNotFound(uri)
    session.UnsupportedFileType(uri) -> UnsupportedFileType(uri)
    session.SpawnFailed(reason) -> SpawnFailed(reason)
    session.HandshakeFailed(reason) -> HandshakeFailed(reason)
    session.UnknownCustomUriScheme(uri) -> UnknownCustomUriScheme(uri)
    session.NoActiveSessionForLanguage(uri, language) ->
      NoActiveSessionForLanguage(uri, language)
    session.AmbiguousSessionForLanguage(uri, language, workspaces) ->
      AmbiguousSessionForLanguage(uri, language, workspaces)
  }
}

fn describe_decode_errors(errs: List(decode.DecodeError)) -> String {
  case errs {
    [] -> "no error info"
    [first, ..] -> first.expected <> " (got " <> first.found <> ")"
  }
}
