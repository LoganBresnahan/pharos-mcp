//! `pharos`: the front-end executable (ADR-034).
//!
//! - No arguments: the MCP stdio shim. It connects this session to the
//!   shared daemon for this build, starting it if none runs.
//!   `PHAROS_MODE` picks `auto` (the default: fall back to direct mode,
//!   loudly, if the daemon cannot be reached), `daemon` (fail instead;
//!   tests and CI) or `direct`.
//! - `--direct`, or a `PHAROS_TRANSPORT` other than `stdio`: direct mode,
//!   the in-process server, as before 0.2.0.
//!
//! Linux and macOS only. Windows users run pharos inside WSL (ADR-035).
//! - `daemon status|stop [--all]`: operator requests to running daemons.
//! - `self update|rollback|prune|uninstall`: manage the installed
//!   pharos (ADR-036), here, without booting the runtime.
//!   `--purge-cache` is a deprecated alias of `self prune`.
//! - `daemon` alone: run this build's daemon in the foreground.
//! - `--version`: answered here, without booting the runtime.
//! - Anything else: handed to the bundled runtime unchanged.

#[cfg(not(unix))]
compile_error!("pharos runs on Linux and macOS; on Windows, build and run it inside WSL (ADR-035)");

mod client;
mod json;
mod launch;
mod paths;
mod release;
mod self_cmd;

use std::env;
use std::ffi::OsString;
use std::process::ExitCode;

use release::Release;

fn main() -> ExitCode {
    let args: Vec<OsString> = env::args_os().skip(1).collect();
    let release = match Release::locate() {
        Ok(release) => release,
        Err(e) => {
            eprintln!("pharos: cannot find the bundled runtime: {}", e);
            return ExitCode::from(1);
        }
    };
    let first = args.first().and_then(|a| a.to_str());
    match first {
        None => mcp(&release),
        Some("--version") | Some("-V") if args.len() == 1 => {
            println!("pharos {}", release.version);
            ExitCode::SUCCESS
        }
        Some("--direct") => direct(&release, &args[1..]),
        Some("daemon") => daemon_command(&release, &args),
        Some("self") => self_cmd::run(&release, &args[1..]),
        Some("--purge-cache") if args.len() == 1 => {
            eprintln!("pharos: --purge-cache is deprecated and goes in the next release; it is `pharos self prune` now, which this runs");
            self_cmd::run(&release, &[OsString::from("prune")])
        }
        Some(_) => direct(&release, &args),
    }
}

fn direct(release: &Release, args: &[OsString]) -> ExitCode {
    let err = launch::exec_beam(release, args);
    eprintln!("pharos: cannot start the bundled runtime: {}", err);
    ExitCode::from(1)
}

/// The no-argument path: what an MCP client launches.
fn mcp(release: &Release) -> ExitCode {
    let transport = env::var("PHAROS_TRANSPORT").unwrap_or_default();
    let mode = env::var("PHAROS_MODE").unwrap_or_default();
    if mode == "direct" || !(transport.is_empty() || transport == "stdio") {
        return direct(release, &[]);
    }
    shim(release, mode == "daemon")
}

fn shim(release: &Release, require_daemon: bool) -> ExitCode {
    match client::run(release) {
        client::Outcome::Exit(code) => ExitCode::from(code as u8),
        client::Outcome::Unreachable(reason) if require_daemon => {
            eprintln!("pharos: the pharos daemon is unreachable: {}", reason);
            ExitCode::from(1)
        }
        client::Outcome::Unreachable(reason) => {
            client::record_fallback(release, &reason);
            eprintln!(
                "pharos: the pharos daemon is unreachable ({}); running this session in direct mode. `pharos --doctor` lists recent fallbacks.",
                reason
            );
            direct(release, &[])
        }
    }
}

fn daemon_command(release: &Release, args: &[OsString]) -> ExitCode {
    let rest: Vec<&str> = args[1..].iter().filter_map(|a| a.to_str()).collect();
    let key = paths::daemon_key(|name| env::var_os(name));
    let mine = paths::DaemonPaths::new(&release.build_id, &key);
    match rest.as_slice() {
        [] | ["run"] => {
            if let Err(reason) = paths::ensure_private_dir(&mine.dir) {
                eprintln!("pharos: {}", reason);
                return ExitCode::from(1);
            }
            direct(
                release,
                &launch::daemon_args(&mine.socket, &release.build_id, &key),
            )
        }
        [op @ ("status" | "stop")] | [op @ ("status" | "stop"), "--all"] => {
            let all = rest.len() == 2;
            let sockets = if all {
                all_sockets(&mine.dir)
            } else {
                vec![mine.socket.clone()]
            };
            if sockets.is_empty() || (!all && !mine.socket.exists()) {
                eprintln!(
                    "pharos: no daemon running{}",
                    if all { "" } else { " for this build" }
                );
                return ExitCode::from(if *op == "status" { 3 } else { 0 });
            }
            let mut failed = false;
            for socket in sockets {
                match client::operator_request(&socket, op) {
                    Ok(reply) => println!("{}", reply),
                    Err(e) => {
                        eprintln!("pharos: {}", e);
                        failed = true;
                    }
                }
            }
            ExitCode::from(failed as u8)
        }
        // `daemon --socket … --build …`: a raw daemon invocation.
        [flag, ..] if flag.starts_with("--") => direct(release, args),
        _ => {
            eprintln!("usage: pharos daemon [run | status [--all] | stop [--all]]");
            ExitCode::from(2)
        }
    }
}

fn all_sockets(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut sockets: Vec<_> = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "sock"))
                .collect()
        })
        .unwrap_or_default();
    sockets.sort();
    sockets
}
