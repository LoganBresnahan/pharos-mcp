//// ADR-030 S3: per-LSP PID tracking and instance directory.
////
//// Thin Gleam wrapper around `pharos_instance_track_ffi`. The actor
//// that manages each LSP holds onto the `lsp_pid` value returned by
//// `register_lsp/4` and passes it to `deregister_lsp/1` when the LSP
//// is closed.
////
//// See `doc/adr/030-process-lifecycle-hardening.md` for the full
//// rationale.

import pharos/lsp/port.{type Port}

/// Create the per-PID instance directory. Idempotent; safe to call
/// multiple times. No-op if `$HOME` is unset or the directory cannot
/// be created.
@external(erlang, "pharos_instance_track_ffi", "init")
pub fn init() -> Nil

/// Returns the absolute path of this pharos instance's tracking
/// directory. Used by the `pharos cleanup` subcommand to enumerate
/// candidate orphans across all known instances.
@external(erlang, "pharos_instance_track_ffi", "instance_dir")
pub fn instance_dir() -> String

/// Write a tracking file for a freshly-spawned LSP. Call immediately
/// after `port.spawn` returns `Ok(Port)`. Returns the LSP's OS PID
/// (or 0 if `port_info` is unavailable — rare; means the port closed
/// between spawn and this call).
///
/// The returned integer must be stored alongside the Port so
/// `deregister_lsp/1` can find the file when the LSP is closed.
@external(erlang, "pharos_instance_track_ffi", "register_lsp")
pub fn register_lsp(
  port: Port,
  server_id: String,
  resolved_binary: String,
  workspace: String,
) -> Int

/// Remove the tracking file for an LSP. Idempotent; missing files
/// are ignored. Pass 0 to silently no-op (used by call sites that
/// did not capture a valid PID at spawn time).
@external(erlang, "pharos_instance_track_ffi", "deregister_lsp")
pub fn deregister_lsp(lsp_pid: Int) -> Nil

/// Remove the entire instance directory. Call from the pharos
/// application stop callback on graceful exit so `pharos cleanup`
/// does not see this instance as an orphan.
@external(erlang, "pharos_instance_track_ffi", "clear_instance_dir")
pub fn clear_instance_dir() -> Nil

// -- pharos cleanup CLI surface -------------------------------------

/// Return the absolute path of the root tracking directory (one
/// level up from `instance_dir`). Contains one subdir per known
/// pharos PID.
@external(erlang, "pharos_instance_track_ffi", "instances_root")
pub fn instances_root() -> String

/// Return all instance subdirs as `(owner_pid, absolute_path)`.
@external(erlang, "pharos_instance_track_ffi", "list_instance_dirs")
pub fn list_instance_dirs() -> List(#(Int, String))

/// Return `.pid` files inside an instance dir as `(lsp_pid,
/// absolute_path)`.
@external(erlang, "pharos_instance_track_ffi", "list_pid_files")
pub fn list_pid_files(instance_dir: String) -> List(#(Int, String))

/// Parse a tracking file into key/value pairs.
@external(erlang, "pharos_instance_track_ffi", "read_pid_file")
pub fn read_pid_file(path: String) -> List(#(String, String))

/// True when `kill -0 <pid>` succeeds (process exists and we can
/// signal it). False on ESRCH or EPERM.
@external(erlang, "pharos_instance_track_ffi", "is_pid_alive")
pub fn is_pid_alive(pid: Int) -> Bool

/// Read the executable basename for a PID. Empty string if the PID
/// is gone or unreachable.
@external(erlang, "pharos_instance_track_ffi", "process_comm")
pub fn process_comm(pid: Int) -> String

/// Send a signal (one of `"TERM"`, `"KILL"`, `"INT"`) to a PID.
@external(erlang, "pharos_instance_track_ffi", "signal_pid")
pub fn signal_pid(pid: Int, signal: String) -> Result(Nil, Nil)

/// Remove a directory and all its contents recursively. Best-effort:
/// silent on missing dirs, missing files, etc.
@external(erlang, "pharos_instance_track_ffi", "remove_dir_recursive")
pub fn remove_dir_recursive(dir: String) -> Nil

/// Block the caller for `millis` milliseconds. Used by the cleanup
/// CLI between SIGTERM and SIGKILL escalation.
@external(erlang, "pharos_instance_track_ffi", "sleep_ms")
pub fn sleep_ms(millis: Int) -> Nil
