---
name: orient
description: Take a bearing at the start of a new pharos context window. Read the recent commits and the (gitignored) roadmap to reconstruct what shipped and what's next, follow the commit trail into whichever ADRs it points at, then reconcile that ground truth against remembered state (MEMORY.md, cavemem) and flag any drift. Read-only — it briefs, it does not write memory or change code. Run when opening a fresh session or whenever you've lost the thread of where the project stands.
---

# /orient — take a bearing at session start

A new context window starts blind to *where we are*. This reconstructs it from
the sources that don't auto-load — the commits and the docs they point at — then
checks that what you already remember still matches reality.

**Read-only.** The deliverable is a briefing, not actions. It does **not** edit
code and does **not** write memory — memory files and cavemem own writing; orient
only reads and reconciles them. Assumes cwd = the pharos-mcp repo root.

## The context sources — and which lane is orient's

| Source | Holds | Trust | Loaded |
| --- | --- | --- | --- |
| CLAUDE.md | how-to-work rules + invariants | authoritative, static | auto |
| MEMORY.md + `memory/*.md` | curated durable facts | *as-of-write-time* — can drift | auto |
| **cavemem** (MCP, if connected) | narrative / the *why*, cross-session | *as-of-write-time*, richer | **on-demand** |
| **git + `.private/roadmap.md` + ADRs** | what the code *is* / the plan *says* | authoritative, **current** | **must be read** |

Rules that keep the lanes disjoint:

- **Don't re-summarize CLAUDE.md or MEMORY.md** — they're in context already. Add
  the *delta* (what changed since last session) and the *reconciliation* (does
  memory still match ground truth?).
- **git = what shipped. cavemem = what was discussed/decided.** A commit says
  *what* changed, never *why*. Reach into cavemem only for a *why* the commits
  don't carry.
- **orient never writes memory.**

**The pharos twist: the roadmap is gitignored.** `.private/` is not in version
control, so `git log` and `.private/roadmap.md` can disagree with no history
explaining the gap, and a fresh clone has no roadmap at all. Treat `.private/`
as one operator's local planning notes: authoritative about *intent*, silent
about what actually landed. If `.private/` is absent, say so in the report
rather than inferring a frontier from commits alone.

## 1. What shipped — read the commits

```bash
git log --oneline -12
git status --short
git branch --show-current
```

Read back only until the arc is coherent — usually the last 5–10 commits. You're
answering three things: last known-good state, what landed most recently, and
whether there's uncommitted WIP on the floor.

Note the commit-prefix convention (`fix(scope):`, `chore(deps):`, `ci:`,
`doc:`) — the scope is a fast filter for which subsystem has been moving.

## 2. Where we meant to be — the roadmap

Read `.private/roadmap.md` — the **v0.2.0 — next** section and the
"Smaller items folded into" list under it. Map shipped commits onto items. The
**frontier** = the first item not evidenced by a commit.

Two traps specific to this file:

- Items are *ordered by suggested shipping sequence*, not priority, and the
  ordering rationale ("smallest wins first, hardest last") matters when picking
  the next move.
- The "Smaller items folded into v0.2.0" list is where deferred hardening lives
  (orphan-LSP reaping, `PR_SET_PDEATHSIG`, Windows JobObject). Those are
  carry-ins from [ADR-030](../../../doc/adr/030-process-lifecycle-hardening.md)
  and are the traps waiting on whichever task touches process lifecycle.

Also check `.private/release.md` when the next move is release-shaped — it holds
the staged v1.0 plan and the housekeeping checklist.

## 3. Reconcile ground truth against memory  ← the cavemem step

MEMORY.md is already in your context. For every remembered claim naming a
concrete artifact — a file, symbol, flag, ADR number, or version — **verify it
against what git / roadmap / code show now.** Memories reflect write-time truth;
flag drift explicitly rather than trusting them.

Then, and only then, reach for the *why* the commits don't carry:

```
cavemem search "<topic the commit raised>"   → get_observations(ids)
# or replay the last session:
cavemem list_sessions → timeline(session_id) → get_observations(ids)
```

Query cavemem against a **specific question the commits raised** — never dump it.

## 4. Follow the trail into docs (on demand)

Commit messages and roadmap items cite ADRs by number. Read the *specific*
referenced doc **only when the next move touches it**. The map:

- **`doc/adr/README.md`** — the index. Start here to resolve a number to a title
  and status; note that the "Anticipated future ADRs" table at the bottom reuses
  numbers already taken by accepted ADRs, so trust the top table for what exists.
- **`doc/architecture.md`** — the operational map (process tree, request
  lifecycle, timeout map, sync/async boundaries). Read before anything that
  spawns, blocks, or times out.
- **`doc/dogfood-*.md`, `doc/m*-test-plan.md`** — dated field reports. Useful for
  "has this been observed in the wild?", not for current state.

Statuses matter: an ADR marked **Proposed** (e.g. 028, the editor bridge) is a
design not yet built — don't report it as shipped.

## 5. The bearing (report)

```
ORIENT — pharos @ <branch> <sha>
  shipped     <recent arc in one line>  · last good: <commit>
  wip         <uncommitted files, or "clean">
  roadmap     frontier → "<item title>"   (.private present? yes/no)
  drift       <remembered-vs-actual mismatch, or "none">
  next move   <the obvious task> — read <the one doc> first
```

Keep it to that shape. The point is a fast "you are here" that lets work resume
in one turn — not a re-run of the project's whole history.
