# 037. Reap each LSP's process group on every stop; no die-with-parent wrapper

**Status:** Accepted
**Date:** 2026-10-19
**Amends:** [ADR-031](031-process-group-signalling-no-setsid-wrapper.md) (group signalling, until now only in
`pharos --cleanup`), [ADR-030](030-process-lifecycle-hardening.md) (its deferred
`PR_SET_PDEATHSIG` item is now rejected)

## Context

0.2.0 put every session's LSPs in one long-lived daemon (ADR-034), so how they end when the daemon
does matters more than before. bosun, now a Rust crate, offered a die-with-parent spawn prefix
(`PR_SET_PDEATHSIG`) and was proposed for pharos. Before building anything, a real 0.2.1 daemon
was measured with real LSPs on fixtures: rust-analyzer twice (a proc-macro workspace, so
proc-macro-srv runs, and a crate whose `build.rs` sleeps, so the startup `cargo check` is in
flight), pyright, gopls, typescript-language-server with tsserver, and jdtls. The daemon was
SIGKILLed, stopped with `pharos daemon stop`, or had its `erl_child_setup` SIGKILLed. Survivors
were checked 5 s later, by pid and start time.

| OS | SIGKILL beam.smp | `pharos daemon stop` | SIGKILL erl_child_setup |
|---|---|---|---|
| WSL2, under `systemd-run --user --scope` | cargo (+ jdtls) | cargo (+ jdtls) | cargo, jdtls |
| WSL2, `PHAROS_DAEMON_SYSTEMD=0` | cargo, jdtls | cargo, jdtls | cargo, jdtls |
| ubuntu-24.04 runner | cargo, jdtls | cargo | cargo |
| macos-14 runner | cargo, jdtls | cargo | cargo |

"cargo" is rust-analyzer's in-flight `cargo check` and the build script it runs; "jdtls" is
jdtls's `java`, the LSP itself. Everything else died within 5 s every time, on every OS: every
other direct LSP (they exit on stdin EOF), proc-macro-srv, gopls's child, tsserver.

What the measurement showed:

- **jdtls is slow, not leaked.** It was gone 5–30 s after both a SIGKILL and an orderly stop.
- **cargo is the leak.** It was still running 120 s after both kinds of stop. It lives as long as
  the step it is on (a long build script or a big `rustc`), then dies at its next write to the
  closed pipe. It is in rust-analyzer's **process group**: erl_child_setup setsid()s every port
  child (ADR-031), and descendants keep that group.
- **An orderly stop leaks it too.** pharos closes an LSP's port and nothing else, and nothing
  signals the group the LSP leaves behind. ADR-031's group signalling ran only in the manual
  `pharos --cleanup`. That command also skipped an LSP whose leader had already exited, which is
  exactly this case.
- **Killing `erl_child_setup` takes the VM down,** so that case is the same as a SIGKILL.
- **The systemd scope changes nothing about survivors.** They stay in its cgroup, and the scope
  lingers until they exit.
- **pharos sent `"processId": null`** in every `initialize`. That opts each server out of the LSP
  spec's own way to notice a dead client, which jdtls and the vscode-languageserver servers
  (pyright, typescript-language-server, …) implement.
- **Signal state an LSP starts with** (from a probe LSP, Linux): SigBlk 0; SigIgn 0x1080 (SIGPIPE
  and SIGFPE).

## Decision

No native code, and no bosun.

1. **Every LSP stop reaps the LSP's process group.** `register_lsp/4` records the LSP's start time
   (`ps -o lstart`) and starts one reaper process. The reaper monitors the lsp_proc actor that
   spawned the LSP; `client.close` also wakes it. When the actor goes, for any reason (close,
   eviction, idle stop, session end, `daemon stop`, a crash), the reaper:
   - waits up to 3 s for the group to empty by itself (most LSPs exit on EOF in milliseconds);
   - TERMs what is left and waits 2 s;
   - KILLs what is still left;
   - removes the tracking file.

   Application stop runs the same pass synchronously over whatever is still recorded, with 1 s and
   1 s, before the instance directory goes and the VM halts. This covers `daemon stop` and the end
   of a direct-mode session.
2. **Pid reuse is ruled out, not hoped against.** The kernel never reuses a number while any
   process still uses it as a group id. So a live process under the LSP's pid that didn't start at
   the recorded time means the old group is empty, and nothing is signalled. While the leader is
   ours, the whole group is signalled, behind ADR-031's `signal_target` guards. Once the leader
   has exited, the remaining members are signalled one by one. A live leader with no recorded
   start time is never signalled.
3. **A daemon or server that starts reaps what dead ones left.** Each starting process reaps, in the
   background, the instance directories of pharos processes that are no longer alive, by the same
   rules. This covers the hard-crash case (SIGKILL, OOM, a frozen machine) at the next session
   rather than instantly. Records written before this change carry no start time: they are
   deleted and nothing is signalled, because they can be months old, with their numbers reused
   since. `pharos --cleanup` uses the same code.
4. **`initialize` carries the VM's OS pid as `processId`.** Servers that watch their client now
   exit by themselves when pharos dies without closing their pipes. A dogfood pass across the 23
   bundled languages compared it with 0.2.1's `null`.

## Consequences

- The measured leak is gone on the orderly path, everywhere. The integration suite pins it with
  a stub LSP that leaves a long-lived grandchild in its group. The grandchild must be gone after
  `daemon stop`, after an idle stop, and after a SIGKILLed daemon is followed by the next daemon's
  start. Unit tests pin the reaping rules against real process groups: leader gone, a live group,
  a group that empties by itself, a reused pid, an unverifiable leader.
- jdtls's 5–30 s exit becomes at most the reap grace plus TERM.
- `daemon stop` and a direct-mode exit can take up to about 2 s longer, only when an LSP group
  doesn't empty by itself.
- After a hard crash, leftovers live until the next daemon or server starts (the shim starts one
  on the next session). In the measurements that was cargo, which dies by itself at its next write
  anyway.
- Reaping shells out to `ps`, polling every 100 ms while a group is non-empty: cheap, portable
  (Linux and macOS), and only during a stop.
- The reaping timings join the timeout map in [architecture.md](../architecture.md).

## Alternatives considered

- **bosun as a spawn prefix: `pharos exec-child --pdeathsig KILL -- <lsp>`.** Rejected: it
  fixes nothing that was measured.
  - Direct LSPs already die on EOF, and the death of their kernel parent, erl_child_setup, is the
    same event as their EOF.
  - The leak is grandchildren, and `PR_SET_PDEATHSIG` is cleared in a fork's child, so cargo
    would survive exactly as now.
  - It would add native code to every spawn path, and a Rust std runtime ahead of every LSP:
    std ignores SIGPIPE before main, which happens to match the 0x1080 an LSP gets today, but
    that's a coincidence to maintain. Linux only.
- **A sentinel: one small process per daemon** watches the daemon pid (pidfd on Linux, kqueue on
  macOS) and kills the recorded groups the moment it dies. Deferred. Its only gain over decision 3
  is reaping immediately rather than at the next start, and only after a hard crash, which is rare.
  If that ever matters, there is a Linux option with no native code first: start the daemon as a
  transient systemd **user service** (`KillMode=control-group`) instead of the current scope, so
  systemd kills the whole cgroup, grandchildren included, when beam dies. That covers systemd
  hosts only.
- **Rely on `processId` alone.** Not every server watches it (rust-analyzer doesn't, and its
  `cargo check` was the leak). Kept, in addition to reaping.
