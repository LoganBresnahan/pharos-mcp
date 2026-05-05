//// LSP subtree supervisor per ADR-013.
////
//// Phase A scaffolding: this module exposes a `start_pool_subtree/0`
//// builder that constructs a `static_supervisor` with the topology
//// ADR-013 describes for the pool subtree. Phase B fills in
//// children once pool.start and a future `lsp_dyn_sup` expose the
//// `actor.Started` shapes that supervision specs need.
////
//// The LSP subtree shape:
////
////     pool_subtree_sup (rest_for_one, permanent)
////      ├─ pool actor (permanent)
////      └─ lsp_dyn_sup (one_for_one, permanent)
////         ├─ lsp_proc (rust)            (transient)
////         ├─ lsp_proc (go)              (transient)
////         ├─ lsp_proc (typescript)      (transient)
////         └─ lsp_proc (python)          (transient)
////
//// `rest_for_one` couples the pool actor with the dyn_sup: a pool
//// crash restarts both, because the dyn_sup's children (lsp_procs)
//// are addressed via pool's cache and would leak if the pool came
//// back without them.

import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor

pub type StartError {
  StartFailed(actor.StartError)
}

/// Spawn the pool-subtree supervisor with no children. Phase B adds
/// the pool actor and `lsp_dyn_sup` here.
pub fn start_pool_subtree() -> Result(
  actor.Started(supervisor.Supervisor),
  StartError,
) {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 60)
  |> supervisor.start()
  |> result_map_error()
}

/// Spawn the dynamic-supervisor that hosts individual `lsp_proc`
/// children. Empty in Phase A; Phase B's pool.spawn_lsp_proc adds
/// children dynamically via `static_supervisor.start_child_callback`
/// (the equivalent of OTP's `:simple_one_for_one` start_child).
pub fn start_lsp_dyn_sup() -> Result(
  actor.Started(supervisor.Supervisor),
  StartError,
) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 60)
  |> supervisor.start()
  |> result_map_error()
}

fn result_map_error(
  r: Result(actor.Started(supervisor.Supervisor), actor.StartError),
) -> Result(actor.Started(supervisor.Supervisor), StartError) {
  case r {
    Ok(s) -> Ok(s)
    Error(e) -> Error(StartFailed(e))
  }
}
