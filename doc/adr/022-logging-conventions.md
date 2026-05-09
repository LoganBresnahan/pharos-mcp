# 022. Logging conventions: structured fields canonical, file rotation, ring target-prefix filter

**Status:** Accepted
**Date:** 2026-05-09

## Context

Pharos's logging facade (`pharos/log`) has evolved organically and
ships with two coexisting call shapes plus three rough edges that
are starting to bite as ADR 021's timeout matrix and `runtime_*`
introspection tools push more programmatic consumers onto the log
output.

**The two shapes:**

```gleam
// String-jammed (the majority of existing call sites)
log.info_at("pharos/lsp/proc", "request id=42 took=120ms")

// Structured fields
log.at_with_fields("pharos/lsp/proc", Info, "request done",
                   [#("id", "42"), #("took_ms", "120")])
```

Both render the same human-readable line because the writer
formats `[#("k", "v")]` as ` k="v"` after the message. Functionally
identical to a grep-only consumer. Different to a programmatic
consumer (parsing rendered text vs reading structured pairs).

**Three rough edges:**

1. **No file rotation.** When `[log] file = "..."` is set, the file
   appends forever. Long-running pharos sessions produce multi-GB
   logs nobody can grep.
2. **Ring buffer query is substring-only.** `ring.tail(n, substring)`
   filters by message text. To grab "all entries from a target
   subtree" (e.g., for the new `runtime_effective_tool_config`
   tool from ADR 021 to find autotune events), substring is brittle
   ("info" matches the level AND any word containing it). A
   target-prefix filter is more robust.
3. **Field shape is mixed.** ~80% of call sites string-jam values
   into the message; ~20% use `at_with_fields`. Programmatic
   consumers either handle both or dictate one. Today every
   consumer is a human reading the rendered line, so the
   inconsistency hasn't bit. ADR 021's autotune events and the
   new introspection tools are the first programmatic consumers.

Two further gaps were considered and deferred: runtime-override
persistence (would require TOML round-trip; same blast-radius
concern as ADR 021's autotune persistence), and JSON output mode
(explicit non-goal per `entry.gleam`'s top doc — "clip-then-grep
beats jq at this scale"; revisit if pharos ever ships into a fleet
deployment with log-aggregation needs).

## Decision

**Pick `at_with_fields` as the canonical shape for new logging.**
The string-jammed `log.info_at` / `log.warn_at` / `log.debug_at`
APIs stay because rewriting ~33 existing call sites would be
churn for no behavior change. New code uses
`at_with_fields(target, level, message, fields)` (or the
ergonomic alias `fields_at(target, level, message, fields)` —
same arity, conventional ordering). Existing call sites migrate
opportunistically when next touched.

The convention is explicit: any value that a programmatic
consumer might want to extract goes in `fields`. Free-form prose
goes in `message`. Bad: `"request id=42 finished in 120ms"`.
Good: `message = "request finished"`,
`fields = [#("id", "42"), #("duration_ms", "120")]`.

**Add file rotation.** `[log] file_max_bytes` (default 10 MB,
configurable) caps the active file's size. When the cap is hit,
pharos renames `pharos.log` → `pharos.log.1` (and so on, dropping
the oldest), reopens a fresh `pharos.log`, and continues. Rotation
count is configurable via `[log] file_keep_rotated` (default 3).
Rotation is best-effort — a failed rename logs at WARN to stderr
and keeps appending to the current file.

**Add `ring.tail_by_target(n, target_prefix)` helper.** Filters the
ring buffer by exact target prefix (matching the same
prefix-semantics as `pharos/log/filter`). Sits alongside the
existing `ring.tail(n, substring)`; both are exposed via the
public `pharos/log` module. Used by `runtime_log_tail` (new
optional `target_prefix` argument) and by
`runtime_effective_tool_config` (ADR 021) to find autotune events
under target `pharos/tool_config/autotune`.

**Skip runtime-override persistence and JSON output for v0.1.0.**
Both are real but not pulling their weight today:
runtime-override persistence would need a TOML write-back path
identical in shape to ADR 021's deferred autotune persistence;
JSON output has no real consumer in pharos's current
local-subprocess deployment.

## Consequences

**Easier:**

- Programmatic consumers (the new `runtime_effective_tool_config`
  tool, future log-aggregator integrations) can pull values out
  of structured fields without parsing rendered text.
- Long-running file-sink users no longer accumulate multi-GB logs.
- Tooling that wants "all entries from module X" (digest tools,
  debugging an LSP-specific issue) gets a clean prefix filter.

**Harder:**

- Two log call shapes coexist for the foreseeable future. Style
  guide must spell out when to pick each (rule: structured for
  any value a parser might want; string for prose).
- Rotation introduces a small race: a writer in the middle of
  emitting a line during rename could land on the rotated file.
  Acceptable since every emitted line is a complete write
  (Erlang's `file:write/2` is atomic for line-sized payloads).

**Live with:**

- Existing string-jammed call sites stay until a maintainer
  touches them. The codebase mixes both shapes during the
  migration tail.
- File-sink users on Windows pay a small cost: rename-during-write
  semantics differ from POSIX. The simple approach (close → rename
  → reopen) is portable but has a sub-millisecond gap where new
  log lines could be dropped. Documented; bug-report-driven if
  it bites.

## Alternatives considered

- **Bulk-migrate all existing call sites to `at_with_fields`.**
  Churn for no behavior change; rejected. Migration happens
  organically.
- **Substring-filter only on ring.** Already exists; the rough
  edge is brittleness for target-based queries. Target-prefix is
  additive, not replacing substring.
- **JSON output mode behind a flag.** Real ask but no real
  consumer today; defer to a fleet-deployment future where it has
  a payoff.
- **Logrotate (external)** — works on Unix but pharos ships as a
  burrito self-extracting binary that may not have logrotate
  configured by the user. In-process rotation removes a deployment
  dependency.
