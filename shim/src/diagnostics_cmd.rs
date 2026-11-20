//! `pharos diagnostics [--json] [--timeout-ms N] FILE...` (#6): the
//! diagnostics of some files, through the shared daemon, for hooks and
//! scripts that aren't MCP clients.
//!
//! It joins (or starts) this build's daemon like a session, asks
//! `get_diagnostics` for each file over MCP, prints the answers and
//! exits. It lives in the shim, not the runtime, because a hook runs it
//! on every edit: booting the Erlang VM each time would cost about a
//! second per call.
//!
//! Each file's answer has a status:
//! - `ok`: diagnostics about the file's current text (ADR-038);
//! - `unsure`: pharos says the answer may be old or incomplete
//!   (`pharos.carried_over`, `pharos.not_reported`, or no publish in
//!   time), or couldn't name the file's project
//!   (`pharos.project_unknown`). A hook should stay silent;
//! - `failed`: the tool call failed for that file.
//!
//! Exit 0 once the daemon answered, whatever the statuses; 1 when pharos
//! itself failed (daemon unreachable, the session broke); 2 on bad usage.

use std::env;
use std::ffi::OsString;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Component, Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use crate::client;
use crate::json::{self, Value};
use crate::release::Release;

const USAGE: &str = "usage: pharos diagnostics [--json] [--timeout-ms N] FILE...";

/// get_diagnostics' own default (`tools/diagnostics.gleam`).
const DEFAULT_TIMEOUT_MS: u64 = 8000;

/// On top of each call's timeout: the session's sync, and the daemon's
/// own bookkeeping, before the reply comes.
const REPLY_MARGIN: Duration = Duration::from_secs(10);

#[derive(Debug, PartialEq)]
pub struct Options {
    pub json: bool,
    pub timeout_ms: u64,
    pub files: Vec<String>,
}

pub fn parse_args(args: &[String]) -> Result<Options, String> {
    let mut opts = Options {
        json: false,
        timeout_ms: DEFAULT_TIMEOUT_MS,
        files: Vec::new(),
    };
    let mut i = 0;
    let mut flags = true;
    while i < args.len() {
        let a = &args[i];
        if flags && a == "--" {
            flags = false;
        } else if flags && a == "--json" {
            opts.json = true;
        } else if flags && (a == "--timeout-ms" || a.starts_with("--timeout-ms=")) {
            let value = match a.strip_prefix("--timeout-ms=") {
                Some(v) => v.to_string(),
                None => {
                    i += 1;
                    args.get(i).cloned().ok_or("--timeout-ms needs a value")?
                }
            };
            opts.timeout_ms = value
                .parse::<u64>()
                .ok()
                .filter(|ms| *ms > 0)
                .ok_or_else(|| format!("--timeout-ms takes a positive number, not {:?}", value))?;
        } else if flags && a.starts_with("--") {
            return Err(format!("unknown option {}", a));
        } else {
            opts.files.push(a.clone());
        }
        i += 1;
    }
    if opts.files.is_empty() {
        return Err("name at least one file".into());
    }
    Ok(opts)
}

pub fn run(release: &Release, args: &[OsString]) -> ExitCode {
    let args: Vec<String> = args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let opts = match parse_args(&args) {
        Ok(opts) => opts,
        Err(e) => {
            eprintln!("pharos diagnostics: {}\n{}", e, USAGE);
            return ExitCode::from(2);
        }
    };
    let cwd = match env::current_dir() {
        Ok(cwd) => cwd,
        Err(e) => {
            eprintln!(
                "pharos diagnostics: cannot read the working directory: {}",
                e
            );
            return ExitCode::from(1);
        }
    };
    let (stream, leftover) = match client::connect(release) {
        Ok(connected) => connected,
        Err(reason) => {
            eprintln!("pharos: the pharos daemon is unreachable: {}", reason);
            return ExitCode::from(1);
        }
    };
    let mut session = Session {
        stream,
        pending: leftover,
        next_id: 0,
    };
    if let Err(e) = session.initialize(&release.version) {
        eprintln!("pharos diagnostics: {}", e);
        return ExitCode::from(1);
    }
    let mut results = Vec::new();
    for file in &opts.files {
        let path = absolute(&cwd, file);
        let uri = file_uri(&path);
        match session.get_diagnostics(&uri, opts.timeout_ms) {
            Ok(reply) => results.push(classify(file, &path, &uri, &reply)),
            Err(e) => {
                eprintln!("pharos diagnostics: {}", e);
                return ExitCode::from(1);
            }
        }
    }
    let mut out = std::io::stdout().lock();
    let written = if opts.json {
        writeln!(out, "{}", json_output(&results).write())
    } else {
        for r in &results {
            if r.status != "ok" {
                eprintln!(
                    "pharos: {}: {}{}",
                    r.file,
                    r.status,
                    r.reason
                        .as_deref()
                        .map(|why| format!(" ({})", why))
                        .unwrap_or_default()
                );
            }
        }
        human_lines(&results)
            .iter()
            .try_for_each(|line| writeln!(out, "{}", line))
    };
    match written.and_then(|_| out.flush()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(1),
    }
}

/// `file` made absolute against `cwd`, with `.` and `..` resolved
/// lexically. Symlinks are kept as the caller wrote them, like the
/// paths an agent's tools pass.
/// The `file://` URI of an absolute path, percent-encoded as the daemon's
/// `workspace_root.path_to_uri` does: every byte but `A-Z a-z 0-9 - . _ ~ /`.
/// The daemon decodes every `uri` argument, so a raw path holding a valid
/// escape (`100%25`, `a%20b`) would name another file (#16).
pub fn file_uri(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let mut out = String::from("file://");
    for &b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

pub fn absolute(cwd: &Path, file: &str) -> PathBuf {
    let joined = if Path::new(file).is_absolute() {
        PathBuf::from(file)
    } else {
        cwd.join(file)
    };
    let mut out = PathBuf::from("/");
    for part in joined.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(name) => out.push(name),
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
    out
}

struct Session {
    stream: UnixStream,
    pending: Vec<u8>,
    next_id: u64,
}

impl Session {
    fn initialize(&mut self, version: &str) -> Result<(), String> {
        let params = format!(
            "{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"pharos-diagnostics\",\"version\":{}}}}}",
            json::string(version)
        );
        let reply = self.request("initialize", &params, Duration::from_secs(60))?;
        if reply.get("result").is_none() {
            return Err(format!("initialize failed: {}", reply.write()));
        }
        self.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
    }

    fn get_diagnostics(&mut self, uri: &str, timeout_ms: u64) -> Result<Value, String> {
        let params = format!(
            "{{\"name\":\"get_diagnostics\",\"arguments\":{{\"uri\":{},\"timeout_ms\":{}}}}}",
            json::string(uri),
            timeout_ms
        );
        self.request(
            "tools/call",
            &params,
            Duration::from_millis(timeout_ms) + REPLY_MARGIN,
        )
    }

    fn send(&mut self, line: &str) -> Result<(), String> {
        self.stream
            .write_all(line.as_bytes())
            .map_err(|e| format!("lost the pharos daemon: {}", e))
    }

    /// Send a request and read lines until the reply with its id.
    fn request(&mut self, method: &str, params: &str, wait: Duration) -> Result<Value, String> {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":{},\"params\":{}}}\n",
            id,
            json::string(method),
            params
        ))?;
        self.stream
            .set_read_timeout(Some(wait))
            .map_err(|e| e.to_string())?;
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            while let Some(at) = self.pending.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = self.pending.drain(..=at).collect();
                let text = String::from_utf8_lossy(&line);
                let text = text.trim();
                if text.is_empty() {
                    continue;
                }
                let msg = json::parse(text).map_err(|e| format!("unreadable reply: {}", e))?;
                if msg.get("id").and_then(Value::as_f64) == Some(id as f64) {
                    return Ok(msg);
                }
            }
            match self.stream.read(&mut chunk) {
                Ok(0) => return Err("the pharos daemon closed the session".into()),
                Ok(n) => self.pending.extend_from_slice(&chunk[..n]),
                Err(e) => {
                    return Err(format!(
                        "no reply from the pharos daemon for {}: {}",
                        method, e
                    ))
                }
            }
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct FileResult {
    pub file: String,
    pub path: String,
    pub uri: String,
    pub status: &'static str,
    pub reason: Option<String>,
    pub project: Option<String>,
    pub diagnostics: Vec<Value>,
}

/// One file's `tools/call` reply, read into a status.
pub fn classify(file: &str, path: &Path, uri: &str, reply: &Value) -> FileResult {
    let mut r = FileResult {
        file: file.to_string(),
        path: path.display().to_string(),
        uri: uri.to_string(),
        status: "failed",
        reason: None,
        project: None,
        diagnostics: Vec::new(),
    };
    if let Some(err) = reply.get("error") {
        r.reason = Some(
            err.get("message")
                .and_then(Value::as_str)
                .unwrap_or("JSON-RPC error")
                .to_string(),
        );
        return r;
    }
    let result = match reply.get("result") {
        Some(result) => result,
        None => {
            r.reason = Some("no result".into());
            return r;
        }
    };
    let text = result
        .get("content")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(|item| item.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("");
    if result.get("isError").and_then(Value::as_bool) == Some(true) {
        r.reason = Some(one_line(text));
        return r;
    }
    let envelope = match json::parse(text) {
        Ok(v) if v.get("params").is_some() => v,
        // get_diagnostics' plain-text answer: nothing was published in time.
        _ => {
            r.status = "unsure";
            r.reason = Some("no_publish".into());
            return r;
        }
    };
    let notes = envelope.get("pharos");
    r.project = notes
        .and_then(|n| n.get("project"))
        .and_then(Value::as_str)
        .map(String::from);
    r.diagnostics = envelope
        .get("params")
        .and_then(|p| p.get("diagnostics"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // The reason names pharos's marker: an answer that may be old, or
    // whose project tsserver couldn't name in time.
    let unsure: Vec<&str> = ["carried_over", "not_reported", "project_unknown"]
        .into_iter()
        .filter(|key| notes.and_then(|n| n.get(key)).is_some())
        .collect();
    if unsure.is_empty() {
        r.status = "ok";
    } else {
        r.status = "unsure";
        r.reason = Some(unsure.join(","));
    }
    r
}

pub fn json_output(results: &[FileResult]) -> Value {
    let files = results
        .iter()
        .map(|r| {
            let mut m = std::collections::BTreeMap::new();
            m.insert("file".to_string(), Value::Str(r.file.clone()));
            m.insert("path".to_string(), Value::Str(r.path.clone()));
            m.insert("uri".to_string(), Value::Str(r.uri.clone()));
            m.insert("status".to_string(), Value::Str(r.status.to_string()));
            if let Some(reason) = &r.reason {
                m.insert("reason".to_string(), Value::Str(reason.clone()));
            }
            if let Some(project) = &r.project {
                m.insert("project".to_string(), Value::Str(project.clone()));
            }
            m.insert(
                "diagnostics".to_string(),
                Value::Array(r.diagnostics.clone()),
            );
            Value::Object(m)
        })
        .collect();
    let mut top = std::collections::BTreeMap::new();
    top.insert("files".to_string(), Value::Array(files));
    Value::Object(top)
}

/// `FILE:LINE:COL SEVERITY CODE MESSAGE`, 1-based, for the ok files.
pub fn human_lines(results: &[FileResult]) -> Vec<String> {
    let mut lines = Vec::new();
    for r in results.iter().filter(|r| r.status == "ok") {
        for d in &r.diagnostics {
            let pos = |key: &str| {
                d.get("range")
                    .and_then(|range| range.get("start"))
                    .and_then(|start| start.get(key))
                    .and_then(Value::as_f64)
                    .map(|n| n as i64 + 1)
                    .unwrap_or(0)
            };
            let severity = match d.get("severity").and_then(Value::as_f64).map(|s| s as i64) {
                Some(2) => "warning",
                Some(3) => "info",
                Some(4) => "hint",
                _ => "error",
            };
            let code = match d.get("code") {
                Some(Value::Number(n)) => format!(" {}", *n as i64),
                Some(Value::Str(s)) => format!(" {}", s),
                _ => String::new(),
            };
            let message = d.get("message").and_then(Value::as_str).unwrap_or("");
            lines.push(format!(
                "{}:{}:{} {}{} {}",
                r.file,
                pos("line"),
                pos("character"),
                severity,
                code,
                one_line(message)
            ));
        }
    }
    lines
}

/// Every newline and the indentation after it collapse to one space.
fn one_line(text: &str) -> String {
    let mut out = String::new();
    let mut lines = text.lines();
    if let Some(first) = lines.next() {
        out.push_str(first.trim_end());
    }
    for line in lines {
        out.push(' ');
        out.push_str(line.trim());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn parses_flags_and_files() {
        let o = parse_args(&s(&["--json", "--timeout-ms", "1500", "a.ts", "b.ts"])).unwrap();
        assert_eq!(
            o,
            Options {
                json: true,
                timeout_ms: 1500,
                files: s(&["a.ts", "b.ts"])
            }
        );
        let o = parse_args(&s(&["--timeout-ms=900", "--", "--odd-name.ts"])).unwrap();
        assert_eq!(o.timeout_ms, 900);
        assert_eq!(o.files, s(&["--odd-name.ts"]));
        assert!(parse_args(&s(&["--json"])).is_err());
        assert!(parse_args(&s(&["--timeout-ms", "0", "a"])).is_err());
        assert!(parse_args(&s(&["--nope", "a"])).is_err());
    }

    #[test]
    fn file_uris_are_escaped_as_the_daemon_escapes() {
        assert_eq!(
            file_uri(Path::new("/w/proj/src/a.ts")),
            "file:///w/proj/src/a.ts"
        );
        assert_eq!(
            file_uri(Path::new("/w/a b#c%25d-\u{e9}/x+y.ts")),
            "file:///w/a%20b%23c%2525d-%C3%A9/x%2By.ts"
        );
        assert_eq!(file_uri(Path::new("/w/a-b_c.d~e")), "file:///w/a-b_c.d~e");
    }

    #[test]
    fn absolute_paths_resolve_dots_lexically() {
        let cwd = Path::new("/w/proj");
        assert_eq!(absolute(cwd, "src/a.ts"), PathBuf::from("/w/proj/src/a.ts"));
        assert_eq!(absolute(cwd, "./x/../b.ts"), PathBuf::from("/w/proj/b.ts"));
        assert_eq!(absolute(cwd, "/abs/c.ts"), PathBuf::from("/abs/c.ts"));
    }

    fn reply(text: &str, is_error: bool) -> Value {
        json::parse(&format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{}}}],\"isError\":{}}}}}",
            json::string(text),
            is_error
        ))
        .unwrap()
    }

    const ENVELOPE: &str = r#"{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///w/a.ts","diagnostics":[{"range":{"start":{"line":1,"character":9},"end":{"line":1,"character":21}},"message":"Type 'string' is not\n  assignable.","severity":1,"code":2322,"source":"typescript"}]}"#;

    #[test]
    fn a_plain_answer_is_ok_with_its_project() {
        let text = format!(
            "{},\"pharos\":{{\"project\":\"/w/tsconfig.json\"}}}}",
            ENVELOPE
        );
        let r = classify(
            "a.ts",
            Path::new("/w/a.ts"),
            "file:///w/a.ts",
            &reply(&text, false),
        );
        assert_eq!(r.status, "ok");
        assert_eq!(r.project.as_deref(), Some("/w/tsconfig.json"));
        assert_eq!(r.diagnostics.len(), 1);
        assert_eq!(
            human_lines(&[r]),
            vec!["a.ts:2:10 error 2322 Type 'string' is not assignable."]
        );
    }

    #[test]
    fn marked_answers_are_unsure() {
        let text = format!(
            "{},\"pharos\":{{\"carried_over\":[\"ts\"],\"carried_over_note\":\"…\"}}}}",
            ENVELOPE
        );
        let r = classify(
            "a.ts",
            Path::new("/w/a.ts"),
            "file:///w/a.ts",
            &reply(&text, false),
        );
        assert_eq!(
            (r.status, r.reason.as_deref()),
            ("unsure", Some("carried_over"))
        );
        assert!(human_lines(&[r]).is_empty());
        let r = classify(
            "a.ts",
            Path::new("/w/a.ts"),
            "file:///w/a.ts",
            &reply(
                "No textDocument/publishDiagnostics notification was received …",
                false,
            ),
        );
        assert_eq!(
            (r.status, r.reason.as_deref()),
            ("unsure", Some("no_publish"))
        );
    }

    #[test]
    fn an_unknown_project_is_unsure() {
        let text = format!("{},\"pharos\":{{\"project_unknown\":true}}}}", ENVELOPE);
        let r = classify(
            "a.ts",
            Path::new("/w/a.ts"),
            "file:///w/a.ts",
            &reply(&text, false),
        );
        assert_eq!(
            (r.status, r.reason.as_deref(), r.project.as_deref()),
            ("unsure", Some("project_unknown"), None)
        );
    }

    #[test]
    fn tool_errors_fail() {
        let r = classify(
            "a.ts",
            Path::new("/w/a.ts"),
            "file:///w/a.ts",
            &reply("no workspace\nroot", true),
        );
        assert_eq!(
            (r.status, r.reason.as_deref()),
            ("failed", Some("no workspace root"))
        );
        let rpc =
            json::parse(r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"bad uri"}}"#)
                .unwrap();
        let r = classify("a.ts", Path::new("/w/a.ts"), "file:///w/a.ts", &rpc);
        assert_eq!((r.status, r.reason.as_deref()), ("failed", Some("bad uri")));
    }

    #[test]
    fn json_output_names_each_file() {
        let text = format!("{}}}", ENVELOPE);
        let r = classify(
            "a.ts",
            Path::new("/w/a.ts"),
            "file:///w/a.ts",
            &reply(&text, false),
        );
        let out = json_output(&[r]).write();
        assert!(out.starts_with(r#"{"files":[{"diagnostics":[{"#));
        assert!(out
            .contains(r#""file":"a.ts","path":"/w/a.ts","status":"ok","uri":"file:///w/a.ts"}]}"#));
    }
}
