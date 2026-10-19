//! Where the daemon for this build lives (ADR-034): the daemon key, the
//! per-user runtime directory, the socket and its sibling files, and
//! the state directory for logs.

use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Env vars that shape a whole daemon rather than one session. Their
/// values join the daemon key, so a session started with, say,
/// `PHAROS_LOG=debug` or a test sandbox with its own `HOME` gets its
/// own daemon instead of silently joining one set up differently.
/// Everything else in a session's env travels in its hello.
pub const DAEMON_KEY_VARS: &[&str] = &[
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "PHAROS_LOG",
    "PHAROS_LOG_FILE",
    "PHAROS_LOG_STDERR",
    "PHAROS_LOG_RING",
    "PHAROS_SASL",
    "PHAROS_TRACE_LSP",
    "PHAROS_HEARTBEAT_INTERVAL_MS",
    "PHAROS_SHUTDOWN_DRAIN_MS",
    "PHAROS_DAEMON_IDLE_SECS",
    "PHAROS_LSP_IDLE_SECS",
    "PHAROS_DAEMON_TEST_OPS",
];

/// 8 hex digits of FNV-1a over the daemon-scoped vars, in
/// `DAEMON_KEY_VARS` order, each as `NAME=value` or `NAME unset`.
pub fn daemon_key(lookup: impl Fn(&str) -> Option<OsString>) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for name in DAEMON_KEY_VARS {
        let entry = match lookup(name) {
            Some(value) => format!("{}={}\0", name, value.to_string_lossy()),
            None => format!("{} unset\0", name),
        };
        for byte in entry.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    format!("{:08x}", (hash ^ (hash >> 32)) as u32)
}

/// Longest socket path we use. `sun_path` holds 104 bytes on macOS and
/// 108 on Linux, NUL included.
const MAX_SOCKET_PATH: usize = 100;

pub struct DaemonPaths {
    pub dir: PathBuf,
    pub socket: PathBuf,
    pub lock: PathBuf,
    pub pid: PathBuf,
}

impl DaemonPaths {
    pub fn new(build_id: &str, key: &str) -> DaemonPaths {
        let name = format!("{}-{}", build_id, key);
        let preferred = runtime_dir();
        let dir = if preferred.join(format!("{}.sock", name)).as_os_str().len() <= MAX_SOCKET_PATH {
            preferred
        } else {
            fallback_runtime_dir()
        };
        DaemonPaths {
            socket: dir.join(format!("{}.sock", name)),
            lock: dir.join(format!("{}.lock", name)),
            pid: dir.join(format!("{}.pid", name)),
            dir,
        }
    }
}

/// The per-user directory holding every daemon's socket:
/// `$PHAROS_RUNTIME_DIR` when set (tests), else `$XDG_RUNTIME_DIR/pharos`
/// on Linux and `$TMPDIR/pharos` on macOS (already per-user), else
/// `/tmp/pharos-<uid>`.
pub fn runtime_dir() -> PathBuf {
    if let Some(dir) = absolute_env("PHAROS_RUNTIME_DIR") {
        return dir;
    }
    let base = if cfg!(target_os = "macos") {
        absolute_env("TMPDIR")
    } else {
        absolute_env("XDG_RUNTIME_DIR")
    };
    match base {
        Some(base) => base.join("pharos"),
        None => fallback_runtime_dir(),
    }
}

fn fallback_runtime_dir() -> PathBuf {
    PathBuf::from(format!("/tmp/pharos-{}", uid()))
}

/// `${XDG_STATE_HOME:-$HOME/.local/state}/pharos/log`, the same dir the
/// BEAM side logs to (`pharos_log_rotate_ffi:log_dir/0`).
pub fn log_dir() -> Option<PathBuf> {
    let state = absolute_env("XDG_STATE_HOME")
        .or_else(|| absolute_env("HOME").map(|home| home.join(".local").join("state")))?;
    Some(state.join("pharos").join("log"))
}

fn absolute_env(name: &str) -> Option<PathBuf> {
    let value = PathBuf::from(env::var_os(name)?);
    if value.is_absolute() {
        Some(value)
    } else {
        None
    }
}

fn uid() -> u32 {
    unsafe { libc::getuid() }
}

/// Create `dir` (and parents) owner-only, then refuse it unless it is a
/// real directory (not a symlink), owned by us, with no group or other
/// access. Directory permissions are the daemon's access control.
pub fn ensure_private_dir(dir: &Path) -> Result<(), String> {
    use std::fs::{self, DirBuilder};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};

    if let Err(e) = DirBuilder::new().recursive(true).mode(0o700).create(dir) {
        return Err(format!("cannot create {}: {}", dir.display(), e));
    }
    let meta = fs::symlink_metadata(dir).map_err(|e| format!("{}: {}", dir.display(), e))?;
    if !meta.file_type().is_dir() {
        return Err(format!("{} is not a directory", dir.display()));
    }
    if meta.uid() != uid() {
        return Err(format!(
            "{} is owned by uid {}, not us ({})",
            dir.display(),
            meta.uid(),
            uid()
        ));
    }
    if meta.mode() & 0o077 != 0 {
        // Refuse rather than tighten: whatever another user put in it
        // while it was open would stay.
        return Err(format!(
            "{} allows group or other access (mode {:o}); remove it or chmod 700 it",
            dir.display(),
            meta.mode() & 0o777
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daemon_key_is_stable_and_eight_hex_digits() {
        let lookup = |name: &str| match name {
            "HOME" => Some(OsString::from("/home/a")),
            _ => None,
        };
        let key = daemon_key(lookup);
        assert_eq!(key.len(), 8);
        assert!(key.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(key, daemon_key(lookup));
    }

    #[test]
    fn daemon_key_splits_on_a_daemon_scoped_var() {
        let plain = daemon_key(|_| None);
        let debug = daemon_key(|name| (name == "PHAROS_LOG").then(|| OsString::from("debug")));
        let other_home = daemon_key(|name| (name == "HOME").then(|| OsString::from("/sandbox")));
        assert_ne!(plain, debug);
        assert_ne!(plain, other_home);
    }

    #[test]
    fn daemon_key_ignores_session_scoped_vars() {
        // Only DAEMON_KEY_VARS are ever looked up.
        let seen = std::cell::RefCell::new(Vec::new());
        daemon_key(|name| {
            seen.borrow_mut().push(name.to_string());
            None
        });
        assert!(!seen
            .borrow()
            .iter()
            .any(|n| n == "PATH" || n == "PHAROS_TOOLS"));
    }

    #[test]
    fn an_empty_value_differs_from_unset() {
        assert_ne!(
            daemon_key(|_| None),
            daemon_key(|name| (name == "PHAROS_LOG").then(OsString::new)),
        );
    }

    #[test]
    fn a_long_runtime_dir_falls_back_to_tmp() {
        let long = "/x".repeat(60);
        env::set_var("PHAROS_RUNTIME_DIR", &long);
        let paths = DaemonPaths::new("0123456789abcdef", "01234567");
        env::remove_var("PHAROS_RUNTIME_DIR");
        assert!(paths.socket.to_string_lossy().starts_with("/tmp/pharos-"));
        assert!(paths.socket.as_os_str().len() <= MAX_SOCKET_PATH);
        assert_eq!(paths.lock.extension().unwrap(), "lock");
        assert_eq!(paths.pid.extension().unwrap(), "pid");
    }

    #[test]
    fn private_dir_is_created_owner_only_and_an_open_one_refused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = env::temp_dir().join(format!("pharos-shim-private-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        ensure_private_dir(&dir).unwrap();
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(ensure_private_dir(&dir).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_symlinked_dir_is_refused() {
        let base = env::temp_dir().join(format!("pharos-shim-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("real")).unwrap();
        std::os::unix::fs::symlink(base.join("real"), base.join("link")).unwrap();
        assert!(ensure_private_dir(&base.join("link")).is_err());
        std::fs::remove_dir_all(&base).unwrap();
    }
}
