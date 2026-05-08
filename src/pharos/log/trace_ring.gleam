//// Always-on bounded ring for LSP wire-trace events.
////
//// Sibling of `pharos/log/ring` (the main log ring backing
//// `runtime_log_tail`) but dedicated to `pharos/lsp/trace` events.
//// Split exists so `runtime_trace_lsp` can capture wire events that
//// fired BEFORE the tool toggled the trace filter — the parallel
//// race where a concurrent hover's first emit beats the trace
//// activation's persistent_term update.
////
//// Producer (`pharos/lsp/trace`) writes here UNCONDITIONALLY; the
//// gating it does for `pharos/log/ring` (skip when filter is off)
//// does not apply. Cost is one ETS insert per wire chunk in
//// production; bounded ring keeps memory predictable.

import pharos/log/entry.{type Level}

pub const default_capacity: Int = 100

@external(erlang, "pharos_trace_ring_ffi", "init")
pub fn init(cap: Int) -> Nil

@external(erlang, "pharos_trace_ring_ffi", "insert")
pub fn insert(line: String, level: Level) -> Nil

@external(erlang, "pharos_trace_ring_ffi", "tail")
pub fn tail(n: Int, filter: String) -> List(#(Level, String))

@external(erlang, "pharos_trace_ring_ffi", "clear")
pub fn clear() -> Nil

@external(erlang, "pharos_trace_ring_ffi", "size")
pub fn size() -> Int
