//// Ring buffer sink — bounded in-memory log store backing the
//// `runtime_log_tail` MCP tool (Part C). Writer actor inserts every
//// emitted entry; oldest entry evicts when at capacity.
////
//// Default capacity is 1000 lines (~256kb at typical entry size).
//// Capacity is fixed at `init/1`; resizing is not supported (re-init
//// would require draining first, and changing capacity at runtime
//// is not a use case yet).

import pharos/log/entry.{type Level}

pub const default_capacity: Int = 1000

/// Initialise the ETS table backing the ring with capacity `cap`.
/// Idempotent — calling more than once leaves the table alone.
@external(erlang, "pharos_log_ffi", "ring_init")
pub fn init(cap: Int) -> Nil

/// Append one already-formatted line tagged with its level.
@external(erlang, "pharos_log_ffi", "ring_insert")
pub fn insert(line: String, level: Level) -> Nil

/// Read the last `n` entries, newest first. When `filter` is empty
/// no substring filtering is applied; otherwise only lines containing
/// the substring are returned.
@external(erlang, "pharos_log_ffi", "ring_tail")
pub fn tail(n: Int, filter: String) -> List(#(Level, String))

/// Read the last `n` entries from a target-prefix subtree, newest
/// first. `prefix` matches the rendered line's `<level> <target>`
/// segment via the leading-space anchor — `pharos/tool_config`
/// catches `pharos/tool_config/autotune` and any other module under
/// that subtree. Used by digest tools that grep autotune events
/// from the buffer (ADR 022). False positives are possible if a
/// message body literally contains ` <prefix>`; cheaper than
/// teaching the ring about target as a separate column.
pub fn tail_by_target_prefix(
  n: Int,
  prefix: String,
) -> List(#(Level, String)) {
  tail(n, " " <> prefix)
}

@external(erlang, "pharos_log_ffi", "ring_clear")
pub fn clear() -> Nil

@external(erlang, "pharos_log_ffi", "ring_size")
pub fn size() -> Int
