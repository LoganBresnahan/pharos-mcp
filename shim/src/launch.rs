//! Starting the bundled Erlang runtime: what Burrito's wrapper used to
//! do (ADR-033), minus the self-extraction. Every command that is not
//! the MCP shim itself, and direct mode, run the release this way.

use std::env;
use std::ffi::OsString;
use std::process::Command;

use crate::release::Release;

/// `erlexec` (Unix) or `erl.exe` (Windows) with the release's boot
/// arguments, followed by `-extra` and pharos's own arguments.
///
/// `-mode` and `embedded` are separate argv elements; ADR-033 is the
/// record of what happens when they are not. No `-setcookie`: pharos
/// is not distributed, and a cookie on the command line is readable by
/// anyone who can run `ps`.
pub fn beam_command(release: &Release, pharos_args: &[OsString]) -> Command {
    let erts_bin = release.erts_bin();
    let vsn_dir = release.version_dir();
    let program = if cfg!(windows) {
        erts_bin.join("erl.exe")
    } else {
        erts_bin.join("erlexec")
    };
    let mut cmd = Command::new(program);
    cmd.arg("-noshell")
        .args(["-mode", "embedded"])
        .arg("-boot")
        .arg(vsn_dir.join("start"))
        .args(["-boot_var", "RELEASE_LIB"])
        .arg(release.root.join("lib"))
        .arg("-args_file")
        .arg(vsn_dir.join("vm.args"))
        .arg("-config")
        .arg(vsn_dir.join("sys.config"))
        .arg("-extra")
        .args(pharos_args);
    cmd.env("ROOTDIR", &release.root)
        .env("BINDIR", &erts_bin)
        .env("EMU", "beam")
        .env("PROGNAME", "erl")
        .env("RELEASE_ROOT", &release.root)
        .env("RELEASE_SYS_CONFIG", vsn_dir.join("sys"));
    if let Ok(exe) = env::current_exe() {
        cmd.env("PHAROS_SHIM_PATH", exe);
    }
    cmd
}

/// Replace this process with the BEAM. Returns only on failure.
#[cfg(unix)]
pub fn exec_beam(release: &Release, pharos_args: &[OsString]) -> std::io::Error {
    use std::os::unix::process::CommandExt;
    beam_command(release, pharos_args).exec()
}

/// Windows has no `exec`: run the BEAM with this process's stdio inside
/// a kill-on-close job object (so it dies with us), and exit with its
/// status.
#[cfg(windows)]
pub fn exec_beam(release: &Release, pharos_args: &[OsString]) -> std::io::Error {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    if !job.is_null() {
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
        }
    }
    let mut child = match beam_command(release, pharos_args).spawn() {
        Ok(child) => child,
        Err(e) => return e,
    };
    if !job.is_null() {
        unsafe { AssignProcessToJobObject(job, child.as_raw_handle() as _) };
    }
    match child.wait() {
        Ok(status) => std::process::exit(status.code().unwrap_or(1)),
        Err(e) => e,
    }
}

/// The daemon's argv after `-extra`.
#[cfg(unix)]
pub fn daemon_args(socket: &std::path::Path, build_id: &str, key: &str) -> Vec<OsString> {
    vec![
        "daemon".into(),
        "--socket".into(),
        socket.into(),
        "--build".into(),
        build_id.into(),
        "--key".into(),
        key.into(),
    ]
}
