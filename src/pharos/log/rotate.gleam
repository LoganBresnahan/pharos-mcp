//// ADR-030 C2: session-log default path + LRU rotation.
////
//// Thin Gleam wrapper around `pharos_log_rotate_ffi`. Pharos calls
//// `migrate_cwd_crash_dump`, `rotate_sessions`, and
//// `rotate_crash_dumps` once at boot so old logs do not accumulate
//// indefinitely. `default_session_log_path` is consulted from the
//// config layer when the user has not set `PHAROS_LOG_FILE` so each
//// pharos instance writes to its own readable, timestamped file.

import gleam/option.{type Option}

const default_session_keep: Int = 10

const default_crash_dump_keep: Int = 5

/// Returns the auto-default per-PID per-timestamp session log path
/// under the log dir, `${XDG_STATE_HOME:-$HOME/.local/state}/pharos/log/`,
/// or `None` if neither is set (best-effort fallback to nothing —
/// file logging is optional).
@external(erlang, "pharos_log_rotate_ffi", "default_session_log_path")
pub fn default_session_log_path() -> Option(String)

/// Returns the absolute path of the log dir, or empty string when
/// neither XDG_STATE_HOME nor HOME is set. Exposed mostly for diagnostics; callers
/// usually go through the other helpers.
@external(erlang, "pharos_log_rotate_ffi", "log_cache_dir")
pub fn log_cache_dir() -> String

/// LRU-trim files matching `<prefix>*` under the cache dir down to
/// `keep` newest. Best-effort.
@external(erlang, "pharos_log_rotate_ffi", "rotate_lru")
fn rotate_lru(prefix: String, keep: Int) -> Int

/// Convenience: keep the 10 newest `session-*.log` files.
pub fn rotate_sessions() -> Int {
  rotate_lru("session-", default_session_keep)
}

/// Convenience: keep the 5 newest `erl_crash-*.dump` files.
pub fn rotate_crash_dumps() -> Int {
  rotate_lru("erl_crash-", default_crash_dump_keep)
}

/// If a legacy `erl_crash.dump` exists in cwd, move it under the
/// cache dir with an mtime-stamped name so the next LRU sweep picks
/// it up.
@external(erlang, "pharos_log_rotate_ffi", "migrate_cwd_crash_dump")
pub fn migrate_cwd_crash_dump() -> Nil

/// Tighten crash dumps and crash logs in the log dir to `0600`.
@external(erlang, "pharos_log_rotate_ffi", "secure_crash_files")
pub fn secure_crash_files() -> Nil

/// Apply both `migrate_cwd_crash_dump` and the two `rotate_*` sweeps
/// in one call. Use from `pharos:boot/0` to keep the cache dir tidy.
pub fn boot_sweep() -> Nil {
  migrate_cwd_crash_dump()
  let _ = rotate_sessions()
  let _ = rotate_lru("daemon-", default_session_keep)
  let _ = rotate_crash_dumps()
  secure_crash_files()
}
