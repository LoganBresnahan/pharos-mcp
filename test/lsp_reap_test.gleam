//// ADR-037: reaping an LSP's process group once pharos is done with it.
////
//// Measured before this existed: after the daemon stopped or died,
//// rust-analyzer's in-flight `cargo check` and its build script lived
//// on in rust-analyzer's process group (120 s and counting), because
//// the LSP itself exits on stdin EOF and nothing signalled its group.
//// These tests drive `reap_group/4` against real process groups: a
//// /bin/sh port child stands in for the LSP, since erl_child_setup
//// setsid()s it exactly as it does an LSP.

import gleam/erlang/process
import gleam/string
import gleeunit/should
import pharos/lsp/instance_track

@external(erlang, "pharos_signal_test_support", "spawn_script")
fn spawn_script(script: String) -> #(Int, Int)

@external(erlang, "pharos_instance_track_ffi", "reap_group")
fn reap_group(pgid: Int, start: String, grace_ms: Int, term_wait_ms: Int) -> List(Atom)

@external(erlang, "pharos_instance_track_ffi", "process_start")
fn process_start(pid: Int) -> String

type Atom

@external(erlang, "erlang", "length")
fn length(l: List(Atom)) -> Int

@external(erlang, "erlang", "system_time")
fn now_ms_raw(unit: Unit) -> Int

type Unit {
  Millisecond
}

fn now_ms() -> Int {
  now_ms_raw(Millisecond)
}

/// The leak itself: the leader exits and a child that ignores TERM
/// stays in its group. Reaping signals the members by pid (the leader
/// is gone) and escalates to KILL.
pub fn reap_kills_what_an_exited_leader_left_in_its_group_test() {
  case spawn_script("(trap '' TERM; exec sleep 60) & echo $$ $!; exit 0") {
    #(0, 0) -> Nil
    #(leader, child) -> {
      process.sleep(200)
      should.be_false(instance_track.is_pid_alive(leader))
      should.be_true(instance_track.is_pid_alive(child))
      should.equal(instance_track.group_members(leader), [child])

      let sent = reap_group(leader, "", 200, 300)
      should.equal(length(sent), 2)
      process.sleep(100)
      should.be_false(instance_track.is_pid_alive(child))
      should.equal(instance_track.group_members(leader), [])
    }
  }
}

/// A group that empties by itself within the grace period gets no
/// signal at all: most LSPs exit on EOF in milliseconds.
pub fn reap_sends_nothing_to_a_group_that_empties_by_itself_test() {
  case spawn_script("sleep 0.3 & echo $$ $!; wait") {
    #(0, 0) -> Nil
    #(leader, _child) -> {
      let start = process_start(leader)
      let t0 = now_ms()
      should.equal(length(reap_group(leader, start, 3000, 300)), 0)
      should.be_true(now_ms() - t0 < 2500)
      should.equal(instance_track.group_members(leader), [])
    }
  }
}

/// A live leader that is ours: the whole group gets TERM, and that is
/// enough.
pub fn reap_terms_a_live_group_test() {
  case spawn_script("sleep 30 & echo $$ $!; sleep 30") {
    #(0, 0) -> Nil
    #(leader, child) -> {
      let start = process_start(leader)
      should.equal(length(reap_group(leader, start, 100, 2000)), 1)
      process.sleep(100)
      should.be_false(instance_track.is_pid_alive(leader))
      should.be_false(instance_track.is_pid_alive(child))
    }
  }
}

/// Pid reuse: a live process under the recorded pid that started at a
/// different time is somebody else's. Nothing is signalled.
pub fn reap_leaves_a_reused_pid_alone_test() {
  case spawn_script("sleep 30 & echo $$ $!; sleep 30") {
    #(0, 0) -> Nil
    #(leader, child) -> {
      should.equal(
        length(reap_group(leader, "Thu Jan  1 00:00:00 1970", 100, 100)),
        0,
      )
      should.be_true(instance_track.is_pid_alive(leader))
      should.be_true(instance_track.is_pid_alive(child))
      let _ = instance_track.signal_pid(leader, "KILL")
      Nil
    }
  }
}

/// No start time recorded and the leader alive: nothing proves the
/// group is ours (records from before ADR-037 can be months old), so
/// nothing is signalled.
pub fn reap_leaves_an_unverifiable_live_group_alone_test() {
  case spawn_script("sleep 30 & echo $$ $!; sleep 30") {
    #(0, 0) -> Nil
    #(leader, child) -> {
      should.equal(length(reap_group(leader, "", 100, 100)), 0)
      should.be_true(instance_track.is_pid_alive(leader))
      should.be_true(instance_track.is_pid_alive(child))
      let _ = instance_track.signal_pid(leader, "KILL")
      Nil
    }
  }
}

/// The start identity is stable for one live process and empty once it
/// is gone. On Linux it must not come from `ps -o lstart`, which follows
/// wall-clock adjustments (one live process read 2 s apart on WSL), so a
/// live leader would look like a reused pid and never be signalled.
pub fn process_start_is_stable_and_empty_when_gone_test() {
  case spawn_script("sleep 30 & echo $$ $!; sleep 30") {
    #(0, 0) -> Nil
    #(leader, child) -> {
      let start = process_start(leader)
      should.not_equal(start, "")
      process.sleep(1100)
      should.equal(process_start(leader), start)
      case os_family() {
        Linux -> should.equal(string.starts_with(start, "linux:"), True)
        _ -> Nil
      }
      let _ = instance_track.signal_pid(child, "KILL")
      let _ = instance_track.signal_pid(leader, "KILL")
      process.sleep(200)
      should.equal(process_start(child), "")
    }
  }
}

type OsFamily {
  Linux
  Other
}

fn os_family() -> OsFamily {
  case os_type() {
    #(_, "linux") -> Linux
    _ -> Other
  }
}

@external(erlang, "pharos_signal_test_support", "os_type")
fn os_type() -> #(String, String)
