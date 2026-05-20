//// MCP tool: `workspace_symbols`.
////
//// Wraps LSP `workspace/symbol`. Returns symbols across the entire
//// workspace matching a query string. Server returns
//// `SymbolInformation[]` or `WorkspaceSymbol[]` (LSP 3.17+).
////
//// Response shape is a pharos envelope around the LSP result rather
//// than the raw array, modelled on the `Resolution` pattern that
//// shipped with `find_symbol` (ADR-026). The envelope carries the
//// matches, the truncation count, and — when the LSP returns nothing
//// for the original query — a single retry with a case-or-convention
//// variant and any near-miss names it surfaced. This catches the
//// q0019-family failure where an LLM types the wrong case
//// (`Foo` vs `foo`) or the wrong convention (`calculate_total` vs
//// `calculateTotal`) and the LSP returns `[]` instead of suggesting
//// a fix.
////
//// Unlike per-file tools, this needs a workspace path hint to know
//// which LSP to query. Caller passes a URI of any file inside the
//// workspace, or the workspace root itself as a `file://` URI.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/clip
import pharos/tools/session
import pharos/tools/tool_helpers

pub const default_timeout_ms: Int = 30_000

pub const default_limit: Int = 20

/// Cap on how many names from the retry result get surfaced as
/// `near_misses`. Five is enough to disambiguate without bloating
/// the response when the retry hits an unrelated dense match set.
pub const near_miss_cap: Int = 5

pub type WorkspaceSymbolsError {
  SessionFailed(reason: String)
  RequestFailed(reason: String)
}

pub fn handle(
  pool: Pool,
  workspace_uri_hint: String,
  query: String,
  limit: Int,
  language: Option(String),
  timeout_ms: Int,
) -> Result(String, WorkspaceSymbolsError) {
  case query_once(pool, workspace_uri_hint, query, language, timeout_ms) {
    Error(err) -> Error(err)
    Ok(value) -> {
      let clip.ClipResult(json_text: matches_json, truncated_by: truncated_by) =
        clip.clip_array(value, limit)
      case is_empty_array(value) {
        False ->
          Ok(format_response(
            matches_json: matches_json,
            truncated_by: truncated_by,
            retried_with: None,
            near_misses: [],
          ))

        True ->
          case variant_for(query) {
            None ->
              Ok(format_response(
                matches_json: matches_json,
                truncated_by: truncated_by,
                retried_with: None,
                near_misses: [],
              ))

            Some(variant) -> {
              // Retry once with the alternate-convention query. Treat
              // any failure of the retry as "no near-misses" — we
              // never want a retry error to mask the original empty
              // result.
              let near_misses = case
                query_once(
                  pool,
                  workspace_uri_hint,
                  variant,
                  language,
                  timeout_ms,
                )
              {
                Ok(retry_value) ->
                  extract_first_names(retry_value, near_miss_cap)
                Error(_) -> []
              }
              Ok(format_response(
                matches_json: matches_json,
                truncated_by: truncated_by,
                retried_with: Some(variant),
                near_misses: near_misses,
              ))
            }
          }
      }
    }
  }
}

fn query_once(
  pool: Pool,
  workspace_uri_hint: String,
  query: String,
  language: Option(String),
  timeout_ms: Int,
) -> Result(Dynamic, WorkspaceSymbolsError) {
  let params = json.object([#("query", json.string(query))])

  let body = fn(lsp) {
    session.request_with_content_modified_retry(fn() {
      proc.request(lsp, "workspace/symbol", params, timeout_ms)
    })
  }

  let request_result = case language {
    Some(lang) ->
      session.with_workspace_session_and_retry_by_language(
        pool,
        lang,
        workspace_uri_hint,
        body,
      )
    None ->
      session.with_workspace_session_and_retry(pool, workspace_uri_hint, body)
  }

  case request_result {
    Ok(value) -> Ok(value)
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

/// Build the response JSON. `matches_json` is already a JSON-encoded
/// array, so we splice it in directly rather than re-encoding via
/// `json.object` (which would wrap it as a string). Manual string
/// assembly keeps the output stable and the code obvious.
fn format_response(
  matches_json matches_json: String,
  truncated_by truncated_by: Int,
  retried_with retried_with: Option(String),
  near_misses near_misses: List(String),
) -> String {
  let near_misses_json =
    json.to_string(
      json.preprocessed_array(list.map(near_misses, json.string)),
    )
  let retried_field = case retried_with {
    Some(v) ->
      ",\"retried_with\":" <> json.to_string(json.string(v))
    None -> ""
  }
  "{\"matches\":"
  <> matches_json
  <> ",\"truncated_by\":"
  <> int.to_string(truncated_by)
  <> ",\"near_misses\":"
  <> near_misses_json
  <> retried_field
  <> "}"
}

fn is_empty_array(value: Dynamic) -> Bool {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) -> list.is_empty(items)
    Error(_) -> True
  }
}

/// Pull the `name` field off the first `n` items of a
/// `SymbolInformation[]` / `WorkspaceSymbol[]` array. Tolerant of
/// either LSP response shape because they both expose `name`.
fn extract_first_names(value: Dynamic, n: Int) -> List(String) {
  case decode.run(value, decode.list(decode.dynamic)) {
    Error(_) -> []
    Ok(items) ->
      items
      |> list.take(n)
      |> list.filter_map(fn(item) {
        decode.run(item, {
          use name <- decode.field("name", decode.string)
          decode.success(name)
        })
      })
  }
}

/// Best-effort case/convention variant for the LLM-typed query.
/// Returns `None` when no obvious alternate convention applies, so
/// the caller can skip the retry entirely.
///
/// Priority order:
/// 1. `snake_case` → `camelCase` (most common when the LLM types
///    Python convention against a JS / Go / Rust codebase)
/// 2. `camelCase` → `snake_case` (the reverse)
/// 3. lowercase (case-mismatch fallback when neither convention
///    applies; e.g. `FOO` against `foo`)
pub fn variant_for(query: String) -> Option(String) {
  case string.contains(query, "_") {
    True -> {
      let camel = snake_to_camel(query)
      case camel == query {
        True -> lowercase_variant(query)
        False -> Some(camel)
      }
    }
    False ->
      case has_internal_uppercase(query) {
        True -> {
          let snake = camel_to_snake(query)
          case snake == query {
            True -> lowercase_variant(query)
            False -> Some(snake)
          }
        }
        False -> lowercase_variant(query)
      }
  }
}

fn lowercase_variant(query: String) -> Option(String) {
  let lower = string.lowercase(query)
  case lower == query {
    True -> None
    False -> Some(lower)
  }
}

fn has_internal_uppercase(query: String) -> Bool {
  // True iff the query looks like camelCase: at least one
  // lowercase letter AND at least one uppercase letter past
  // index 0. Used to distinguish:
  //   - camelCase (`fooBar`)               → True
  //   - PascalCase (`FooBar`)              → True
  //   - all-lower (`foobar`)               → False
  //   - leading-uppercase-only (`Foo`)     → False (no internal upper)
  //   - all-caps (`FOO`)                   → False (no lowercase to anchor)
  let graphemes = string.to_graphemes(query)
  case graphemes {
    [] -> False
    [_, ..rest] -> {
      let has_lower =
        list.any(graphemes, fn(g) {
          string.lowercase(g) == g && string.uppercase(g) != g
        })
      let has_internal_upper =
        list.any(rest, fn(g) {
          string.uppercase(g) == g && string.lowercase(g) != g
        })
      has_lower && has_internal_upper
    }
  }
}

fn snake_to_camel(query: String) -> String {
  case string.split(query, "_") {
    [] -> query
    [head, ..tail] -> {
      let camel_tail =
        list.map(tail, fn(part) {
          case string.first(part) {
            Ok(first) ->
              string.uppercase(first)
              <> string.drop_start(part, 1)
            Error(_) -> part
          }
        })
      string.concat([head, ..camel_tail])
    }
  }
}

fn camel_to_snake(query: String) -> String {
  // Walk graphemes; insert `_` before each uppercase letter that
  // isn't at position 0. Lowercase the result.
  let graphemes = string.to_graphemes(query)
  let parts =
    list.index_map(graphemes, fn(g, idx) {
      case idx, string.uppercase(g) == g && string.lowercase(g) != g {
        0, _ -> string.lowercase(g)
        _, True -> "_" <> string.lowercase(g)
        _, False -> g
      }
    })
  string.concat(parts)
}

fn describe_session_error(err: session.SessionError) -> String {
  case err {
    session.NotAFileUri(uri) -> "not a file:// URI: " <> uri
    session.WorkspaceNotFound(uri) ->
      "no workspace root marker found ascending from " <> uri
    session.UnsupportedFileType(uri) -> "unsupported file type: " <> uri
    session.SpawnFailed(reason) -> "LSP spawn failed: " <> reason
    session.HandshakeFailed(reason) ->
      "LSP initialize handshake failed: " <> reason
  }
}
