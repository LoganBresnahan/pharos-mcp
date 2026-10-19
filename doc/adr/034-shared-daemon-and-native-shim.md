# 034. One shared daemon per build, reached through a native stdio shim

**Status:** Accepted
**Date:** 2026-10-19

## Context

Every MCP client session starts its own pharos
([ADR-030](030-process-lifecycle-hardening.md)). Today that start is a
44 MB node wrapper (`bin/pharos.js`) exec'ing a 58 MB BEAM, so about
100 MB per session before any LSP. The LSPs are the bigger cost: the
pool keys servers on `(language, workspace, server)` inside one BEAM,
so three Claude sessions on one Rust repo run three rust-analyzers,
each indexing the same tree and each holding 1–3 GB.

The Burrito wrapper is also on its way out
([ADR-033](033-burrito-fork-embedded-mode-in-use-lock.md) is a stopgap).
Whatever replaces it has to exec the bundled ERTS itself, so pharos
needs a native front-end binary either way.

Decisions already made by the project owner:

- pharos starts **on demand**, not at login or boot.
- Claude reaches the daemon through a **stdio shim** that spawns the
  daemon when none is running.
- **Windows** keeps `--direct` mode (in-process stdio, today's
  behaviour) and gets no daemon.
- The geex ↔ pharos LSP bridge ([ADR-028](028-universal-editor-bridge.md))
  is deferred.
- The release that ships this is 0.2.0.

What the BEAM side assumes today that a shared daemon breaks:

- **Process cwd.** `.pharos.toml` is found by walking up from the
  process cwd (`config.overlay_project_toml`). The project memory layer
  is the relative path `.pharos/memories` (`memory.project_root`), so
  it also resolves against the process cwd. `PHAROS_WARM_LANGS` warms
  against cwd.
- **Process env.** LSPs inherit the BEAM's environment and are found
  with `os:find_executable/1` on the BEAM's `PATH`
  (`pharos_lsp_port_ffi:spawn/3`). Tool-version managers (mise, asdf,
  rustup, pyenv) resolve through `PATH` shims plus cwd.
- **One config.** `config.load/0` runs once and is cached in
  `persistent_term`. `PHAROS_TOOLS`, the language overrides and the
  `[tool_config]` timeouts all come from it.
- **One client.** `pharos_request_workers` and `pharos_inflight` are
  keyed by the MCP request id alone. Two clients both send id `2`.
  `pharos_session_overrides` (ADR-021) is keyed by `(tool, lang)`.
- **stdin EOF means exit.** `stdio_worker` calls `init:stop` on EOF.

Workspace roots are not on that list: they are derived from file URIs
(`workspace_root.ascend`, [ADR-032](032-workspace-root-determination.md)),
never from cwd, so they already work for any number of clients.

## Decision

pharos becomes two cooperating programs:

- **`pharos` (the shim)**: a small native executable written in Rust.
  With no arguments it is the MCP stdio server that clients launch.
  With any other command it is the launcher that replaces Burrito's
  wrapper.
- **The daemon**: the existing BEAM release, run as `pharos daemon`.
  One per user per build per *daemon key*. It accepts MCP connections
  on a Unix socket and serves each one as a separate MCP session over
  one shared LSP pool.

### The shim

Rust, standard library plus `libc`, no async runtime. Rust rather than
Zig: the shim is long-lived per session and must be boring to
maintain, Rust's toolchain story is stable across our five targets,
and Zig would put us back on the 0.15 → 0.16 churn that pins Burrito
today. It is a separately built executable, not code linked into the
BEAM, which is the shape CLAUDE.md asks for when native code is
added.

`pharos` with no arguments (Linux and macOS):

1. Compute the socket path for this build and daemon key (below).
2. Connect. On success, go to 5.
3. On `ENOENT` or `ECONNREFUSED`, take an exclusive `flock` on the
   sibling `<name>.lock`, blocking with a bounded wait. Under the lock:
   - try to connect again (another shim may have just started it);
   - otherwise check the daemon's `<name>.pid` and unlink the socket
     only if that pid is dead (`kill(pid, 0)`) or its command line is
     not a pharos daemon. A live daemon that is slow to accept is
     waited for, never orphaned;
   - if no daemon is alive, spawn one detached:
     - `fork`, then `setsid`;
     - stdin from `/dev/null`, stdout and stderr appended to the
       daemon's boot log;
     - close every inherited fd ≥ 3 (`close_range`, or iterate where
       that is missing), so a daemon that outlives the session never
       holds one of the client's non-close-on-exec fds;
     - exec the bundled ERTS with `daemon --socket <path>`.

     Where a systemd user manager is running, the spawn goes through
     `systemd-run --user --scope`, so tearing down the terminal's or
     the client's scope cannot take the daemon with it;
   - poll-connect until the socket accepts or
     `PHAROS_DAEMON_START_TIMEOUT_MS` (default 15000) runs out.

   Then release the lock. The lock fd is close-on-exec, so the daemon
   never holds it.
4. If the daemon could not be reached, the next step depends on
   `PHAROS_MODE`:
   - `auto` (the default) prints one stderr line naming the boot log
     and falls back to `--direct`. A broken daemon is never worse than
     today. A stderr line only reaches a client log nobody reads, so
     the shim also appends the fallback (time, reason, build) to
     `$XDG_STATE_HOME/pharos/log/fallbacks.log`, and `--doctor`
     reports recent fallbacks.
   - `daemon` exits 1 instead. Tests and CI use it.
5. Send the hello, read the ack, then copy bytes both ways until stdin
   closes.
6. On stdin EOF, half-close the socket (`shutdown(SHUT_WR)`), keep
   copying daemon → stdout until the daemon closes or 3 s pass, then
   exit 0.

Only daemon bytes received after the ack reach stdout, and only whole
lines. The daemon → stdout relay writes each read up to its last
`\n` and holds the tail until the next read completes it. When the
connection is lost, the tail is dropped. That is a byte scan, not JSON
parsing, and the buffer is bounded by the largest frame. Without it, a
daemon dying mid-frame would leave half a line on the client's stdout.
Every shim diagnostic goes to stderr, prefixed `pharos:`. The shim runs
two threads with blocking I/O, so it holds about a megabyte per
session.

`PHAROS_MODE=direct`, the `--direct` flag, any `PHAROS_TRANSPORT`
other than `stdio`, and every Windows build exec the BEAM in-process
exactly as today. The HTTP transport stays a direct-mode feature: the
daemon multiplexes stdio sessions only.

### The launcher

Every other invocation (`--version`, `--help`, `--doctor`,
`--cleanup`, `--print-*`, `warm …`, `daemon …`, `--direct`, and the
successor of `--purge-cache`, which ADR-035 defines) execs the bundled
ERTS directly: `erlexec` from `<release>/erts-*/bin` with `ROOTDIR`,
`BINDIR`, `EMU`, `PROGNAME` and `RELEASE_ROOT` set, plus
`-boot <release>/releases/<vsn>/start -mode embedded -boot_var
RELEASE_LIB <release>/lib`, the release's `sys.config` and `vm.args`,
`-noshell -noinput`, and the pharos arguments after `-extra`. `-mode` and
`embedded` are separate argv elements, as ADR-033 found the hard way. On
Unix this is a real `execve`, so the BEAM takes over the shim's pid and
stdio. On Windows, which has no `exec`, the shim spawns the BEAM with
inherited handles inside a kill-on-close Job Object and returns its
exit code.

The shim finds its release relative to its own resolved path, so it
works in the npm package and in the versioned install layout without
configuration. `--version` is answered by the shim from the release
metadata, with no BEAM boot.

### Build id and daemon key

- **Build id**: the first 16 hex digits of a SHA-256 over the release
  tree (ERTS, `lib/`, `releases/`) **and the shim binary**, so the
  shim and the daemon can never skew within one id. It is computed
  when the release is
  packaged and written to `<release>/BUILD_ID`. A rebuilt dev build
  with any changed byte gets a new id. A byte-identical rebuild joining
  the old daemon is harmless.
- **Daemon key**: 8 hex digits of a digest over the env vars that
  shape the whole daemon rather than one session: `HOME`,
  `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
  `XDG_CACHE_HOME`, and the daemon-scoped `PHAROS_*` vars (`PHAROS_LOG`,
  `PHAROS_LOG_FILE`, `PHAROS_LOG_STDERR`, `PHAROS_LOG_RING`,
  `PHAROS_SASL`, `PHAROS_TRACE_LSP`, `PHAROS_HEARTBEAT_INTERVAL_MS`,
  `PHAROS_SHUTDOWN_DRAIN_MS`, `PHAROS_DAEMON_IDLE_SECS`,
  `PHAROS_LSP_IDLE_SECS`). The list lives in one place in the shim, and
  a test pins it. A session started with `PHAROS_LOG=debug`, or a test
  sandbox with its own `HOME`, gets its own daemon instead of silently
  inheriting another's.

### Socket location

- **Linux**: `$XDG_RUNTIME_DIR/pharos/<build>-<key>.sock`. If
  `XDG_RUNTIME_DIR` is unset, `/tmp/pharos-<uid>/`.
- **macOS**: `$TMPDIR/pharos/<build>-<key>.sock`. `$TMPDIR` is already
  per-user (`/var/folders/…/T/`). The name is at most 30 bytes, so a
  typical path is about 85 bytes, under the 104-byte `sun_path` limit.
  If the full path would exceed 100 bytes, use `/tmp/pharos-<uid>/`.
- Every socket dir is created `0700`. The shim refuses to use one that
  is not owned by the current uid or that allows group or other
  access, and says why on stderr. The socket, its `.lock` and the
  daemon's `.pid` sit beside each other. Directory permissions are the
  access control, as with `ssh-agent` and `tmux`.
- macOS's periodic cleaner deletes `$TMPDIR` files left untouched for
  about three days. If it removes a live daemon's socket, the next shim
  starts a second daemon for the same key. That is harmless: the old
  one keeps its sessions and idles out.

The shim passes the socket path to the daemon as an argument. Path
logic lives only in the shim.

### Hello preamble

The first line the shim sends is a JSON object (at most 1 MiB):

```json
{"pharos_hello": 1, "op": "mcp", "build": "<build id>",
 "cwd": "/abs/cwd", "env": {"PATH": "…", "...": "…"},
 "client_pid": 4242, "shim_pid": 4250}
```

`env` is the shim's whole environment. `client_pid` is the shim's
parent, which is the MCP client.

The env carries secrets: API keys live in client environments. The
daemon never logs it, never returns it from `status`, and never puts
it in an MCP response, `runtime_language_config` included. Wherever
pharos reports which session started an LSP, it gives the session id
and cwd, never the env. The env is still process state, so a crash
dump contains it: crash dumps are created `0600` in a `0700`
directory. The daemon itself also runs with its first shim's whole
env, secrets included, for as long as it lives. That is the same uid
only: `/proc/<pid>/environ` is readable by the owner alone. The daemon answers with one line,
either `{"pharos_hello_ok": 1, "session": "<id>", "daemon_pid": N}` or
`{"pharos_hello_error": "<reason>"}` followed by a close. A build
mismatch is refused: it can only happen if a release was rebuilt in
place under a live socket. After the ack the connection carries the
client's newline-delimited JSON-RPC unchanged. The daemon does its own
line reassembly, because gen_tcp's `{packet, line}` truncates lines
longer than the receive buffer and MCP lines carry whole files.

Two more ops share the preamble for operator use: `status` (build,
uptime, sessions, LSPs) and `stop` (orderly ADR-030 shutdown). They
back `pharos daemon status` and `pharos daemon stop [--all]`.

### Inside the daemon: what's shared and what's per session

Each accepted connection gets a **session context** built from its
hello: the cwd, the env, a Config resolved the way `config.load/0`
resolves it today (defaults, then the global TOML, then `.pharos.toml`
walked up from the *session* cwd, then the `PHAROS_*` session vars),
and the language registry merged from that Config. Contexts are cached
by `(toml path, toml mtime, digest of the PHAROS_* session vars)`, so
identical sessions share one parsed Config. The connection's reader
replaces `stdio_worker`'s stdin port with the socket. Its dispatchers
carry the session id in their process dictionary, set once at spawn.
`config.cached/0` and `registry.cached/0` resolve through it and fall
back to the daemon's own Config. The tools keep their signatures.

Direct mode is one session context built from the process cwd and
env, through the same code. The two modes cannot drift. Every
connection, including direct mode's stdio, has its own writer: the
per-worker `WriterMsg` subject `stdio_worker` already uses. Nothing
server → client goes through a global writer.

| State | Scope | Why |
|---|---|---|
| LSP processes (`pool`, `lsp_dyn_sup`, `pharos_lsp_proc_subjects`) | **shared**, keyed `(language, root, server, spawn fingerprint)` | The whole point. |
| didOpen dedupe, `capabilities` | shared | Properties of an LSP process, not of a client. |
| `pharos_diagnostics_cache` (by URI) | shared | It is what the LSP said about the file on disk; both sessions see the same disk. |
| `pharos_request_workers`, `pharos_inflight` | **per session**: keys become `(session, mcp_id)` | MCP ids are per connection, so two clients both send id `2`. `notifications/cancelled` must only reach its own session. |
| `runtime_set_tool_timeout` (`pharos_session_overrides`) | **per session**: key `(session, tool, lang)`, dropped on disconnect | One agent's "jdtls is slow, wait 5 min" must not change another agent's behaviour. "Survives the session" (ADR-021) now means the connection, which is what an MCP client sees as a session. |
| Tool filter (`PHAROS_TOOLS`, `[tools]`), `[tool_config]` timeouts | per session (from the session Config) | They are client configuration. |
| Memory tools | per session **resolution**, shared **storage** | The project layer becomes `<session cwd>/.pharos/memories` (or `PHAROS_MEMORY_ROOT` from the session env), fixing the old process-cwd dependency. The user layer is `HOME`-based, and `HOME` is in the daemon key. The files are the only state, so concurrent sessions already coordinate through `exclusive_write` and `atomic_write`. |
| Log ring, log file, heartbeat | daemon-wide | Every entry from a dispatcher gets a `session` field. |
| ADR-030 instance dir | daemon-wide, keyed by the daemon's pid | `pharos --cleanup` keeps working unchanged. |

**Spawn fingerprint and env.** An LSP for a root runs with the env of
the session that started it:

- Its command is resolved with `os:find_executable(Name, SessionPATH)`.
- It runs with cwd = the workspace root, which is what mise, asdf and
  pyenv resolve against.
- `open_port` gets `{env, …}` set to the session env, with every var
  the daemon has but the session lacks unset (`{Name, false}`).

The spawn fingerprint is a digest of the **resolved absolute command
path**, the effective server config (args, init options, settings)
and the values of the language's `env_keys`. `env_keys` is a new
per-language list in the registry, overridable in TOML. The bundled
defaults name the variables known to change an LSP's answers:

- python: `VIRTUAL_ENV`, `CONDA_PREFIX`, `PYTHONPATH`
- java: `JAVA_HOME`
- go: `GOFLAGS`, `GOWORK`, `GOPATH`, `GOROOT`
- rust: `RUSTUP_TOOLCHAIN`, `CARGO_HOME`, `CARGO_TARGET_DIR`

So two sessions on one root share an LSP when they resolve the same
binary with the same config and agree on those variables. Otherwise
each gets its own, exactly as two roots would. `PATH` itself is not in
the fingerprint: Claude sessions prepend different entries all the
time, and the resolved binary already captures what `PATH` decided.
A later session that joins an LSP gets the starter's env for the
variables outside `env_keys`. That is the documented trade, and
`runtime_language_config` shows which session started each LSP, by
session id and cwd.

Known limit: the diagnostics cache stays keyed by `(uri, server id)`
without the variant. When two variants of one server run on the same
root (two sessions with different `VIRTUAL_ENV`s, say), their pushed
diagnostics for a shared file overwrite each other, and the last push
wins. Keying it by variant would need every diagnostics lookup to
rebuild the spawn spec. Revisit if it shows up in practice.
`runtime_kill_lsp` with a bare server id stops every variant, including
ones other sessions are using. That is acceptable for a debug tool, and
its description says so.

### Lifecycle

- **Daemon idle exit**: no connections for `PHAROS_DAEMON_IDLE_SECS`
  (default 1800). It then runs the ADR-030 orderly shutdown and removes
  its socket. In-flight work counts only through its connection, and
  an open connection is never idle.
- **LSP idle stop**: an LSP with no request routed to it, from any
  session, for 1800 s is stopped the way any eviction stops one: its
  stdin closes. A language can set its own `idle_stop_secs` (TOML), and
  `PHAROS_LSP_IDLE_SECS` overrides every language. `0` means never. Bundled defaults are 7200 for
  java, scala and haskell, whose cold starts take minutes. Today an
  LSP lives as long as its session, so this is new, deliberate memory
  reclamation.
- **Session end**: on connection EOF the daemon drains that session's
  in-flight requests for up to `PHAROS_SHUTDOWN_DRAIN_MS`, cancels the
  rest (`$/cancelRequest` plus a dispatcher kill, the existing cancel
  path), drops the session's overrides and context, and closes.
  `init:stop` is no longer reached from a session.
- **Upgrade**: a new build has a new build id, so a new socket and a
  new daemon. The old daemon keeps serving the sessions it has and
  exits on its idle timer. It runs entirely from its own release
  folder. The release root is in its argv (`-root`), which is what
  install-layout pruning keys on (ADR-035). With embedded mode
  (ADR-033) nothing it loads comes from disk after boot except lazily
  started port programs.
- **SIGTERM** to the daemon is the ADR-030 drain. Every connected shim
  sees EOF.

### Daemon crash

In v1, a shim whose socket closes while stdin is still open writes
`pharos: lost connection to the pharos daemon (<reason>); restart the
MCP server to reconnect. Daemon log: <path>` to stderr and exits 1. Its
stdout carries only the complete frames already relayed. The client
marks the server failed. Reconnecting (`/mcp` in Claude Code) starts a
new shim, which starts a new daemon.

Stretch, not v1: the shim keeps the client's `initialize` request and
`initialized` notification. On loss it respawns, replays the hello and
both messages, swallows the replayed `initialize` reply, and answers
each request that was in flight with a JSON-RPC error. That requires
the shim to parse lines, which v1 avoids.

### Logs

`$XDG_STATE_HOME/pharos/log/`, defaulting to `~/.local/state/pharos/log/`
on both Linux and macOS:

- `daemon-<build>-<pid>.log`: the structured log, with the existing
  size rotation (`file_max_bytes`, `file_keep_rotated`).
- `daemon-<build>-<key>.boot.log`: the daemon's raw stdout and stderr, for
  failures before the logger is up. The shim truncates it at spawn
  when it exceeds 1 MiB.

The ADR-030 C2 LRU (keep 10 session logs, 5 crash dumps) moves to this
directory and covers both daemon and direct-mode logs. Direct mode's
default log dir moves from `~/.cache/pharos/log/` to the same place,
since logs are state, not cache.

### stdout

In daemon mode, sacred invariant 1 holds structurally. The client's
stdout is written only by the shim, and only with bytes from the
session's socket. The daemon's own fd 1 is the boot log, so a stray
`io.println` in the daemon lands there and cannot corrupt any client.
In direct mode the invariant applies exactly as today.

## Consequences

- N sessions on one repo cost one daemon (about 60 MB) plus one set of
  LSPs, not N × 100 MB plus N sets. Each session's own cost is about
  1 MB for the shim, once ADR-035 removes the resident node wrapper.
- A second session on a warm repo answers immediately. Today it pays
  the full cold start (jdtls 5–15 min) again.
- LSPs now stop when idle. A session that comes back after 30 quiet
  minutes pays one cold start. That is tunable per language, and the
  slow starters default to 2 h.
- Invariant 4 ("never add a global single-instance lock") needs new
  wording, not an exception. The spawn lock is per build and daemon
  key and only serializes daemon startup. Any number of sessions
  share the daemon, any number of daemons coexist across builds and
  keys, and `--direct` instances stay fully independent. ADR-030's
  per-PID partitioning still holds, keyed by the daemon's pid. The
  approved rewording of CLAUDE.md's invariant 4, which Logan applies:
  "Multi-session is the norm. Sessions share a daemon per build and
  daemon key (ADR-034), and `--direct` instances stay independent.
  Never add a lock that limits sessions; the only lock serializes
  daemon startup. Partition on-disk state by the owning pharos PID
  (ADR-030)."
- A daemon crash now takes down every session on it, not one. That is
  why the v1 failure mode is a loud, immediate stderr line, and why
  `PHAROS_MODE=auto` falls back to `--direct` when the daemon cannot
  start.
- Two languages to maintain: a Rust crate (`shim/`) with its own CI
  job (fmt, clippy, tests) on Linux, macOS and Windows. Mix stays
  authoritative for the BEAM side (invariant 2). Cargo builds the shim
  and the release step pairs them.
- macOS arm64: anything stripped or patched after linking is re-signed
  ad hoc (`codesign -s - -f`) before packaging, or the kernel kills it.
- The tools keep their signatures, but `config.cached/0`,
  `registry.cached/0`, the memory roots and the inflight and override
  tables change meaning (per session). Tests must cover two concurrent
  sessions with different configs.
- `PHAROS_WARM_LANGS` from a session env warms against that session's
  cwd. `pharos warm` keeps working in direct mode.
- `doc/architecture.md` gains the daemon process tree: an acceptor, one
  reader actor per connection in place of the singleton
  `stdio_worker`, and the idle timers.

### Tests

The shim crate has unit tests for:

- socket path choice and the 100-byte fallback;
- refusing a bad socket dir;
- daemon-key digest stability;
- hello encoding.

The Gleam suite has unit tests for:

- hello parsing and refusal;
- `(session, mcp_id)` scoping of cancel;
- the open_port env diff;
- spawn fingerprints;
- per-session Config resolution and its cache.

Integration tests run in a new CI job on Linux and macOS. They drive a
built release plus shim with a temp `HOME` and temp `XDG_*` dirs,
`PHAROS_MODE=daemon`, and `bin/_stub_lsp.py` as the LSP. The stub
records its own pid, and its env-driven behaviour proves which session's
env an LSP got. The checks are:

1. **Two shims share one daemon and one LSP**: both get correct
   answers, `daemon status` shows one daemon, and the stub logged one pid.
2. **Spawn race**: 8 shims start at once against no daemon. Exactly one
   daemon process exists for the key, and all 8 initialize.
3. **Builds stay isolated**: two releases with different `BUILD_ID`s
   get two sockets and two daemons, and a hello with the wrong build is
   refused.
4. **Idle exit**: with `PHAROS_DAEMON_IDLE_SECS=2` the daemon exits and
   removes its socket after the last shim leaves. With
   `PHAROS_LSP_IDLE_SECS=2` the stub LSP gets `shutdown` while a
   session stays connected.
5. **Daemon death**: SIGKILL the daemon in the middle of a large
   response. The shim exits 1 within a second with the stderr line,
   and its stdout holds only complete frames.
6. **stdout stays clean**: every stdout line in every scenario parses
   as a JSON-RPC frame, including runs with `PHAROS_LOG=debug` and
   `PHAROS_INSTALL_DIR` set.
7. **Per-session isolation**: two sessions with different
   `PHAROS_TOOLS` see different `tools/list`. A cancel in one session
   doesn't touch the same id in the other. A timeout override in one
   doesn't apply to the other. No secret-looking env value from a
   hello shows up in the log, in `status`, or in any tool response.
8. **The daemon outlives the terminal that spawned it**: start it from
   shell A (`setsid`), keep a session open from shell B, then kill A's
   terminal. The daemon and B's session survive. CI covers Linux, and
   the coordinator repeats it on WSL and macOS by hand.
9. **Stale sockets**: a socket file whose `.pid` is dead is replaced. A
   live daemon that is slow to accept (stopped with SIGSTOP) is waited
   on and never unlinked.
10. **Fd hygiene**: a shim started with an extra non-close-on-exec fd
    spawns a daemon that doesn't hold it (checked via
    `/proc/<pid>/fd` on Linux, `lsof` on macOS).

The post-release smoke workflow (ADR-035) repeats 1, 4 and 6 against
the published artifacts with a real LSP.

## Alternatives considered

- **Keep one BEAM per session.** Rejected: about 100 MB per session,
  and every session re-pays every LSP's memory and cold start.
- **Have clients connect to pharos's HTTP transport directly.**
  Rejected:
  - Nothing would start it on demand.
  - A TCP port is reachable by every local user and would need a token.
  - Per-session cwd and env don't exist over HTTP.
- **A shim that speaks MCP-over-HTTP to the daemon.** Rejected: the
  shim would have to understand MCP. The byte pipe keeps it dumb.
- **Shim in node** (`bin/pharos.js` piping to the socket). Rejected:
  that is the 44 MB per session we're removing.
- **Shim as an escript or tiny BEAM.** Rejected: still a VM per
  session.
- **Shim in Zig.** Workable, but Zig's breaking releases are what pin
  Burrito today. The coordinator prefers Rust, and nothing here favours
  Zig.
- **One daemon per user across builds, upgraded with hot code
  loading.** Rejected: in-place upgrades of a process holding live LSP
  ports are fragile. Per-build sockets make an upgrade a fresh process
  and make old/new isolation automatic.
- **One daemon per user regardless of env.** Rejected: a test sandbox
  or a `PHAROS_LOG=debug` session would silently join a daemon with a
  different `HOME` and log setup.
- **systemd socket activation or launchd.** Rejected: the owner chose
  on-demand start from the shim, and it would be two platform-specific
  mechanisms instead of one.
- **Shim as a hidden Erlang distribution node.** Rejected: it needs
  epmd and cookies and is still a VM.
- **Put `PATH` in the spawn fingerprint.** Rejected: Claude sessions
  differ in `PATH` constantly, so nothing would ever share. The resolved
  binary path captures the decision `PATH` made.
- **Reconnect and replay in v1.** Deferred: it makes the shim parse
  JSON-RPC and track in-flight ids. Fail loud first, and add it if
  daemon crashes turn out to happen in practice.
