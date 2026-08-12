# 031. Orphan reaping via process-group signals; no external setsid wrapper

**Status:** Accepted
**Date:** 2026-08-12

## Context

[ADR-030](030-process-lifecycle-hardening.md) failure mode 4: LSP children
that outlive pharos. Its Layer 3 answer, `pharos cleanup`, reaped orphans
with a bare `kill <lsp_pid>` — which reaches only the LSP process itself.
jdtls and metals both spawn helper processes, and a grandchild that
reparents to init is structurally unreachable from any process-tree walk.
Measured on a real tree before the fix:

```
kill -TERM 261068     grandchild SURVIVED
kill -TERM -261068    grandchild reaped, and its sibling too
```

So the cleanup path needed to signal the LSP's *process group*, and the
open question was whether pharos must arrange for that group to exist —
i.e. wrap every LSP spawn in `setsid` so the child leads a fresh group
that its descendants inherit.

A concrete candidate existed: **bosun**, the Zig spawn-prefix built for
captAInHook, where the host runtime (.NET) cannot reach the fork→exec
window to call `setsid()` itself. Adopting it here was evaluated and
would have **broken spawning outright**:

```
bosun: setsid failed (already a session leader?)   -> exit 125
```

That loud refusal (a deliberate bosun design virtue) surfaced the
underlying fact: **BEAM's `erl_child_setup` already calls `setsid()` on
every port child.** Measured with no wrapper involved:

```
261022  pgid=261022  beam.smp
261037  pgid=261037  erl_child_setup
261068  pgid=261068  bash   <- the child: pid == pgid == sid already
261069  pgid=261068  sleep  <- grandchild inherits the group
```

The capability an external wrapper exists to provide is already present
on the BEAM. The process groups were correct all along; pharos just
wasn't aiming at them.

ADR-030 also deferred `PR_SET_PDEATHSIG` (Linux auto-SIGKILL of children
on parent death) to v1.1 as the belt-and-suspenders answer to orphan
LSPs. That deferral was made before this finding, when orphans looked
reachable only via kernel help or a manual per-pid kill.

## Decision

`pharos cleanup` signals the orphaned LSP's **process group** (`kill
-TERM -<pgid>`), not the bare pid, relying on the group `erl_child_setup`
already created at spawn time. No spawn-time wrapper — bosun or otherwise
— is adopted; there is nothing left for it to do.

The group-vs-pid decision lives in `signal_target/1`
(`src/pharos_instance_track_ffi.erl`), which group-targets only when all
three guards hold, else falls back to the bare pid (never unsafe, only
incomplete):

- `Pgid =:= Pid` — the pid actually *leads* the group. Signalling `-N`
  where N leads nothing hits an unrelated group that merely happens to
  be numbered N.
- `Pgid > 1` — never group 0: `kill -TERM -0` means "my own process
  group", i.e. pharos killing itself and, when it shares a group with
  its MCP host, the host.
- `Pgid =/= OwnPgid` — the same suicide via a different route.

pgid is read with `ps -o pgid=` rather than `/proc` so the path works on
macOS as well as Linux, matching the portability approach already used
by `process_comm/1`.

The `erl_child_setup` setsid behaviour is pinned by a test
(`test/signal_target_test.gleam`: a BEAM-spawned child leads its own
group), so if a future OTP release stops setsid-ing port children, that
surfaces as a test failure rather than as silently leaked processes.

## Consequences

### Easier

- **Grandchild orphans are reachable.** The jdtls/metals helper-process
  class of leak — previously permanent, since a reparented grandchild is
  invisible to tree walks — dies with its group.
- **ADR-030's deferred `PR_SET_PDEATHSIG` item is mostly obsolete.** Its
  motivating scenario (orphans that cleanup cannot reach) is now covered
  by group signalling. What remains uniquely for pdeathsig is the
  SIGKILL/OOM case where *no pharos cleanup code ever runs and the user
  never invokes the CLI* — kernel-level auto-reap needs no surviving
  process. That residual case is narrower than ADR-030 assumed, and is
  further complicated by the child's parent being `erl_child_setup`
  rather than `beam.smp` (the pdeathsig would fire on the wrong parent's
  death). Same reasoning covers the "auto-reaper for orphan LSP
  children" roadmap carry-in: `pharos cleanup` with group signalling is
  the auto-reaper's coverage without its PID-reuse risk.
- **No new native surface.** The v1.0 no-NIF constraint (ADR-030) holds
  with nothing deferred against it; the wrapper-binary alternative is
  rejected rather than postponed.

### Harder

- **Dependence on undocumented-ish OTP behaviour.** `erl_child_setup`
  calling `setsid()` is implementation detail, not contract. The pinning
  test converts that risk from "silent leak" to "visible red test", but
  a future OTP change would still demand a spawn-side fix at that point.
- **Fallback is incomplete by design.** When any guard fails, cleanup
  signals only the bare pid — correct for the safety property, but a
  grandchild behind a non-leader pid survives. Acceptable: the guards
  fail only in states where group signalling would be dangerous.

## Alternatives considered

- **Adopt bosun (external setsid spawn-prefix).** Rejected: redundant —
  the group already exists — and actively breaking, since `setsid()`
  fails for a process that is already a session leader (exit 125).
- **bosun `--pdeathsig --no-setsid` (Linux-only) for the SIGKILL case.**
  Noted, not adopted: narrow residual benefit, Linux-only, and the
  parent seen by the kernel would be `erl_child_setup`, not pharos.
- **`PR_SET_PDEATHSIG` via NIF.** Still ruled out per ADR-030's no-NIF
  constraint; this ADR additionally removes most of its motivation.
- **Walk the process tree and kill descendants individually.** Rejected:
  structurally cannot reach a grandchild that reparented to init, which
  is exactly the observed leak.
