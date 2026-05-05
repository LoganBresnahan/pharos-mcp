//// Smoke tests for `pharos/lsp/supervisor` Phase A scaffolding.
////
//// Phase A's supervisors are empty (no children); the test surface
//// is small. Verify each `start_*` returns Ok, the returned process
//// is alive, and shutting it down via `process.send_exit` actually
//// terminates it. Phase B adds child-restart tests once children
//// exist.

import gleam/erlang/process
import gleeunit/should
import pharos/lsp/supervisor

pub fn start_pool_subtree_returns_alive_pid_test() {
  let assert Ok(started) = supervisor.start_pool_subtree()
  process.is_alive(started.pid) |> should.be_true
  process.send_exit(started.pid)
}

pub fn start_lsp_dyn_sup_returns_alive_pid_test() {
  let assert Ok(started) = supervisor.start_lsp_dyn_sup()
  process.is_alive(started.pid) |> should.be_true
  process.send_exit(started.pid)
}
