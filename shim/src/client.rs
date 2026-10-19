//! The MCP stdio shim (ADR-034, Unix): find or start the daemon for
//! this build and daemon key, introduce this session with the hello,
//! then relay bytes until the client closes stdin.
//!
//! Only daemon bytes received after the ack reach stdout, and only
//! whole lines: a daemon dying mid-frame must never leave half a
//! JSON-RPC message on the client's stdout. Every diagnostic goes to
//! stderr.

use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::json;
use crate::launch;
use crate::paths::{self, DaemonPaths};
use crate::release::Release;

pub enum Outcome {
    /// The session ran (or failed after it started); exit with this.
    Exit(i32),
    /// No daemon could be reached before any MCP byte was read; the
    /// caller may fall back to direct mode.
    Unreachable(String),
}

/// Largest ack line accepted from the daemon.
const MAX_ACK_BYTES: usize = 64 * 1024;

/// After stdin closes, how long to keep relaying replies still in
/// flight before exiting.
const STDIN_EOF_GRACE: Duration = Duration::from_secs(3);

pub fn run(release: &Release) -> Outcome {
    let key = paths::daemon_key(|name| env::var_os(name));
    let paths = DaemonPaths::new(&release.build_id, &key);
    if let Err(reason) = paths::ensure_private_dir(&paths.dir) {
        return Outcome::Unreachable(reason);
    }
    let stream = match UnixStream::connect(&paths.socket) {
        Ok(stream) => stream,
        Err(_) => match start_or_join(release, &paths, &key) {
            Ok(stream) => stream,
            Err(reason) => return Outcome::Unreachable(reason),
        },
    };
    let leftover = match hello(&stream, release) {
        Ok(leftover) => leftover,
        Err(reason) => return Outcome::Unreachable(reason),
    };
    Outcome::Exit(relay(stream, leftover))
}

fn start_timeout() -> Duration {
    let ms = env::var("PHAROS_DAEMON_START_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(15_000);
    Duration::from_millis(ms)
}

/// Under the spawn lock: connect if another shim got there first, wait
/// for a live daemon that is slow to accept, or replace a stale socket
/// and start one. N shims starting at once get exactly one daemon.
fn start_or_join(release: &Release, paths: &DaemonPaths, key: &str) -> Result<UnixStream, String> {
    let deadline = Instant::now() + start_timeout();
    let _lock = lock(&paths.lock, deadline)?;
    if let Ok(stream) = UnixStream::connect(&paths.socket) {
        return Ok(stream);
    }
    if let Some(pid) = read_pid(&paths.pid).filter(|pid| is_our_daemon(*pid, &paths.socket)) {
        // A live daemon slow to accept: wait for it. If it exits instead
        // (it was stopping), fall through and replace it.
        if let Ok(stream) = wait_for_accept(&paths.socket, pid, deadline) {
            return Ok(stream);
        }
    }
    let _ = fs::remove_file(&paths.socket);
    let _ = fs::remove_file(&paths.pid);
    let daemon_pid = spawn_daemon(release, paths, key)?;
    wait_for_accept(&paths.socket, daemon_pid, deadline)
}

/// An exclusive `flock` on `path`, waiting at most until `deadline`.
/// Released when the returned file is dropped. The fd is close-on-exec,
/// so a daemon this shim spawns never holds it.
fn lock(path: &Path, deadline: Instant) -> Result<File, String> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| format!("cannot open {}: {}", path.display(), e))?;
    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(file);
        }
        if Instant::now() >= deadline {
            return Err(format!("timed out waiting for {}", path.display()));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn read_pid(path: &Path) -> Option<i32> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn alive(pid: i32) -> bool {
    pid > 0
        && (unsafe { libc::kill(pid, 0) } == 0
            || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM))
}

/// `pid` is alive and its command line is the daemon for `socket`, not
/// an unrelated process that reused the pid.
fn is_our_daemon(pid: i32, socket: &Path) -> bool {
    if !alive(pid) {
        return false;
    }
    let socket = socket.to_string_lossy();
    command_line(pid).is_some_and(|cmd| cmd.contains("daemon") && cmd.contains(socket.as_ref()))
}

#[cfg(target_os = "linux")]
fn command_line(pid: i32) -> Option<String> {
    let raw = fs::read(format!("/proc/{}/cmdline", pid)).ok()?;
    Some(String::from_utf8_lossy(&raw).replace('\0', " "))
}

#[cfg(not(target_os = "linux"))]
fn command_line(pid: i32) -> Option<String> {
    let out = std::process::Command::new("ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Poll-connect until the daemon accepts, it dies, or `deadline`.
fn wait_for_accept(
    socket: &Path,
    daemon_pid: i32,
    deadline: Instant,
) -> Result<UnixStream, String> {
    loop {
        if let Ok(stream) = UnixStream::connect(socket) {
            return Ok(stream);
        }
        if !alive(daemon_pid) {
            return Err(format!(
                "the daemon (pid {}) exited before it accepted connections",
                daemon_pid
            ));
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "the daemon did not accept connections within {:?}",
                start_timeout()
            ));
        }
        thread::sleep(Duration::from_millis(20));
    }
}

/// Start the daemon detached: a new session (`setsid`), stdin from
/// `/dev/null`, stdout and stderr appended to its boot log, every
/// inherited fd from 3 up marked close-on-exec so a daemon outliving
/// this session holds none of the client's fds, and, where a systemd
/// user manager runs, in its own scope so tearing down the client's or
/// the terminal's scope cannot take it along. Returns the daemon's pid.
fn spawn_daemon(release: &Release, paths: &DaemonPaths, key: &str) -> Result<i32, String> {
    let log_dir = paths::log_dir();
    let boot_log = match &log_dir {
        Some(dir) => {
            paths::ensure_private_dir(dir)?;
            let path = dir.join(format!("daemon-{}-{}.boot.log", release.build_id, key));
            if fs::metadata(&path)
                .map(|m| m.len() > 1024 * 1024)
                .unwrap_or(false)
            {
                let _ = fs::remove_file(&path);
            }
            OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(&path)
                .map_err(|e| format!("cannot open {}: {}", path.display(), e))?
        }
        None => File::create("/dev/null").map_err(|e| e.to_string())?,
    };
    let boot_log_err = boot_log.try_clone().map_err(|e| e.to_string())?;

    let daemon_args = launch::daemon_args(&paths.socket, &release.build_id, key);
    let mut cmd = launch::beam_command(release, &daemon_args);
    if let Some(dir) = &log_dir {
        cmd.env(
            "ERL_CRASH_DUMP",
            dir.join(format!(
                "erl_crash-daemon-{}-{}-{}.dump",
                release.build_id,
                key,
                unix_secs()
            )),
        );
    }
    if use_systemd_run() {
        let inner = cmd;
        let mut scoped = std::process::Command::new("systemd-run");
        scoped.args(["--user", "--scope", "--quiet", "--collect", "--"]);
        scoped.arg(inner.get_program()).args(inner.get_args());
        for (name, value) in inner.get_envs() {
            match value {
                Some(value) => scoped.env(name, value),
                None => scoped.env_remove(name),
            };
        }
        cmd = scoped;
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::from(boot_log))
        .stderr(Stdio::from(boot_log_err));
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            mark_inherited_fds_cloexec();
            Ok(())
        });
    }
    let child = cmd
        .spawn()
        .map_err(|e| format!("cannot start the daemon: {}", e))?;
    // Not waited for: the daemon outlives this shim and is reparented
    // when it exits.
    Ok(child.id() as i32)
}

/// Mark every fd from 3 up close-on-exec, so exec drops whatever the
/// MCP client handed down without `O_CLOEXEC`. Marking rather than
/// closing keeps std's own exec-error pipe working. Runs between fork
/// and exec: async-signal-safe calls only. The scan stops at the soft
/// `RLIMIT_NOFILE`, capped at 65536 to bound the syscalls: an fd above
/// 65536 (only possible under a raised limit) would still be inherited.
unsafe fn mark_inherited_fds_cloexec() {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    let max = if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
        limit.rlim_cur.min(65_536) as i32
    } else {
        1024
    };
    for fd in 3..max {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 && flags & libc::FD_CLOEXEC == 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}

/// Spawn through `systemd-run --user --scope` when a user manager is
/// running and `PHAROS_DAEMON_SYSTEMD` is not `0`.
fn use_systemd_run() -> bool {
    if env::var("PHAROS_DAEMON_SYSTEMD").as_deref() == Ok("0") || !cfg!(target_os = "linux") {
        return false;
    }
    let manager = env::var_os("XDG_RUNTIME_DIR")
        .map(|dir| PathBuf::from(dir).join("systemd").join("private").exists())
        .unwrap_or(false);
    manager && on_path("systemd-run")
}

fn on_path(program: &str) -> bool {
    env::var_os("PATH")
        .map(|path| env::split_paths(&path).any(|dir| dir.join(program).is_file()))
        .unwrap_or(false)
}

/// Send the hello and read the ack. Returns any bytes that arrived
/// after the ack line, for the relay.
fn hello(mut stream: &UnixStream, release: &Release) -> Result<Vec<u8>, String> {
    let cwd =
        env::current_dir().map_err(|e| format!("cannot read the working directory: {}", e))?;
    let line = hello_line(
        release,
        &cwd,
        env::vars_os(),
        unsafe { libc::getppid() },
        std::process::id(),
    );
    stream
        .write_all(line.as_bytes())
        .map_err(|e| format!("hello failed: {}", e))?;

    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    stream
        .set_read_timeout(Some(start_timeout()))
        .map_err(|e| e.to_string())?;
    let newline = loop {
        if let Some(at) = buf.iter().position(|b| *b == b'\n') {
            break at;
        }
        if buf.len() > MAX_ACK_BYTES {
            return Err("the daemon's ack is too long".into());
        }
        match stream.read(&mut chunk) {
            Ok(0) => return Err("the daemon closed the connection during the hello".into()),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) => return Err(format!("no ack from the daemon: {}", e)),
        }
    };
    stream.set_read_timeout(None).map_err(|e| e.to_string())?;
    let ack = String::from_utf8_lossy(&buf[..newline]).into_owned();
    if json::has_key(&ack, "pharos_hello_ok") {
        Ok(buf[newline + 1..].to_vec())
    } else {
        let reason = json::get_string(&ack, "pharos_hello_error").unwrap_or(ack);
        Err(format!("the daemon refused the session: {}", reason))
    }
}

/// The hello preamble line. `env` is the whole environment: the daemon
/// launches this session's LSPs with it. It can hold secrets, and the
/// daemon never logs or echoes it.
pub fn hello_line(
    release: &Release,
    cwd: &Path,
    env: impl Iterator<Item = (OsString, OsString)>,
    client_pid: i32,
    shim_pid: u32,
) -> String {
    let vars: Vec<String> = env
        .map(|(name, value)| {
            format!(
                "{}:{}",
                json::string(&name.to_string_lossy()),
                json::string(&value.to_string_lossy())
            )
        })
        .collect();
    format!(
        "{{\"pharos_hello\":1,\"op\":\"mcp\",\"build\":{},\"cwd\":{},\"env\":{{{}}},\"client_pid\":{},\"shim_pid\":{}}}\n",
        json::string(&release.build_id),
        json::string(&cwd.to_string_lossy()),
        vars.join(","),
        client_pid,
        shim_pid
    )
}

/// Copy stdin to the daemon and the daemon to stdout until the client
/// closes stdin (exit 0, after up to `STDIN_EOF_GRACE` for replies in
/// flight) or the daemon goes away first (exit 1).
fn relay(stream: UnixStream, leftover: Vec<u8>) -> i32 {
    let stdout = Arc::new(Mutex::new(io::stdout()));
    let stdin_closed = Arc::new(AtomicBool::new(false));

    let to_daemon = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("pharos: cannot relay stdin: {}", e);
            return 1;
        }
    };
    {
        let stdout = Arc::clone(&stdout);
        let stdin_closed = Arc::clone(&stdin_closed);
        thread::spawn(move || {
            let mut to_daemon = to_daemon;
            // Only a real end of stdin is the client leaving. A failed
            // write means the daemon went away, and the reader below
            // reports that: marking stdin closed here would turn a lost
            // daemon into a clean exit 0 (seen on macos-15-intel, where
            // the write failed before the read saw EOF).
            if io::copy(&mut io::stdin().lock(), &mut to_daemon).is_err() {
                return;
            }
            stdin_closed.store(true, Ordering::SeqCst);
            let _ = to_daemon.shutdown(std::net::Shutdown::Write);
            thread::sleep(STDIN_EOF_GRACE);
            // Hold the stdout lock so the exit never cuts a line.
            let _guard = stdout.lock();
            std::process::exit(0);
        });
    }

    let mut from_daemon = stream;
    let mut pending = leftover;
    let mut chunk = vec![0u8; 64 * 1024];
    loop {
        if let Some(last) = pending.iter().rposition(|b| *b == b'\n') {
            let mut out = stdout.lock().unwrap_or_else(|e| e.into_inner());
            if out
                .write_all(&pending[..=last])
                .and_then(|_| out.flush())
                .is_err()
            {
                // The client is gone.
                return 0;
            }
            drop(out);
            pending.drain(..=last);
        }
        match from_daemon.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => pending.extend_from_slice(&chunk[..n]),
        }
    }
    // Connection closed. Any unterminated tail is a partial frame: drop it.
    if stdin_closed.load(Ordering::SeqCst) {
        0
    } else {
        eprintln!(
            "pharos: lost connection to the pharos daemon; restart the MCP server to reconnect.{}",
            paths::log_dir()
                .map(|d| format!(" Daemon logs: {}", d.display()))
                .unwrap_or_default()
        );
        1
    }
}

/// One-shot operator request (`status`, `stop`) to the daemon on
/// `socket`; returns its one-line reply.
pub fn operator_request(socket: &Path, op: &str) -> Result<String, String> {
    let mut stream =
        UnixStream::connect(socket).map_err(|e| format!("{}: {}", socket.display(), e))?;
    stream
        .write_all(format!("{{\"pharos_hello\":1,\"op\":{}}}\n", json::string(op)).as_bytes())
        .map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| e.to_string())?;
    let mut reply = String::new();
    stream
        .read_to_string(&mut reply)
        .map_err(|e| e.to_string())?;
    Ok(reply.trim_end().to_string())
}

/// Append an auto-mode fallback to `<log dir>/fallbacks.log`, so a
/// broken daemon does not hide behind a stderr line only the client's
/// own log ever sees. `pharos --doctor` reports recent entries.
pub fn record_fallback(release: &Release, reason: &str) {
    if let Some(dir) = paths::log_dir() {
        if paths::ensure_private_dir(&dir).is_ok() {
            if let Ok(mut file) = OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(dir.join("fallbacks.log"))
            {
                let _ = writeln!(
                    file,
                    "{} build={} version={} reason={}",
                    iso8601(unix_secs()),
                    release.build_id,
                    release.version,
                    reason.replace('\n', " ")
                );
            }
        }
    }
}

fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// UTC `YYYY-MM-DDTHH:MM:SSZ` (civil-from-days, Howard Hinnant).
fn iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year,
        month,
        day,
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release() -> Release {
        Release {
            root: PathBuf::from("/r"),
            erts_version: "16.1".into(),
            version: "0.2.0".into(),
            build_id: "0123456789abcdef".into(),
        }
    }

    #[test]
    fn hello_carries_build_cwd_env_and_pids() {
        let env = vec![
            (OsString::from("PATH"), OsString::from("/usr/bin")),
            (OsString::from("TOKEN"), OsString::from("a\"b")),
        ];
        let line = hello_line(&release(), Path::new("/proj"), env.into_iter(), 7, 8);
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        assert_eq!(
            json::get_string(&line, "build").as_deref(),
            Some("0123456789abcdef")
        );
        assert_eq!(json::get_string(&line, "cwd").as_deref(), Some("/proj"));
        assert!(line.contains("\"PATH\":\"/usr/bin\""));
        assert!(line.contains("\"TOKEN\":\"a\\\"b\""));
        assert!(line.contains("\"client_pid\":7,\"shim_pid\":8"));
    }

    #[test]
    fn iso8601_formats_utc() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(1_792_423_000), "2026-10-19T15:16:40Z");
    }
}
