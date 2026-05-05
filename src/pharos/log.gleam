//// Structured logging facade.
////
//// **Stdout is reserved for MCP protocol traffic.** Every log line
//// MUST go to stderr (or the in-memory ring buffer). A single stray
//// write to stdout breaks the binary for every user. This module is
//// the only place log output is produced.
////
//// Existing call sites use `log.info / log.warn / log.error` with a
//// single message string and an implicit target of `"pharos"`. New
//// code in hot modules should use the `*_at` variants to pass the
//// module path as the target so per-module verbosity overrides
//// (`PHAROS_LOG=info,pharos/lsp/proc=debug`) take effect.
////
//// `set_correlation_id/1` stashes a per-process MCP request id in
//// the process dictionary; every log line emitted from the same
//// process picks it up automatically. The MCP request handler is
//// responsible for setting and clearing the id around each tool
//// dispatch.

import gleam/option.{type Option, None, Some}
import pharos/env
import pharos/log/entry.{
  type Level, Critical, Debug, Info, LogEntry, Warn,
}
import pharos/log/filter
import pharos/log/ring
import pharos/log/writer.{type Writer}

const default_target: String = "pharos"

/// Boot the writer using filter + sink configuration read from the
/// environment. Call once near the top of `pharos.main`. Subsequent
/// calls re-register the writer subject; old writer pid is left to
/// exit naturally (its mailbox drains before the cast resolves).
///
/// Configuration:
///   - `PHAROS_LOG` — RUST_LOG-style spec; default `info`.
///   - `PHAROS_TRACE_LSP` — convenience flag. When set to anything
///     other than empty/`0`/`off`, the boot filter is augmented
///     with `pharos/lsp/trace=debug` so wire traces are emitted
///     without having to spell out the full `PHAROS_LOG` form.
///   - `PHAROS_LOG_RING` — `0`/`off` disables the ring buffer sink;
///     anything else (or unset) keeps it on.
///   - `PHAROS_LOG_STDERR` — `0`/`off` disables stderr; default on.
pub fn start_default() -> Result(Writer, writer.StartError) {
  let spec = case env.get("PHAROS_LOG") {
    None -> ""
    Some(value) -> value
  }
  let parsed_filter = filter.parse_spec(spec)
  let with_trace = case read_bool_env("PHAROS_TRACE_LSP", default_value: False) {
    False -> parsed_filter
    True ->
      filter.Filter(
        default: parsed_filter.default,
        overrides: [
          filter.Override("pharos/lsp/trace", option.Some(Debug)),
          ..parsed_filter.overrides
        ],
      )
  }
  let ring_enabled = read_bool_env("PHAROS_LOG_RING", default_value: True)
  let stderr_enabled = read_bool_env("PHAROS_LOG_STDERR", default_value: True)
  writer.start(with_trace, ring_enabled, stderr_enabled)
}

fn read_bool_env(name: String, default_value default: Bool) -> Bool {
  case env.get(name) {
    None -> default
    Some(raw) ->
      case raw {
        "0" -> False
        "off" -> False
        "false" -> False
        "no" -> False
        _ -> True
      }
  }
}

// -- Default-target API (back-compat with the 33 existing call sites)

pub fn debug(message: String) -> Nil {
  emit(Debug, default_target, message, [])
}

pub fn info(message: String) -> Nil {
  emit(Info, default_target, message, [])
}

pub fn warn(message: String) -> Nil {
  emit(Warn, default_target, message, [])
}

pub fn error(message: String) -> Nil {
  emit(Critical, default_target, message, [])
}

// -- Explicit-target API for new and migrated call sites

pub fn debug_at(target: String, message: String) -> Nil {
  emit(Debug, target, message, [])
}

pub fn info_at(target: String, message: String) -> Nil {
  emit(Info, target, message, [])
}

pub fn warn_at(target: String, message: String) -> Nil {
  emit(Warn, target, message, [])
}

pub fn error_at(target: String, message: String) -> Nil {
  emit(Critical, target, message, [])
}

// -- Field-bearing API

pub fn with_fields(
  level: Level,
  message: String,
  fields: List(#(String, String)),
) -> Nil {
  emit(level, default_target, message, fields)
}

pub fn at_with_fields(
  target: String,
  level: Level,
  message: String,
  fields: List(#(String, String)),
) -> Nil {
  emit(level, target, message, fields)
}

// -- Correlation id API

/// Stamp every subsequent log line emitted by the calling process
/// with `cid=<id>`. Set once per MCP request at the dispatch
/// boundary; clear via `clear_correlation_id/0` once the handler
/// returns. Process-dict-scoped — does not propagate across
/// `process.send` boundaries.
pub fn set_correlation_id(id: String) -> Nil {
  cid_set(id)
}

pub fn clear_correlation_id() -> Nil {
  cid_clear()
}

pub fn correlation_id() -> Option(String) {
  case cid_get() {
    Ok(id) -> Some(id)
    Error(_) -> None
  }
}

/// Adjust the writer's filter for one target at runtime. `level =
/// None` silences the target. Used by the `runtime_log_level` MCP
/// tool.
pub fn set_target_level(
  target_prefix: String,
  level: Option(Level),
) -> Result(Nil, Nil) {
  writer.set_target_global(target_prefix, level)
}

/// Read N most-recent ring buffer entries newest-first, optionally
/// filtered to lines containing `substring_filter`. Returns the
/// raw `(level, line)` tuples ready for serialization. Empty
/// `substring_filter` disables filtering.
pub fn ring_tail(
  n: Int,
  substring_filter: String,
) -> List(#(Level, String)) {
  ring.tail(n, substring_filter)
}

/// Reset the ring buffer.
pub fn ring_clear() -> Nil {
  ring.clear()
}

pub fn ring_size() -> Int {
  ring.size()
}

// -- Internal

fn emit(
  level: Level,
  target: String,
  message: String,
  fields: List(#(String, String)),
) -> Nil {
  let cid = case cid_get() {
    Ok(id) -> id
    Error(_) -> ""
  }
  let log_entry =
    LogEntry(
      timestamp_ms: now_ms(),
      level: level,
      target: target,
      correlation_id: cid,
      message: message,
      fields: fields,
    )
  writer.emit(log_entry)
}

@external(erlang, "pharos_log_ffi", "iso_timestamp_ms")
fn now_ms() -> String

@external(erlang, "pharos_log_ffi", "cid_set")
fn cid_set(id: String) -> Nil

@external(erlang, "pharos_log_ffi", "cid_clear")
fn cid_clear() -> Nil

@external(erlang, "pharos_log_ffi", "cid_get")
fn cid_get() -> Result(String, Nil)
