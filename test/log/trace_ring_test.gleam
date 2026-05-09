//// Regression test for the M11 trace-ring fix.
////
//// Before the fix the trace producer (`pharos/lsp/trace.emit`)
//// routed every wire chunk through the writer actor, whose
//// producer-side mailbox-depth gate (`max_mailbox_depth = 1000`)
//// coalesced bursts into a single `dropped=N` warn line —
//// runtime_trace_lsp then saw no actual wire entries. The fix
//// inserts trace entries directly into the ETS ring (lock-free,
//// no mailbox), and exempts the trace target from the writer's
//// own ring fan-out to avoid double-inserts.
////
//// This test fires 5000 trace events back-to-back (5x the writer's
//// mailbox cap) and asserts the ring captured at least the ring's
//// configured capacity.

import gleam/list
import gleam/option.{None, Some}
import pharos/log/entry
import pharos/log/filter.{Filter, Override}
import pharos/log/ring
import pharos/log/writer
import pharos/lsp/trace

pub fn ring_captures_burst_above_mailbox_cap_test() {
  let trace_filter =
    Filter(default: entry.Info, overrides: [
      Override("pharos/lsp/trace", Some(entry.Debug)),
    ])
  let assert Ok(w) = writer.start(trace_filter, True, False, None, None, 3)

  // Ensure the producer cache mirrors "trace on" — set_target_global
  // also handles the persistent_term flip so emit's prefilter passes.
  let assert Ok(Nil) =
    writer.set_target_global("pharos/lsp/trace", Some(entry.Debug))

  // Reset the ring so the test is hermetic with respect to other
  // tests that may have already populated it.
  ring.clear()

  let burst = 5000
  burst_emit(burst)

  // Default ring capacity is 1000; under the fix the ring should
  // reach (or stay near) capacity. Without the fix, it never grows
  // past a few dozen because the writer's mailbox cap drops the rest.
  let cap_lower_bound = 900
  let observed_size = ring.size()
  case observed_size >= cap_lower_bound {
    True -> Nil
    False ->
      panic as {
        "ring captured "
        <> int_str(observed_size)
        <> " entries (expected >= "
        <> int_str(cap_lower_bound)
        <> "); the trace path is still routing through the writer's "
        <> "mailbox-depth cap"
      }
  }

  let entries = ring.tail(2000, "lsp wire")
  case list.length(entries) >= cap_lower_bound {
    True -> Nil
    False -> panic as { "ring tail returned fewer than the cap" }
  }

  writer.stop(w)
}

fn burst_emit(n: Int) -> Nil {
  case n <= 0 {
    True -> Nil
    False -> {
      trace.out(<<"x":utf8>>)
      burst_emit(n - 1)
    }
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_str(n: Int) -> String
