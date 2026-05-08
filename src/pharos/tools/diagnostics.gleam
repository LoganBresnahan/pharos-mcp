//// MCP tool: `get_diagnostics`.
////
//// Returns LSP diagnostics (errors and warnings) for a file URI.
//// Implementation branches on how many servers in the language
//// claim `textDocument/diagnostic` and on each server's
//// `diagnostics_mode`:
////
//// - **Single-server.** Use the language's primary server with
////   `Push` (drain `textDocument/publishDiagnostics`
////   notifications) or `Pull` (`textDocument/diagnostic` request).
////   Reads from `pharos_diagnostics_cache` first; cache miss falls
////   through to the live drain or pull request.
////
//// - **Multi-server (M10 / ADR-019 Stage 3 follow-up).** Every
////   server whose scope COVERS `textDocument/diagnostic` runs its
////   own per-mode fetch in turn; the resulting `diagnostics`
////   arrays are concatenated into one synthesized
////   publishDiagnostics envelope. The cache is bypassed in this
////   branch — it stores one entry per URI, which would conflict
////   with N servers contributing different subsets. Used today by
////   python (pyright type-errors + ruff lint violations) and by
////   any future multi-server language declaration.
////
//// In every case the result body is shaped as a synthetic
//// `textDocument/publishDiagnostics` envelope so the MCP caller
//// reads identical JSON structure regardless of how many servers
//// answered.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import pharos/log
import pharos/lsp/client
import pharos/lsp/diagnostics_cache
import pharos/lsp/languages.{type LanguageConfig, type ServerConfig, Pull, Push}
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc
import pharos/tools/session
import pharos/tools/tool_helpers
import pharos/workspace_root

const default_drain_window_ms: Int = 8000

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
}

pub type DiagnosticsResult {
  /// Server published or returned diagnostics for the file.
  /// `body_json` is a `textDocument/publishDiagnostics`-shaped
  /// envelope — verbatim from the server in single-server push
  /// mode, synthesized otherwise.
  Diagnostics(uri: String, body_json: String)
  /// No diagnostics observed from any contributing server.
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
      let covering = languages.servers_covering_method(config, diagnostic_method)
      case covering {
        [_single] -> attempt_single(pool, file_uri, config, timeout_ms, retries_left: 1)
        _ -> attempt_merge(pool, file_uri, config, covering, timeout_ms)
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
/// session. Retains the cache check so warm runs hit at O(1).
fn attempt_single(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
  timeout_ms: Int,
  retries_left retries_left: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.prepare(pool, file_uri) {
    Error(err) -> Error(map_session_error(err))
    Ok(lsp) -> {
      let primary_id = case languages.primary_server(config) {
        Ok(s) -> s.id
        Error(_) -> ""
      }
      case lookup_cached(file_uri, primary_id) {
        option.Some(body_json) ->
          Ok(Diagnostics(uri: file_uri, body_json: body_json))

        option.None -> {
          let mode = case languages.primary_server(config) {
            Ok(server) -> server.diagnostics_mode
            Error(_) -> Push
          }
          let result = case mode {
            Push -> push_drain(lsp, file_uri, timeout_ms)
            Pull -> pull_diagnostics(lsp, file_uri, timeout_ms)
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
                retries_left: retries_left - 1,
              )
            }
            _, _ -> result
          }
        }
      }
    }
  }
}

// -- Multi-server merge path --------------------------------------------

/// Multi-server attempt. Every server whose scope covers
/// `textDocument/diagnostic` runs its own fetch sequentially; their
/// items concatenate. Per-server failures warn-log and contribute
/// an empty array — the surviving servers' diagnostics still reach
/// the LLM.
///
/// Cache participation: the cache is keyed by `(uri, server_id)`
/// (M11 fix), so each server's cached items are addressable. For
/// each contributing server we hit the cache first; on miss we run
/// the live fetch (push drain or pull request) and lifecycle's
/// classifier writes the response back to the cache for next time.
/// No transport-error retry on this path — partial results are
/// preferable to all-or-nothing failure.
fn attempt_merge(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
  _covering: List(ServerConfig),
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case session.prepare_all_covering_method(pool, file_uri, diagnostic_method) {
    Error(err) -> Error(map_session_error(err))
    Ok([]) -> Ok(NoDiagnosticsObserved(uri: file_uri))
    Ok(prepared) -> {
      let server_results =
        list.map(prepared, fn(entry) {
          let #(server, lsp) = entry
          let items = case server.diagnostics_mode {
            Push ->
              case fetch_items_cached(file_uri, server.id) {
                option.Some(cached) -> cached
                option.None ->
                  fetch_items_one(server, lsp, file_uri, timeout_ms)
              }
            Pull -> fetch_items_one(server, lsp, file_uri, timeout_ms)
          }
          #(server.id, items)
        })

      let merged_items = merge_items_arrays(server_results)
      let _ = config
      let _ = pool
      case merged_items == "[]" {
        True -> Ok(NoDiagnosticsObserved(uri: file_uri))
        False ->
          Ok(Diagnostics(
            uri: file_uri,
            body_json: synthesize_publish_body(file_uri, merged_items),
          ))
      }
    }
  }
}

/// Per-server cache hit on the merge path. Returns the JSON-string
/// `diagnostics` array if cached; `None` on miss so the live fetch
/// runs. The cache stored params verbatim from publishDiagnostics
/// (`{uri, version?, diagnostics}`); we extract `diagnostics` and
/// re-encode as JSON.
fn fetch_items_cached(
  file_uri: String,
  server_id: String,
) -> option.Option(String) {
  case diagnostics_cache.get(file_uri, server_id) {
    Error(_) -> option.None
    Ok(params_value) -> {
      let envelope =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
        <> "\"params\":"
        <> tool_helpers.json_encode(params_value)
        <> "}"
      case extract_items_from_envelope(envelope) {
        Ok(items) -> option.Some(items)
        Error(_) -> option.None
      }
    }
  }
}

/// Run one server's diagnostics fetch and return the items array as
/// a JSON string. Errors return `"[]"` after a warn log; the merge
/// path treats them as "no items from this server" rather than
/// failing the whole call.
fn fetch_items_one(
  server: ServerConfig,
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> String {
  let result = case server.diagnostics_mode {
    Push -> push_drain_items(lsp, file_uri, timeout_ms)
    Pull -> pull_items(lsp, file_uri, timeout_ms)
  }
  case result {
    Ok(items) -> items
    Error(reason) -> {
      log.warn_at(
        "pharos/tools/diagnostics",
        "server `"
          <> server.id
          <> "` diagnostics fetch failed: "
          <> reason
          <> " — contributing empty array",
      )
      "[]"
    }
  }
}

fn push_drain_items(
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> Result(String, String) {
  case proc.wait_for_publish_diagnostics(lsp, file_uri, timeout_ms) {
    Error(err) ->
      Error("publishDiagnostics drain: " <> describe_client_error(err))
    Ok(option.None) -> Ok("[]")
    Ok(option.Some(envelope)) -> extract_items_from_envelope(envelope)
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

/// Pull `params.diagnostics` out of a publishDiagnostics envelope and
/// return as a JSON string suitable for concatenation. Returns an
/// `Error` on decode failure so the caller can fall back to live fetch
/// instead of silently contributing `"[]"` to the merged result.
/// Earlier behaviour returned `Ok("[]")` on every failure, which made
/// the multi-server merge collapse to empty whenever the cached params
/// failed to round-trip — surfaced in M11 dogfood Run 4 as
/// `NoDiagnosticsObserved` for python despite pyright having items.
fn extract_items_from_envelope(envelope: String) -> Result(String, String) {
  let decoder = {
    use params <- decode.field("params", params_with_diagnostics_decoder())
    decode.success(params)
  }
  case json.parse(envelope, decoder) {
    Ok(items_json) -> Ok(items_json)
    Error(_) -> Error("publishDiagnostics envelope decode failed")
  }
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
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, p) { acc <> sep <> p })
  }
}

// -- Single-server push (cache hit + drain) -----------------------------

fn push_drain(
  lsp: proc.Proc,
  file_uri: String,
  timeout_ms: Int,
) -> Result(DiagnosticsResult, DiagnosticsError) {
  case proc.wait_for_publish_diagnostics(lsp, file_uri, timeout_ms) {
    Error(err) ->
      Error(TransportFailed(
        "publishDiagnostics drain failed: " <> describe_client_error(err),
      ))
    Ok(option.None) -> Ok(NoDiagnosticsObserved(uri: file_uri))
    Ok(option.Some(body)) -> Ok(Diagnostics(uri: file_uri, body_json: body))
  }
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

        Ok(items_json) ->
          case items_json == "[]" {
            True -> Ok(NoDiagnosticsObserved(uri: file_uri))
            False ->
              Ok(Diagnostics(
                uri: file_uri,
                body_json: synthesize_publish_body(file_uri, items_json),
              ))
          }
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

fn synthesize_publish_body(uri: String, items_json: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
  <> "\"params\":{\"uri\":\""
  <> uri
  <> "\",\"diagnostics\":"
  <> items_json
  <> "}}"
}

// -- Cache + eviction (single-server only) -------------------------------

fn lookup_cached(
  file_uri: String,
  server_id: String,
) -> option.Option(String) {
  case diagnostics_cache.get(file_uri, server_id) {
    Error(_) -> option.None
    Ok(params_value) -> {
      let envelope =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
        <> "\"params\":"
        <> tool_helpers.json_encode(params_value)
        <> "}"
      option.Some(envelope)
    }
  }
}

fn evict_for_uri(
  pool: Pool,
  file_uri: String,
  config: LanguageConfig,
) -> Nil {
  case workspace_root.discover_from_uri(file_uri, config.root_markers) {
    Error(_) -> Nil
    Ok(raw_workspace) -> {
      let workspace = case config.root_promotion {
        languages.NoPromotion -> raw_workspace
        languages.CargoWorkspacePromotion ->
          workspace_root.promote_to_cargo_workspace(raw_workspace)
      }
      pool.evict_all_servers(pool, config.id, workspace)
    }
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
  }
}

fn describe_client_error(err: client.Error) -> String {
  case err {
    client.PortReceiveError(_) -> "port receive error"
    client.PortSendError(_) -> "port send error"
    client.FramingError(_) -> "framing error"
    client.SpawnError(_) -> "spawn error"
  }
}

fn describe_decode_errors(errs: List(decode.DecodeError)) -> String {
  case errs {
    [] -> "no error info"
    [first, ..] -> first.expected <> " (got " <> first.found <> ")"
  }
}
