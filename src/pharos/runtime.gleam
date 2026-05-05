//// Runtime introspection — typed wrappers over BEAM BIFs.
////
//// This module is the Gleam-side surface for the M9.5 Part C MCP
//// tools. Every function here is a thin wrapper over a single
//// `pharos_runtime_ffi` call; tool handlers in `pharos/mcp/server`
//// translate the values into JSON for the MCP wire.
////
//// Pids are passed as text (`<0.143.0>`) at every boundary. They
//// are not stable across BEAM restart, so storing them in long-
//// lived state would be a bug. `parse_pid` is the only way to
//// turn text back into a real pid for follow-up introspection.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list

pub type ProcessSummary {
  ProcessSummary(
    pid: String,
    registered_name: String,
    current_function: String,
    message_queue_len: Int,
    memory: Int,
    status: String,
  )
}

pub type EtsTable {
  EtsTable(
    name: String,
    size: Int,
    memory_words: Int,
    owner: String,
    table_type: String,
    protection: String,
  )
}

pub type AppSummary {
  AppSummary(name: String, description: String, version: String)
}

pub type SchedulerSample {
  SchedulerSample(sample_type: String, id: String, utilization: Float)
}

pub type SupervisedNode {
  SupervisedNode(
    pid: String,
    registered_name: String,
    current_function: String,
    kind: String,
  )
}

@external(erlang, "pharos_runtime_ffi", "list_processes")
pub fn list_processes(limit: Int) -> List(ProcessSummary)

@external(erlang, "pharos_runtime_ffi", "process_info_for")
pub fn process_info_for(pid_text: String) -> Result(List(#(String, String)), Nil)

@external(erlang, "pharos_runtime_ffi", "list_ets_tables")
pub fn list_ets_tables() -> List(EtsTable)

@external(erlang, "pharos_runtime_ffi", "memory_breakdown")
pub fn memory_breakdown() -> List(#(String, Int))

@external(erlang, "pharos_runtime_ffi", "list_applications")
pub fn list_applications() -> List(AppSummary)

@external(erlang, "pharos_runtime_ffi", "scheduler_utilization")
pub fn scheduler_utilization(interval_ms: Int) -> List(SchedulerSample)

@external(erlang, "pharos_runtime_ffi", "supervision_tree")
pub fn supervision_tree() -> List(SupervisedNode)

@external(erlang, "pharos_runtime_ffi", "parse_pid")
pub fn parse_pid(text: String) -> Result(Pid, Nil)

@external(erlang, "pharos_runtime_ffi", "pid_to_text")
pub fn pid_to_text(pid: Pid) -> String

/// Result tuple from `recon_trace.calls/2` wrapped via
/// `pharos_runtime_ffi:trace_calls/4`. Pattern wildcards are passed
/// as the atom `'_'` from the Gleam call site via the `wildcard/0`
/// helper.
@external(erlang, "pharos_runtime_ffi", "trace_calls")
pub fn trace_calls(
  module: dynamic.Dynamic,
  function: dynamic.Dynamic,
  arity: dynamic.Dynamic,
  spec: #(Int, Int),
) -> Result(List(String), String)

@external(erlang, "pharos_runtime_ffi", "trace_calls_clear")
pub fn trace_calls_clear() -> Nil

/// The atom `'_'` used as a wildcard for module/function/arity in
/// the trace pattern. Using `dynamic.from(Atom)` would require an
/// atom-creation BIF; this helper avoids the indirection.
@external(erlang, "pharos_runtime_ffi", "wildcard")
pub fn wildcard() -> dynamic.Dynamic

/// Convert a memory-breakdown list to a dict, dropping duplicates by
/// taking the last occurrence (Erlang's memory list never has dup
/// keys, so this just shapes for downstream consumption).
pub fn memory_dict(list: List(#(String, Int))) -> Dict(String, Int) {
  list
  |> list.fold(dict.new(), fn(acc, pair) {
    let #(k, v) = pair
    dict.insert(acc, k, v)
  })
}

pub type DynamicValue =
  Dynamic
