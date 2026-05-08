//// Result-clipping helpers for tools that can return very large
//// arrays. M8 Stage 2 dogfood found `goto_implementation` returning
//// 907K characters when called on a stdlib trait method (`Default::
//// default`); MCP hosts cap per-tool-result token budgets, so a
//// single overlarge response is unusable. Clipping the array at a
//// caller-chosen `limit` keeps the result actionable.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/string
import pharos/tools/tool_helpers

/// Clip the supplied Dynamic — expected to be a JSON array — to the
/// first `limit` elements and re-encode as JSON text. If the value
/// is not an array (null, single object), it passes through
/// unchanged. The clip is silent: callers that want to know the
/// original count should declare a richer tool wrapper. Default
/// limit is the caller's choice; tool defaults of 50 cover almost
/// every dogfood scenario.
///
/// Returns the encoded JSON text plus a flag describing whether
/// the result was actually clipped, so tool callers can append a
/// human-readable marker if desired.
pub fn clip_array(value: Dynamic, limit: Int) -> ClipResult {
  case decode.run(value, decode.list(decode.dynamic)) {
    Error(_) ->
      // Not an array — return verbatim, no clipping possible.
      ClipResult(json_text: tool_helpers.json_encode(value), truncated_by: 0)

    Ok(items) -> {
      let original_count = list.length(items)
      case original_count > limit {
        False ->
          ClipResult(
            json_text: tool_helpers.json_encode(value),
            truncated_by: 0,
          )

        True -> {
          let kept = list.take(items, limit)
          let body =
            kept
            |> list.map(tool_helpers.json_encode)
            |> string.join(",")
          ClipResult(
            json_text: "[" <> body <> "]",
            truncated_by: original_count - limit,
          )
        }
      }
    }
  }
}

pub type ClipResult {
  ClipResult(json_text: String, truncated_by: Int)
}
