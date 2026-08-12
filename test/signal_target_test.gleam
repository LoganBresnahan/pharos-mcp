//// Tests for the process-group kill path in `pharos_instance_track_ffi`.
////
//// Why this file exists: `pharos cleanup` reaps orphaned LSPs by
//// signalling them, and a bare `kill <lsp_pid>` reaches only the LSP
//// itself. jdtls and metals both spawn helper processes; a grandchild
//// that reparents to init is structurally unreachable from a
//// process-tree walk, so it survives forever (ADR-030 failure mode 4).
//// Signalling the process GROUP fixes that.
////
//// It is also the riskiest code in the cleanup path: `kill -TERM -0`
//// means "signal my own process group", i.e. pharos killing itself and
//// every sibling. The guards in `signal_target/1` exist to make that
//// unreachable, and the first test below is the one that keeps them
//// honest.

import gleam/erlang/process
import gleeunit/should
import pharos/lsp/instance_track

@external(erlang, "pharos_signal_test_support", "own_os_pid")
fn own_os_pid() -> Int

@external(erlang, "pharos_signal_test_support", "signal_target")
fn signal_target(pid: Int) -> Int

/// Returns `#(child_pid, grandchild_pid)`, or `#(0, 0)` if the spawn
/// never reported (treated as a skip rather than a failure — a CI
/// sandbox without `/bin/sh` job control shouldn't fail the suite).
@external(erlang, "pharos_signal_test_support", "spawn_child_with_grandchild")
fn spawn_child_with_grandchild() -> #(Int, Int)

// -- the safety property ------------------------------------------------

/// pharos must NEVER group-signal its own process group. If it did,
/// `pharos cleanup` would kill the very pharos running it — and, when
/// pharos shares a group with its MCP host, the host too.
///
/// This holds by two different routes depending on how the BEAM was
/// launched, which is why the assertion is on the sign rather than on
/// which guard fired: if the BEAM leads its own group, the
/// `Pgid =/= OwnPgid` guard rejects it; if it does not, the
/// `Pgid =:= Pid` guard rejects it first. Either way the answer must
/// be a bare, positive pid.
pub fn signal_target_never_targets_own_group_test() {
  let own = own_os_pid()
  should.be_true(own > 0)
  should.equal(signal_target(own), own)
}

/// A pid that leads no group we can read (nonexistent process) must
/// fall back to the bare pid. Falling back is never unsafe — only
/// incomplete — whereas guessing a group id is how you signal an
/// unrelated process that merely happens to be numbered the same.
pub fn signal_target_falls_back_when_pgid_unreadable_test() {
  // Above the default pid_max on Linux and macOS, so it cannot exist.
  let nonexistent = 4_294_967_000
  should.equal(signal_target(nonexistent), nonexistent)
}

// -- the behaviour it buys ----------------------------------------------

/// An LSP pharos spawns comes back as its own session and group leader,
/// because BEAM's `erl_child_setup` already calls `setsid()` on every
/// port child. So the group path is the one that fires in production,
/// and `signal_target` should return the negated pid.
///
/// This is the assertion that documents *why pharos needs no external
/// setsid wrapper* — if a future OTP changed that behaviour, this test
/// fails and the group-kill fix silently regressing is caught here.
pub fn spawned_child_leads_its_own_group_test() {
  case spawn_child_with_grandchild() {
    #(0, 0) -> Nil
    #(child, _grandchild) -> {
      should.be_true(child > 0)
      should.equal(signal_target(child), -child)
      let _ = instance_track.signal_pid(child, "KILL")
      Nil
    }
  }
}

/// The end-to-end property: signalling the leader reaps the grandchild.
/// Before the group fix this failed — the grandchild outlived the kill.
pub fn group_signal_reaps_grandchild_test() {
  case spawn_child_with_grandchild() {
    #(0, 0) -> Nil
    #(child, grandchild) -> {
      // The grandchild is alive to begin with, or the test proves nothing.
      should.be_true(instance_track.is_pid_alive(grandchild))

      let _ = instance_track.signal_pid(child, "KILL")
      process.sleep(300)

      should.be_false(instance_track.is_pid_alive(grandchild))
    }
  }
}
