# 030. Process lifecycle hardening: boot, shutdown, and cleanup

**Status:** Accepted
**Date:** 2026-05-22

## Context

Pharos is a BEAM-based MCP server launched on demand by MCP clients
(Claude Code, Cursor, ChatGPT desktop). The expected lifecycle is short
and noisy:

- Multiple instances run concurrently — one per MCP client session.
- Restarts happen often. Users restart Claude Code, the host machine
  shuts down or hibernates, the client tears down its child process on
  exit.
- Each instance spawns multiple long-lived child processes — one
  rust-analyzer, gopls, jdtls, etc., per project — and jdtls / metals
  spawn their own grandchildren.
- Stdin/stdout are the JSON-RPC transport; stderr is the diagnostic
  channel. Any of the three can be closed or redirected to `/dev/null`
  by the parent at any moment, including mid-boot.

Three failure modes have surfaced in the v1.0-rc1 prep window
(2026-05-21 → 2026-05-22) and are not yet addressed:

### Failure mode 1 — pre-`main` boot panic on closed `standard_error`

OTP's default `logger_std_h` and SASL `error_logger` handlers are
installed by the boot supervision tree before `pharos:main/0` is ever
called. When those handlers attempt `:io.put_chars(:standard_error, …)`
on a closed file descriptor 2, the BEAM raises `:badarg` ("device does
not exist"). That `:badarg` becomes a logger event that the same
handler tries to write to the same dead device, and BEAM terminates
the runtime with slogan:

```
Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,…
```

ADR commit e81d87a (2026-05-21) wrapped pharos's own
`install_sasl_capture_handler/0` in try/catch, which addresses the
in-`main` path only. The same `erl_crash.dump` file has been
overwritten three times since (2026-05-22 01:45, 07:24, 08:00) — every
overwrite is a pre-`main` panic that our wrap cannot reach. The 08:00
overwrite occurred when the user restarted Claude Code, confirming
that ordinary MCP-server spawn-during-host-shutdown is enough to
trigger this.

### Failure mode 2 — ungraceful shutdown on signal or stdin close

Today's shutdown path is implicit: when stdin closes (parent died) or
SIGTERM arrives, BEAM halts on its default schedule, which can hit the
same closed-stderr panic as Failure mode 1. There is no orderly drain
of in-flight MCP requests, no LSP `shutdown`/`exit` sent to children,
and no guarantee LSP children receive SIGTERM. On hosts that race
filehandle teardown against BEAM startup (WSL2 host shutdown,
`pkill claude`), the result is a crash dump in `cwd` and live LSP
processes orphaned with no parent.

### Failure mode 3 — silent death during extended idle

The trigger that started this entire investigation. Observed in
Phase 5 attempt 1 (2026-05-21) across all five featured languages
running in parallel. Concrete signature from
`bench/results/v1.0-final/phase5-partial-stderr-blind/python.log`:

```
[q0022 pro-thinking control trial=0]      t=400.5s
[q0022 pro-thinking treatment trial=0]    t=304.8s    ← last OK pharos call
[q0023 pro-thinking control trial=0]      t=393.7s    ← ~6.5 min idle
[q0023 pro-thinking treatment trial=0]    BrokenPipeError on tools/list
```

The harness alternates a **control** cell (Bash / Read / Grep — does
not touch pharos) with a **treatment** cell (pharos). Hard questions
in control run 5–7 minutes each. During that window pharos sits idle
with several large LSP children loaded. After a long enough idle
(≈6–7 min in attempt 1) the next pharos request gets `BrokenPipe` —
the pharos process is gone.

Because attempt 1 ran with `stderr=DEVNULL`, no trace survived. The
crash diagnostics work (commit e81d87a) and the harness patch
(commit 8d06872 — `capture pharos stderr so broken-pipe crashes leave
a trace`) were both reactions to this gap, not solutions to the
underlying death. **We still do not know why pharos died.** Working
hypotheses:

1. **WSL2 OOM-killer.** 5 pharos × N LSP children + Phase 5 client
   memory + DeepSeek streaming buffers approaches the host's 23 GB
   limit. Linux OOM-killer picks the idlest large process.
2. **LSP grandchild died and crashed pharos via port termination.**
   jdtls / rust-analyzer occasionally die after indexing; if pharos
   doesn't handle the port crash cleanly, the BEAM supervisor may
   bubble it up and halt.
3. **BEAM scheduler / GC panic during idle.** Lower-probability;
   no Erlang priors for this.

Phase 5 attempt 2 ran past q22-29 successfully (1448 cells captured
before WSL host restart, not crash), suggesting either the harness
stderr-capture removed the death trigger by accident, or the
re-extracted Burrito binary differed in a relevant way, or the WSL
host had less memory pressure on that run. Without a deliberate
repro we cannot tell.

### Failure mode 4 — orphan LSPs after unclean prior exit

Even when pharos itself exits, rust-analyzer / gopls / jdtls children
poll stdin on multi-second intervals (relabeled from "failure mode 3"
in earlier draft; failure mode 3 is now the idle-death pattern above). Between pharos dying and the
child noticing EOF, anything from a few seconds (gopls) to a minute
(jdtls cold) can elapse. If the host kills pharos with SIGKILL or
OOM-killer or a hard power-off — or if pharos boot-panics before
emitting its registration of these children — the children outlive
pharos with no supervisor.

The user has also confirmed they restart Claude Code regularly and
hard-shutdown the machine when it misbehaves. Both are normal user
behaviors. Pharos cannot prevent them; it must tolerate them.

### Constraints

- **Multi-instance is the norm.** Each MCP client session spawns its
  own pharos. We must not enforce single-instance global locks.
- **Cleanup must be per-PID.** Global state must be partitioned by
  the pharos PID that owns it.
- **No NIFs in v1.0.** `PR_SET_PDEATHSIG` would be the ideal Linux
  belt-and-suspenders against orphan LSPs (kernel auto-SIGKILLs
  children on parent death), but a NIF + zig shim is too much surface
  for the v1.0 release. Defer to v1.1.
- **macOS lacks an equivalent** of `PR_SET_PDEATHSIG`; Windows has
  `JobObject` (also v1.1). The manual `pharos cleanup` subcommand
  must carry cross-platform.

## Decision

We treat process lifecycle as a v1.0 release blocker and ship four
layers of hardening, in this order. Each layer addresses one of the
four failure modes; the layers compose so that any single one being
bypassed still leaves the next in place.

### Layer 1 — Boot hardening (B1)

**B1. `sys.config` logger override.** Replace OTP's default
`logger_std_h` handler config with a try/catch-tolerant variant that
no-ops on dead-device writes. Lives in the OTP `sys.config` loaded
during release boot — strictly before `pharos:main/0`, before the
in-`main` SASL capture handler installs. Catches every pre-`main`
panic path. This is the root-cause fix; with B1 in place the
pre-main panics that wrote our investigated crash dumps simply do
not occur, so dump location becomes moot.

(An earlier draft included B2 — `ERL_CRASH_DUMP` set via a vendored
Burrito wrapper patch — as belt-and-suspenders. Dropped: B1 fixes
the root cause, and vendoring a patch into `deps/burrito/` creates
permanent re-merge cost on every Burrito upgrade for a scenario
B1 should prevent.)

### Layer 2 — Shutdown hardening (S1, S2, S3)

**S1. Signal traps.** Install handlers for SIGTERM, SIGINT, SIGHUP
via `os:set_signal/2` at the start of `pharos:main/0`. Each signal
triggers the same orderly drain: stop accepting new MCP requests,
allow in-flight requests up to a configurable deadline
(`PHAROS_SHUTDOWN_DRAIN_MS`, default 2000), send LSP `shutdown` +
`exit` requests to every active child, close stdio, halt with code 0.
No panic dump.

**S2. Unify normal-exit and signal-exit paths.** Stdin EOF (parent
closed the pipe) → same drain sequence as S1. Today these are
separate; converge so any clean-exit trigger runs one orderly
shutdown function.

**S3. Per-LSP PID tracking.** On every LSP spawn, write
`~/.local/share/pharos/instances/<pharos-pid>/<lsp-name>.pid` with
content `<pharos_pid>:<lsp_pid>:<lsp_binary>` (one line). On graceful
exit (S1 or S2), remove the file. The file is the contract with
`pharos cleanup` — it represents "this child belongs to a pharos
instance that may or may not still be alive." No starttime
recorded: PID-reuse risk on the pharos side is handled by `kill -0`
plus the user-confirmation flow in `pharos cleanup`; PID-reuse risk
on the LSP side is mitigated by the recorded `<lsp_binary>` name
being verified against the candidate PID's process name before any
signal is sent.

### Layer 2.5 — Idle resilience (I1, I2)

Failure mode 3 (silent idle death) needs diagnosis before
remediation. The fix depends on the cause: an OOM-killer can be
addressed with cgroup hints, an LSP-grandchild crash with stricter
port-exit handling, a BEAM scheduler bug with a runtime flag. We
ship two observability hooks now so the next reproduction surfaces
actionable data:

**I1. Idle heartbeat to log writer.** When pharos has not received
an MCP request for `PHAROS_IDLE_HEARTBEAT_MS` milliseconds (default
60_000), emit a single-line log entry to the pharos log file with
memory stats (`erlang:memory/0`), LSP child count, and process
count. Cheap, side-effect-free, and gives us a timeline if pharos
dies during idle on a future run.

**I2. LSP port-exit visibility.** When any LSP child port exits
(normal or abnormal), log the exit reason and which LSP it was. If
the BEAM supervisor restarts it, log the restart. If supervisor
gives up and pharos halts, the log captures the cascade. ~20 LOC
in the LSP supervision module.

If T5 parallel-×5 reproduces the idle death, I1+I2 give us the
post-mortem to fix root cause. If T5 cannot reproduce, I1+I2 are
still cheap insurance against the same pattern recurring in
production.

### Layer 3 — Cleanup tooling (CLI, C2)

(Earlier draft had a `C1` auto-reaper at boot. Dropped: the
auto-reaper requires platform-divergent process introspection
code (`/proc/<pid>/stat`, `ps`, `wmic`), runs without explicit user
intent, and carries nonzero risk of false-positive kills under
PID-reuse. The user-driven `pharos cleanup` subcommand below
covers the same scenario with explicit consent and identical
cross-platform UX.)

**`pharos cleanup` CLI subcommand.** New top-level command. Scans
`~/.local/share/pharos/instances/`. For each subdir:

1. Parse the owner pharos PID from the dir name.
2. Send signal 0 (`kill -0 <pid>`): if it succeeds, owner is alive →
   skip the dir entirely (regardless of how old it is).
3. If owner is dead (ESRCH) or not ours (EPERM): for each
   `<lsp-name>.pid` file in the dir, parse `<lsp_pid>:<lsp_binary>`,
   verify the candidate LSP PID's process name matches
   `<lsp_binary>` (Linux: `/proc/<pid>/comm`; macOS: `ps -o comm=`;
   Windows: `tasklist`), and queue it for reaping. Mismatches mean
   PID-reuse and are skipped.
4. Print the full reap list with PID, binary name, and age (mtime
   of the pid file).
5. If invoked with `--dry-run`: exit. If invoked with `--yes`:
   proceed without prompting. Otherwise: prompt "Reap N orphans?
   [y/N]".
6. On confirm: SIGTERM each LSP, wait
   `PHAROS_CLEANUP_GRACE_MS` (default 5000) milliseconds, SIGKILL
   survivors, remove the subdir.

The CLI is the v1.0 mechanism for "user notices memory pressure or
weird state after a series of unclean shutdowns." Document it
prominently in the README troubleshooting section. I1's heartbeat
(LSP child count in the log) gives users an early signal that
cleanup may be warranted.

**C2. Session log + crash-dump rotation.** Three pieces:

1. **Default `PHAROS_LOG_FILE` to a per-PID timestamped path:**
   `~/.cache/pharos/log/session-<pid>-<YYYY-MM-DD-HHMMSS>.log`.
   Today the env var is unset by default → no file logging. With
   multi-instance pharos (Phase 5 was the trigger) a shared path
   would clobber. Per-PID-per-timestamp gives every instance its
   own file without coordination. User can still override the env
   var explicitly.
2. **LRU rotation of session logs:** keep the most recent N=10
   `session-*.log` files in the cache dir; delete older.
   Configurable via `PHAROS_LOG_KEEP`.
3. **Same LRU on `erl_crash-*.dump`:** keep 5 most recent. If a
   stray `erl_crash.dump` exists in cwd from a legacy/external
   spawn, move it into the cache dir at boot. ~30 LOC.

### Layer 4 — Test infrastructure (T1–T4)

Forcing each failure mode and asserting the catches fire is the
only way to know the layers work. These tests live in
`bench/crash-repro/` and run sequentially in CI:

- **T1. `closed-stderr.sh`** — spawn pharos with `2>&-` (close fd 2
  in the shell), feed a trivial MCP `initialize` request, assert:
  no crash dump written, pharos answered correctly, clean exit on
  EOF. Tests B1.
- **T2. `sigterm.sh`** — spawn pharos, send an MCP `initialize`,
  spawn one LSP session, SIGTERM the pharos PID, wait 3 seconds,
  assert: 0 orphan LSPs in `ps`, the per-PID instance dir is gone,
  exit code 0. Tests S1 + S3.
- **T3. `cleanup-cli.sh`** — spawn pharos, force-spawn an LSP,
  SIGKILL the pharos PID (skipping graceful path), assert orphan
  LSP exists and per-PID dir remains on disk. Run
  `pharos cleanup --dry-run`, assert the orphan is listed. Run
  `pharos cleanup --yes`, assert: orphan LSP killed, per-PID dir
  removed, exit code 0. Then re-run `pharos cleanup --dry-run`
  and assert the list is empty. Tests S3 + the cleanup CLI.
- **T4. `session-log-rotation.sh`** — spawn 12 pharos instances in
  sequence (each exits immediately after init), assert
  `~/.cache/pharos/log/` contains exactly 10 `session-*.log` files
  (the oldest 2 LRU-deleted), per-PID-per-timestamp naming
  preserved. Tests C2.
- **T5. `idle-death-repro.sh`** — pin the Phase 5 attempt 1
  pattern. Spawn pharos, send `initialize`, open 3 large LSP
  sessions (rust-analyzer on a non-trivial Rust workspace, gopls
  on a Go module, jdtls on a Java project), sleep 600 seconds with
  no further calls, then send `tools/list` and assert it returns
  OK. Run in two configurations:
  1. **single-instance** — one pharos, plenty of host memory.
     Expected: passes. If it fails we have a clean BEAM idle bug
     that we must fix.
  2. **parallel × 5** — five pharos instances, each with 3 LSPs,
     same workspace fixtures as Phase 5. Memory-pressure analog.
     Expected: matches Phase 5 attempt 1 outcome — either reveals
     the death and we capture the surviving stderr / crash dump
     (now that diagnostics land), or passes consistently, in which
     case we know memory pressure is the trigger and Phase 5
     attempt 2 succeeded because the host had less load.

  T5 is gating in the single-instance form. The parallel-×5 form
  is investigative: if it fails we file the root cause as a
  separate ADR (likely an LSP supervision change) and decide
  whether to block v1.0 on it.

T1–T5 are gating (with T5 caveat above): a v1.0 RC tag cannot ship
if any fails.

## Consequences

### Easier

- **Restart-during-shutdown becomes routine.** The most common user
  behavior (closing Claude Code, sleeping the laptop) stops
  producing crash dumps; B1 catches the pre-main panic, S1 catches
  signals, S2 catches stdin-EOF.
- **Multi-instance log inspection.** Per-PID-per-timestamp session
  log naming means five-pharos benchmarks (Phase 5 style) leave
  five readable files instead of one corrupted mess. `ls -lt
  ~/.cache/pharos/log/` chronicles every session.
- **Future failure modes get test coverage by default.** The
  `bench/crash-repro/` harness is the obvious place to drop the
  next failure repro when one surfaces.
- **Per-PID cleanup contract is explicit.** Anything pharos spawns
  that should die with pharos goes in
  `~/.local/share/pharos/instances/<pid>/`. `pharos cleanup`
  handles the unclean-exit case.

### Harder

- **`sys.config` precedence.** B1 means the Gleam `logging`
  library's user-facing handler config must be applied **after**
  the sys.config defaults; this is the existing behavior but we
  now depend on it. Document explicitly.
- **Users must know `pharos cleanup` exists.** Without an
  auto-reaper, orphan LSPs from unclean prior exits accumulate
  until the user runs the command. Mitigations: README
  troubleshooting section as the primary discovery path; I1's
  idle heartbeat logs LSP child count so users have a numeric
  signal in their logs.

### Risks

- **S1's 2-second drain deadline is a guess.** LSP `shutdown`
  responses may take longer; jdtls in particular has been slow.
  Make the deadline configurable via env var
  (`PHAROS_SHUTDOWN_DRAIN_MS`, default 2000); document.
- **`pharos cleanup` PID-reuse on the LSP side.** A dead pharos's
  LSP PID may have been reused by an unrelated process. Mitigation:
  before sending any signal, verify the candidate PID's process
  name against the recorded `<lsp_binary>` (`/proc/<pid>/comm` on
  Linux, `ps -o comm=` on macOS). Mismatches abort the kill for
  that entry and emit a warning to the user.
- **Orphan accumulation if user never runs cleanup.** Acceptable
  for v1.0 given the explicit opt-in design; revisit in v1.1 with
  PR_SET_PDEATHSIG (Linux) and JobObject (Windows) if telemetry
  shows real-world frequency.

### Explicit non-goals

- **No single-instance enforcement.** Pharos must allow multiple
  concurrent instances (one per MCP client). Any future global
  lock is the wrong shape and rejected here.
- **No auto-reaper at boot.** Earlier draft had one (`C1`).
  Dropped because the safety bar — verifying every signal target
  across three platforms without the user observing the kill
  list — exceeds the keystroke saving over `pharos cleanup`.
- **No vendored Burrito patch (`B2`).** Earlier draft set
  `ERL_CRASH_DUMP` via a patch to `deps/burrito/src/erlang_launcher.zig`.
  Dropped because B1 fixes the root cause (pre-main panics don't
  happen → dump location is moot) and vendoring a dep patch
  creates permanent re-merge cost.
- **No PR_SET_PDEATHSIG NIF in v1.0.** Linux kernel-hint that auto-
  SIGKILLs children on parent death would be a belt-and-suspenders
  layer beneath S3 + C1, but adds NIF + zig shim surface that
  doesn't justify itself given the four layers above. Tracked as a
  v1.1 candidate in `.private/future-improvements.md`.
- **No Windows JobObject in v1.0.** Same argument as above; defer.

## Alternatives considered

- **Wrap every `io:format(standard_error, …)` call site in pharos
  source.** Rejected: covers our code only, leaves OTP/SASL boot
  handlers exposed. B1 (sys.config override) is the correct layer.
- **Always launch pharos with `2>>/dev/null` so fd 2 is always
  open.** Rejected as a user-facing requirement (every MCP client
  config would need to specify it), but B2's wrapper handles it
  for the burrito binary path.
- **Single-instance global lockfile to prevent concurrent pharos
  spawns.** Rejected — directly contradicts MCP-server design where
  each client session owns its own server child.
- **Defer everything to v1.1 and ship v1.0 with known crash-dump
  noise.** Considered briefly; rejected because the failure mode
  triggers on the most ordinary user action (restart Claude Code
  during host shutdown). First-impression cost too high.
