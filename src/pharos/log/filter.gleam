//// Log filter — decides whether an entry should be emitted.
////
//// Spec mirrors Rust's `RUST_LOG` so habits transfer:
////
////     PHAROS_LOG=info,pharos/lsp/proc=debug,pharos/lsp/trace=off
////
//// Bare-level entries (`info`) set the global default. Anything of
//// the form `<target>=<level>` overrides for that target. `off`
//// silences the target. Targets are matched as a prefix so
//// `pharos/lsp=debug` enables all `pharos/lsp/*` modules.
////
//// Parsed once at boot. Runtime overrides (Part C
//// `runtime_log_level`) update an in-memory copy held by the
//// writer actor; this module only handles parse + check.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import pharos/log/entry.{type Level, Info}

pub type Filter {
  Filter(default: Level, overrides: List(Override))
}

/// `level = None` means the target is silenced (`off`); `level =
/// Some(L)` means the target emits at threshold `L`.
pub type Override {
  Override(target_prefix: String, level: Option(Level))
}

/// Permissive default — info globally, no overrides — used when
/// `PHAROS_LOG` is unset or unparseable.
pub fn default() -> Filter {
  Filter(default: Info, overrides: [])
}

/// Parse a `PHAROS_LOG` directive string. Unknown clauses are
/// dropped silently rather than failing boot.
pub fn parse_spec(spec: String) -> Filter {
  let cleaned = string.trim(spec)
  case cleaned {
    "" -> default()
    _ -> {
      let parts = string.split(cleaned, ",")
      let acc =
        list.fold(parts, #(Info, []), fn(state, raw) {
          let #(current_default, current_overrides) = state
          let clause = string.trim(raw)
          case parse_clause(clause) {
            ParseDefault(level) -> #(level, current_overrides)
            ParseOverride(ovr) -> #(current_default, [ovr, ..current_overrides])
            ParseSkip -> state
          }
        })
      let #(default_level, overrides) = acc
      Filter(
        default: default_level,
        overrides: list.sort(overrides, by: compare_by_prefix_length),
      )
    }
  }
}

type ClauseResult {
  ParseDefault(Level)
  ParseOverride(Override)
  ParseSkip
}

fn parse_clause(clause: String) -> ClauseResult {
  case string.split_once(clause, "=") {
    Error(_) ->
      case entry.parse_level(clause) {
        Ok(level) -> ParseDefault(level)
        Error(_) -> ParseSkip
      }
    Ok(#(target_raw, level_raw)) -> {
      let target = string.trim(target_raw)
      let level_text = string.lowercase(string.trim(level_raw))
      case target {
        "" -> ParseSkip
        _ ->
          case level_text {
            "off" -> ParseOverride(Override(target, None))
            other ->
              case entry.parse_level(other) {
                Ok(level) -> ParseOverride(Override(target, Some(level)))
                Error(_) -> ParseSkip
              }
          }
      }
    }
  }
}

fn compare_by_prefix_length(a: Override, b: Override) -> order.Order {
  let len_a = string.length(a.target_prefix)
  let len_b = string.length(b.target_prefix)
  case len_a > len_b, len_a < len_b {
    True, _ -> order.Lt
    _, True -> order.Gt
    _, _ -> order.Eq
  }
}

/// Decide whether to emit an entry tagged `target` at `level`.
pub fn allows(filter: Filter, target: String, level: Level) -> Bool {
  case matching_override(filter.overrides, target) {
    Some(Override(_, None)) -> False
    Some(Override(_, Some(threshold))) ->
      entry.level_rank(level) >= entry.level_rank(threshold)
    None -> entry.level_rank(level) >= entry.level_rank(filter.default)
  }
}

fn matching_override(
  overrides: List(Override),
  target: String,
) -> Option(Override) {
  case overrides {
    [] -> None
    [first, ..rest] ->
      case string.starts_with(target, first.target_prefix) {
        True -> Some(first)
        False -> matching_override(rest, target)
      }
  }
}
