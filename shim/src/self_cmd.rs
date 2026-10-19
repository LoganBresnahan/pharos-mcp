//! `pharos self …` (ADR-036): managing the installed pharos from the
//! launcher, without booting the runtime.
//!
//! - An install.sh install (`<install dir>/versions/<version>/`): `update`
//!   runs the release's install.sh (the latest, or `--version`'s);
//!   `rollback`, `prune` and `uninstall` run the install.sh this version
//!   ships. Each runs as `sh -s -- <flags>` with the script on stdin,
//!   the way `curl … | sh` runs it, so no command line names a version
//!   directory (install.sh would take that for a running pharos and keep
//!   it, or refuse to uninstall), with `PHAROS_INSTALL_DIR` and
//!   `PHAROS_BIN_DIR` set from where this executable really is.
//! - An npm install (`node_modules/@pharos-mcp/<platform>/release`): npm
//!   owns those files, so each command prints the npm command that does
//!   it and exits 1. `prune` still removes 0.1.x's Burrito unpacks,
//!   which npm doesn't own.
//! - `prune` also does what `--purge-cache` did in 0.2.0 (ADR-035 §6):
//!   removes the unpacks pharos 0.1.x's Burrito wrapper left under
//!   `<data>/.burrito/pharos_*` that no running process names.

use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use crate::release::Release;

const REPO: &str = "LoganBresnahan/pharos-mcp";
const USAGE: &str = "usage: pharos self update [--version VERSION] | rollback | prune | uninstall";

#[derive(Debug, PartialEq)]
pub enum Install {
    /// install.sh's layout: the release is `<install_dir>/versions/<version>`.
    Script { install_dir: PathBuf },
    /// An npm platform package's `release/`.
    Npm,
    /// Anything else: a build's `_build/prod/rel/pharos`, a copied release.
    Other,
}

/// What installed the release at `root` (a canonical path).
pub fn install_kind(root: &Path) -> Install {
    let tail: Vec<String> = root
        .components()
        .rev()
        .take(4)
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    if tail.len() == 4
        && tail[0] == "release"
        && tail[2] == "@pharos-mcp"
        && tail[3] == "node_modules"
    {
        return Install::Npm;
    }
    match root.parent() {
        Some(versions) if versions.file_name().is_some_and(|n| n == "versions") => {
            match versions.parent() {
                Some(install_dir) => Install::Script {
                    install_dir: install_dir.to_path_buf(),
                },
                None => Install::Other,
            }
        }
        _ => Install::Other,
    }
}

pub fn run(release: &Release, args: &[OsString]) -> ExitCode {
    let args: Option<Vec<&str>> = args.iter().map(|a| a.to_str()).collect();
    let root = release
        .root
        .canonicalize()
        .unwrap_or_else(|_| release.root.clone());
    let install = install_kind(&root);
    match args.as_deref() {
        Some(["update"]) => update(&install, None),
        Some(["update", "--version", version]) => {
            update(&install, Some(version.trim_start_matches('v')))
        }
        Some(["update", flag]) if flag.starts_with("--version=") => update(
            &install,
            Some(flag["--version=".len()..].trim_start_matches('v')),
        ),
        Some(["rollback"]) => bundled(&install, &root, "--rollback"),
        Some(["prune"]) => prune(&install, &root),
        Some(["uninstall"]) => bundled(&install, &root, "--uninstall"),
        Some(["help"]) | Some(["--help"]) | Some(["-h"]) => {
            println!("{}", USAGE);
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("{}", USAGE);
            ExitCode::from(2)
        }
    }
}

fn update(install: &Install, version: Option<&str>) -> ExitCode {
    let install_dir = match install {
        Install::Script { install_dir } => install_dir,
        Install::Npm => {
            return npm_owns(
                "update it",
                &format!("npm install -g pharos-mcp@{}", version.unwrap_or("latest")),
            );
        }
        Install::Other => return not_installed(),
    };
    let url = match (env::var("PHAROS_DOWNLOAD_URL"), version) {
        (Ok(base), _) if !base.is_empty() => format!("{}/install.sh", base.trim_end_matches('/')),
        (_, Some(v)) => format!(
            "https://github.com/{}/releases/download/v{}/install.sh",
            REPO, v
        ),
        (_, None) => format!(
            "https://github.com/{}/releases/latest/download/install.sh",
            REPO
        ),
    };
    let script = match download(&url) {
        Ok(script) => script,
        Err(e) => {
            eprintln!("pharos self update: {}", e);
            return ExitCode::from(1);
        }
    };
    let mut flags = Vec::new();
    if let Some(v) = version {
        flags.extend(["--version", v]);
    }
    exec_install_sh(script, install_dir, &flags)
}

/// Run the install.sh this version ships with `flag`.
fn bundled(install: &Install, root: &Path, flag: &str) -> ExitCode {
    let install_dir = match install {
        Install::Script { install_dir } => install_dir,
        Install::Npm if flag == "--rollback" => {
            return npm_owns(
                "roll back",
                "npm install -g pharos-mcp@<version>   (npm view pharos-mcp versions lists them)",
            );
        }
        Install::Npm => {
            return npm_owns(
                "uninstall it",
                "pharos daemon stop --all && npm uninstall -g pharos-mcp",
            );
        }
        Install::Other => return not_installed(),
    };
    match File::open(root.join("install.sh")) {
        Ok(script) => exec_install_sh(script, install_dir, &[flag]),
        Err(e) => {
            eprintln!(
                "pharos self: this version has no install.sh beside it ({}); run instead:\n  curl -fsSL https://github.com/{}/releases/latest/download/install.sh | sh -s -- {}",
                e, REPO, flag
            );
            ExitCode::from(1)
        }
    }
}

fn prune(install: &Install, root: &Path) -> ExitCode {
    purge_legacy_unpacks();
    match install {
        Install::Script { .. } => bundled(install, root, "--prune"),
        Install::Npm => {
            println!("pharos self prune: npm keeps one version of pharos-mcp; no other versions to prune");
            ExitCode::SUCCESS
        }
        Install::Other => {
            println!(
                "pharos self prune: {} isn't an install.sh install; no versions to prune",
                root.display()
            );
            ExitCode::SUCCESS
        }
    }
}

/// Replace this process with `sh -s -- FLAGS`, reading `script` on its
/// stdin. Returns only on failure.
fn exec_install_sh(script: File, install_dir: &Path, flags: &[&str]) -> ExitCode {
    let mut cmd = Command::new("sh");
    cmd.arg("-s")
        .arg("--")
        .args(flags)
        .stdin(Stdio::from(script))
        .env("PHAROS_INSTALL_DIR", install_dir);
    if env::var_os("PHAROS_BIN_DIR").is_none() {
        if let Some(dir) = link_dir() {
            cmd.env("PHAROS_BIN_DIR", dir);
        }
    }
    let _ = io::stdout().flush();
    let err = cmd.exec();
    eprintln!("pharos self: cannot run sh: {}", err);
    ExitCode::from(1)
}

/// Fetch `url` with curl into a file that is unlinked once open, so
/// nothing is left behind whatever happens next.
fn download(url: &str) -> Result<File, String> {
    let path = env::temp_dir().join(format!("pharos-install-{}.sh", std::process::id()));
    let _ = fs::remove_file(&path);
    // create_new: never write through a file or link someone else put there.
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| format!("{}: {}", path.display(), e))?;
    let status = Command::new("curl")
        .args(["-fsSL", "--retry", "3", "-o"])
        .arg(&path)
        .arg(url)
        .status();
    let opened = File::open(&path);
    let _ = fs::remove_file(&path);
    match status {
        Ok(s) if s.success() => opened.map_err(|e| format!("{}: {}", path.display(), e)),
        Ok(_) => Err(format!("couldn't download {}", url)),
        Err(e) => Err(format!(
            "can't run curl ({}); it is needed to download {}",
            e, url
        )),
    }
}

/// Where install.sh made the `pharos` link to this executable: argv[0]
/// when it is a path to such a link, else the first `pharos` on PATH
/// that is one (a shell passes a bare `pharos` as argv[0]).
fn link_dir() -> Option<PathBuf> {
    let me = env::current_exe().ok()?.canonicalize().ok()?;
    let links_to_me = |link: &Path| {
        fs::symlink_metadata(link).is_ok_and(|m| m.file_type().is_symlink())
            && link.canonicalize().is_ok_and(|target| target == me)
    };
    let argv0 = PathBuf::from(env::args_os().next()?);
    let candidates = argv0
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .map(|dir| dir.to_path_buf())
        .into_iter()
        .chain(
            env::var_os("PATH")
                .map(|p| env::split_paths(&p).collect::<Vec<_>>())
                .unwrap_or_default(),
        );
    candidates
        .filter(|dir| links_to_me(&dir.join("pharos")))
        .map(|dir| dir.canonicalize().unwrap_or(dir))
        .next()
}

fn npm_owns(what: &str, command: &str) -> ExitCode {
    eprintln!(
        "pharos self: npm installed this pharos and owns its files; to {}, run:\n  {}",
        what, command
    );
    ExitCode::from(1)
}

fn not_installed() -> ExitCode {
    eprintln!(
        "pharos self: this pharos wasn't installed by install.sh or npm; `self` manages those installs"
    );
    ExitCode::from(1)
}

/// Where pharos 0.1.x's Burrito wrapper unpacked itself (Zig's
/// `getAppDataDir(".burrito")`): `$XDG_DATA_HOME/.burrito` or
/// `~/.local/share/.burrito` on Linux, `~/Library/Application
/// Support/.burrito` on macOS. Shared with other Burrito apps (geex
/// 0.2.0's among them), so only `pharos_*` children are ever touched.
pub fn legacy_burrito_root() -> Option<PathBuf> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute());
    let data = if cfg!(target_os = "macos") {
        home?.join("Library").join("Application Support")
    } else {
        match env::var_os("XDG_DATA_HOME").map(PathBuf::from) {
            Some(dir) if dir.is_absolute() => dir,
            _ => home?.join(".local").join("share"),
        }
    };
    Some(data.join(".burrito"))
}

/// Remove each `pharos_*` unpack under the legacy root that no running
/// process's command line names (a 0.1.x VM names its unpack in `-root`
/// and `-bindir`): install.sh's rule. Says nothing when there are none.
fn purge_legacy_unpacks() {
    let Some(root) = legacy_burrito_root() else {
        return;
    };
    let unpacks = pharos_unpacks(&root);
    if unpacks.is_empty() {
        return;
    }
    let running = match Command::new("ps")
        .args(["-A", "-ww", "-o", "args="])
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => {
            for dir in &unpacks {
                println!(
                    "pharos self prune: kept {}: can't list running processes to tell whether pharos 0.1.x uses it",
                    dir.display()
                );
            }
            return;
        }
    };
    for (dir, outcome) in unpacks.iter().zip(sort_unpacks(&unpacks, &running)) {
        match outcome {
            Outcome::Kept => println!(
                "pharos self prune: kept {}: a running pharos 0.1.x uses it",
                dir.display()
            ),
            Outcome::Remove => match fs::remove_dir_all(dir) {
                Ok(()) => println!(
                    "pharos self prune: removed {} (pharos 0.1.x)",
                    dir.display()
                ),
                Err(e) => eprintln!(
                    "pharos self prune: couldn't remove {}: {}",
                    dir.display(),
                    e
                ),
            },
        }
    }
}

/// The `pharos_*` directories (not links) directly under `root`, sorted.
pub fn pharos_unpacks(root: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(root)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("pharos_"))
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .map(|e| e.path())
                .collect()
        })
        .unwrap_or_default();
    dirs.sort();
    dirs
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Kept,
    Remove,
}

/// For each unpack, whether a line of `running` (`ps` output) names it.
pub fn sort_unpacks(unpacks: &[PathBuf], running: &str) -> Vec<Outcome> {
    unpacks
        .iter()
        .map(|dir| {
            let needle = format!("{}/", dir.display());
            if running.lines().any(|line| line.contains(&needle)) {
                Outcome::Kept
            } else {
                Outcome::Remove
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tells_the_install_layouts_apart() {
        assert_eq!(
            install_kind(Path::new("/home/u/.local/share/pharos/versions/0.2.1")),
            Install::Script {
                install_dir: PathBuf::from("/home/u/.local/share/pharos")
            }
        );
        assert_eq!(
            install_kind(Path::new(
                "/usr/lib/node_modules/@pharos-mcp/linux-x64/release"
            )),
            Install::Npm
        );
        assert_eq!(
            install_kind(Path::new("/home/u/src/pharos-mcp/_build/prod/rel/pharos")),
            Install::Other
        );
        assert_eq!(install_kind(Path::new("/versions")), Install::Other);
    }

    #[test]
    fn keeps_only_the_unpacks_a_command_line_names() {
        let used = PathBuf::from("/d/.burrito/pharos_erts-16.1_0.1.3");
        let idle = PathBuf::from("/d/.burrito/pharos_erts-16.1_0.1.2");
        // A prefix of another unpack's name doesn't count: the match
        // needs the trailing slash.
        let prefix = PathBuf::from("/d/.burrito/pharos_erts-16.1_0.1");
        let running = "/usr/bin/bash\n/d/.burrito/pharos_erts-16.1_0.1.3/erts-16.1/bin/beam.smp -- -root /d/.burrito/pharos_erts-16.1_0.1.3 -progname erl\n";
        assert_eq!(
            sort_unpacks(&[used, idle, prefix], running),
            vec![Outcome::Kept, Outcome::Remove, Outcome::Remove]
        );
    }

    #[test]
    fn lists_only_pharos_directories() {
        let root = env::temp_dir().join(format!("pharos-shim-legacy-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for dir in [
            "pharos_erts-16.1_0.1.2",
            "geex_erts-16.1_0.2.0",
            "next_ls_erts-15.2_0.23.4",
        ] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        fs::write(root.join("pharos_stray"), "").unwrap();
        std::os::unix::fs::symlink(root.join("geex_erts-16.1_0.2.0"), root.join("pharos_link"))
            .unwrap();
        assert_eq!(
            pharos_unpacks(&root),
            vec![root.join("pharos_erts-16.1_0.1.2")]
        );
        fs::remove_dir_all(&root).unwrap();
    }
}
