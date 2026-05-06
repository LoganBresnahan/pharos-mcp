//// Gleam-side handle for the Erlang `pharos_lsp_dyn_sup`
//// `simple_one_for_one` supervisor (ADR-017a).
////
//// The actual supervisor is implemented in
//// `src/pharos_lsp_dyn_sup.erl` because gleam_otp's
//// `static_supervisor` does not expose `simple_one_for_one`.
//// This module wraps the Erlang FFI in shapes the rest of the
//// supervised tree expects: `start_link_supervised/0` returns
//// `actor.Started(Nil)` so it slots into the pool subtree as a
//// `supervision.supervisor` child.

import gleam/erlang/process.{type Pid}
import gleam/otp/actor

/// Spawn (or attach to) the Erlang supervisor and return the
/// `actor.Started` shape gleam_otp's child specs consume.
pub fn start_link_supervised() -> Result(
  actor.Started(Nil),
  actor.StartError,
) {
  case raw_start_link() {
    Ok(pid) -> Ok(actor.Started(pid: pid, data: Nil))
    Error(reason) -> Error(actor.InitFailed(reason))
  }
}

@external(erlang, "pharos_lsp_dyn_sup", "start_link")
fn raw_start_link() -> Result(Pid, String)

/// Initialise the `pharos_lsp_proc_subjects` ETS bridge table.
/// Idempotent. Call once at boot before any worker spawn so the
/// supervisor's start_child path (which inserts into this table
/// inside `proc.start_link_supervised`) finds it ready.
@external(erlang, "pharos_runtime_ffi", "lsp_proc_subjects_init")
pub fn init_subjects_bridge() -> Nil
