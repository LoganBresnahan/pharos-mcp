//// Top-level supervisor tree per ADR-013 + ADR-017.
////
//// Boots in this order:
////
////   pharos_root (one_for_one)
////     ├─ log_subtree (rest_for_one)
////     │   ├─ ring_keeper        (permanent)
////     │   └─ log_writer         (permanent)
////     ├─ pool_subtree (rest_for_one)
////     │   ├─ pool_actor         (permanent)
////     │   └─ lsp_dyn_sup_stub   (permanent — structural only)
////     ├─ sessions_actor         (permanent)         ◄── HTTP/Both
////     ├─ http_listener_subtree  (permanent)         ◄── HTTP/Both
////     └─ stdio_worker           (transient)        ◄── Stdio/Both
////
//// Restart strategies are per ADR-013/017. `intensity 5 / period 60`
//// applies to every internal supervisor: 5 child failures in 60s
//// shuts the whole tree down so the BEAM (or external supervisor:
//// systemd, Burrito wrapper, MCP host) can restart pharos fresh
//// instead of thrashing.

import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

import pharos/log/filter
import pharos/log/ring_keeper
import pharos/log/writer
import pharos/lsp/dyn_sup
import pharos/lsp/pool
import pharos/mcp/http
import pharos/mcp/sessions
import pharos/stdio_worker

/// Transport modes the root supervisor cares about.
pub type Transport {
  Stdio
  Http
  Both
}

pub type StartError {
  StartFailed(actor.StartError)
}

/// Configuration for the supervised tree. Caller (pharos.main)
/// passes the resolved values; the supervisor does not touch the
/// environment directly.
pub type Config {
  Config(
    transport: Transport,
    log_filter: filter.Filter,
    log_ring_enabled: Bool,
    log_stderr_enabled: Bool,
    log_file_path: Option(String),
    http_port: Int,
    http_bind: String,
  )
}

/// Spawn the root supervisor with the children appropriate for
/// the requested transport. Returns the supervisor's `Started`
/// handle so callers can hand the pid to OTP for monitoring.
pub fn start(
  config: Config,
) -> Result(actor.Started(supervisor.Supervisor), StartError) {
  let log_subtree =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(supervision.worker(ring_keeper.start_supervised))
    |> supervisor.add(supervision.worker(fn() {
      writer.start_supervised(
        config.log_filter,
        config.log_ring_enabled,
        config.log_stderr_enabled,
        config.log_file_path,
      )
    }))

  let pool_subtree =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(supervision.worker(pool.start_supervised))
    |> supervisor.add(supervision.supervisor(dyn_sup.start_link_supervised))

  let root =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(supervision.supervisor(fn() { supervisor.start(log_subtree) }))
    |> supervisor.add(supervision.supervisor(fn() { supervisor.start(pool_subtree) }))

  // HTTP-only children (sessions + listener). Boot order matters:
  // sessions must register its global before the listener starts
  // accepting connections that reference it.
  let root_with_http = case config.transport {
    Stdio -> root
    Http | Both ->
      root
      |> supervisor.add(supervision.worker(sessions.start_supervised))
      |> supervisor.add(supervision.worker(fn() {
        case pool.global(), sessions.global() {
          Ok(p), Ok(s) ->
            http.start_supervised(p, s, config.http_port, config.http_bind)
          _, _ -> Error(actor.InitFailed("pool/sessions global lookup failed"))
        }
      }))
  }

  // stdio_worker is transient — stdin EOF returns actor.stop()
  // and we want the tree to NOT restart it (clean exit). Also
  // last in the boot order so pool.global() is populated by the
  // time the worker's initialiser runs.
  let root_complete = case config.transport {
    Http -> root_with_http
    Stdio | Both ->
      root_with_http
      |> supervisor.add(transient_worker(stdio_worker.start_supervised))
  }

  case supervisor.start(root_complete) {
    Ok(s) -> Ok(s)
    Error(e) -> Error(StartFailed(e))
  }
}

/// Convenience: shut the root supervisor down by sending it a
/// normal exit. `pharos.main` calls this on stdin EOF (Stdio
/// transport's clean-exit signal).
pub fn shutdown(
  root: actor.Started(supervisor.Supervisor),
) -> Nil {
  process.send_exit(root.pid)
}

fn transient_worker(
  start: fn() -> Result(actor.Started(data), actor.StartError),
) -> supervision.ChildSpecification(data) {
  supervision.worker(start)
  |> supervision.restart(supervision.Transient)
}
