//// ADR-030 I1: periodic idle heartbeat.
////
//// A standalone process that wakes every `PHAROS_HEARTBEAT_INTERVAL_MS`
//// (default 60_000) milliseconds and writes a single log line with
//// the runtime's memory total and live BEAM process count. The line
//// is plain — the value of the log is the *timeline* it produces:
//// if pharos dies silently mid-idle (failure mode 3 in ADR-030, the
//// pattern that surfaced in Phase 5 attempt 1), the gap in the
//// heartbeat trail tells the operator roughly when memory pressure
//// or scheduler stall took the runtime down.
////
//// Implementation is a plain tail-recursive `process.spawn` loop —
//// no actor, no messages, no supervision tree entry. The process is
//// linked to its caller (the pharos main process) so it dies with
//// pharos; on a hard kill it is reaped with everything else. We do
//// not need failure isolation: if the heartbeat function itself
//// panics we *want* that to surface, not retry silently.

import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import pharos/env
import pharos/log

const default_interval_ms: Int = 60_000

/// Spawn the heartbeat loop in a linked child process. Returns the
/// child Pid (mostly for completeness; nothing else holds it).
pub fn start() -> process.Pid {
  let interval = read_interval()
  process.spawn(fn() { loop(interval) })
}

fn loop(interval_ms: Int) -> Nil {
  emit_heartbeat()
  process.sleep(interval_ms)
  loop(interval_ms)
}

fn emit_heartbeat() -> Nil {
  let mem = memory_total_bytes()
  let procs = beam_process_count()
  log.info_at(
    "pharos/heartbeat",
    "alive memory_bytes="
      <> int.to_string(mem)
      <> " process_count="
      <> int.to_string(procs),
  )
}

fn read_interval() -> Int {
  case env.get("PHAROS_HEARTBEAT_INTERVAL_MS") {
    Some(raw) ->
      case int.parse(raw) {
        Ok(n) if n > 0 -> n
        _ -> default_interval_ms
      }
    None -> default_interval_ms
  }
}

@external(erlang, "pharos_heartbeat_ffi", "memory_total_bytes")
fn memory_total_bytes() -> Int

@external(erlang, "pharos_heartbeat_ffi", "beam_process_count")
fn beam_process_count() -> Int
