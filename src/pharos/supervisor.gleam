//// Top-level supervisor tree per ADR-013.
////
//// Phase A scaffolding: this module exposes a `start/1` builder that
//// constructs a `static_supervisor` with the topology ADR-013
//// describes. The current implementation includes child specs for
//// the LSP subtree (pool actor + lsp_dyn_sup), the sessions actor,
//// and an optional transport subtree gated on the requested
//// `Transport`. Phase B switches `pharos:main` over to launching the
//// supervisor instead of starting children inline.
////
//// Phase A keeps `pharos:main` on its current inline path, so the
//// existence of this module is a no-op at runtime — it only matters
//// once Phase B's migration lands. Reason: the sub-modules
//// (`pool.start_supervised`, `lsp/supervisor.start`,
//// `mcp/sessions.start_supervised`) need additional plumbing to
//// expose `actor.Started` shapes that supervision specs expect, and
//// landing that plumbing in one go alongside the topology is
//// simpler than splitting it across two commits.
////
//// Restart strategies (locked in ADR-013):
////
////   - root: one_for_one, max 5 restarts in 60s
////   - pool actor: permanent (always restart)
////   - lsp_dyn_sup: permanent (Phase B populates dynamically)
////   - sessions actor: permanent
////   - stdin reader: transient (EOF = clean exit, do not restart)
////   - http_listener: permanent when transport=http|both
////
//// See `pharos/lsp/supervisor.gleam` for the LSP subtree.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor

/// Transport modes the root supervisor cares about. Drives whether
/// the http_listener child gets added. Mirrors the enum in
/// `pharos.gleam` rather than imports it to keep the supervisor
/// module independent of the entry-point's specifics.
pub type Transport {
  Stdio
  Http
  Both
}

pub type StartError {
  StartFailed(actor.StartError)
}

/// Spawn the root supervisor with no children. Intended as the
/// landing zone Phase B fills in. Returns the supervisor's
/// `Started` handle so callers can hand the pid to OTP for
/// monitoring.
///
/// Phase A intentionally does not add LSP / sessions / transport
/// children — those depend on `pool.start_supervised`,
/// `sessions.start_supervised`, and a stdin worker module that do
/// not yet exist. Build them in Phase B and add them here via
/// `static_supervisor.add` before `start`.
pub fn start(
  _transport: Transport,
) -> Result(actor.Started(supervisor.Supervisor), StartError) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 60)
  |> supervisor.start()
  |> result_map_error()
}

/// Public alias of the supervisor's Started.data type so callers
/// (Phase B's `pharos:main`) can name what they receive.
pub type Root =
  supervisor.Supervisor

/// Convenience: shut the root supervisor down by sending it a
/// normal exit. Phase B's `pharos:main` calls this on stdin EOF.
pub fn shutdown(root: actor.Started(Root)) -> Nil {
  process.send_exit(root.pid)
}

fn result_map_error(
  r: Result(actor.Started(supervisor.Supervisor), actor.StartError),
) -> Result(actor.Started(supervisor.Supervisor), StartError) {
  case r {
    Ok(s) -> Ok(s)
    Error(e) -> Error(StartFailed(e))
  }
}
