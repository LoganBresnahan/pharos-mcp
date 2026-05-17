# 027. Project-local memory tools for cross-MCP-client knowledge sharing

**Status:** Proposed
**Date:** 2026-05-16

## Context

LLM coding assistants reach for project context every session:
"what's the build command," "what conventions does this codebase
follow," "why did we choose X over Y." Each MCP host (Claude Code,
Cursor, Gemini CLI, ChatGPT, custom agents) ships its own answer to
this problem:

- **Claude Code** has `CLAUDE.md` + a per-project memory directory
  under `~/.claude/projects/.../memory/`. Auto-loaded into context.
  Claude-only.
- **Cursor** has `.cursor/rules` and a separate notepad system.
  Cursor-only.
- **Gemini CLI** has its own conventions file.
- **ChatGPT / custom agents** have no built-in project memory at
  all — every session starts cold.

Each system is locked to its host. A team that uses Claude Code for
some members and Cursor for others maintains two parallel knowledge
bases. A solo dev who runs ad-hoc scripts against pharos from a
custom Python agent has zero shared context with their Claude Code
sessions on the same project.

Pharos's mission since ADR-009 has been "be the LSP bridge for *any*
MCP client." Memory is a natural extension: be the **project-local,
client-agnostic knowledge store** any MCP host can read and write.
A `.pharos/memories/` directory committed to the repo means:

- Every MCP client sees the same content.
- New cloners inherit the project's accumulated knowledge.
- Memory edits go through `git diff` for review.
- `git blame` answers "who saved this and when."

Cavemem (JuliusBrussee/cavemem) takes a different shape — SQLite +
FTS5 + compressed observation log indexed by session boundaries.
That's an **append-only stream**, useful for "what did the agent
do last week" recall. It's complementary but a different problem
than the curated-knowledge case this ADR targets. See "Alternatives
considered" for why cavemem-style storage isn't our v1 choice.

## Decision

Ship four MCP tools (`memory_save`, `memory_get`, `memory_list`,
`memory_prune`) backed by markdown files under `.pharos/memories/`
with YAML frontmatter for metadata. Filesystem storage, no database,
no compression. Hand-rolled strict-shape frontmatter parser.

### 1. Storage layout

**Two layers in v1.** The `user` type is fundamentally per-user
(role, expertise, preferences) and doesn't belong committed to a
project repo. Other types are project-scoped and committed.

```
~/.pharos/memories/                  ← global, per-user, NOT committed
└── user/
    └── role.md

.pharos/memories/                    ← project-local, committed to repo
├── MEMORY.md                        # auto-maintained index
├── project/
│   ├── ingestion-pipeline.md
│   └── auth-rewrite.md
├── feedback/
│   └── no-mocks-in-tests.md
└── reference/
    └── linear-projects.md
```

- `memory_save(type=user, ...)` writes to global layer.
- `memory_save(type=project|feedback|reference, ...)` writes to
  project layer.
- `memory_get(name)` checks project layer first, falls back to
  global. Project-local overrides global on name collision (rare).
- `memory_list()` merges both layers in the result; each entry
  carries its layer so the LLM can filter.
- `memory_prune(name)` operates on whichever layer the name lives
  in (with a `layer` arg to disambiguate collisions).
- One markdown file per memory.
- Type subdirectories enforce the type-aware vocabulary.
- `MEMORY.md` index is per-layer (one in each root).

**Why ship the two-layer split day 1:** without it, user-type memories
either get committed to project repos (leaks personal info into team
repos) or get dropped from v1 entirely (loses Claude Code parity).
Adding the layer later breaks existing files. Worth the ~30 LOC up
front.

### 2. Memory types (four)

Stolen verbatim from Claude Code's auto-memory vocabulary because it
already encodes the discipline we want:

- **`user`** — Who the user is, their role, expertise, preferences.
  Helps tailor explanations.
- **`project`** — Ongoing work, goals, deadlines, motivations behind
  decisions. State-changes faster than user memories.
- **`feedback`** — Corrections or validated approaches. "Don't mock
  the DB in tests" or "yes, single bundled PR was the right call."
  Includes a **Why:** line so future-self can judge edge cases.
- **`reference`** — Pointers to external systems (Linear projects,
  Grafana dashboards, Slack channels).

Each type has a documented "when to save" rule embedded in the
`memory_save` tool description.

### 3. File schema (YAML frontmatter + markdown body)

```
---
name: ingestion-pipeline
type: project
description: Ingestion pipeline rewrite is driven by legal/compliance, not perf
created: 2026-05-16T07:30:00Z
last_accessed: 2026-05-16T07:30:00Z
---
The ingestion pipeline rewrite was scoped by legal/compliance review
(session-token storage didn't meet new requirements). Scope decisions
should favour compliance over ergonomics until that requirement is
explicitly relaxed.

Why: legal/compliance constraint, not tech-debt cleanup.
How to apply: when reviewing PRs that change ingestion code, check
they don't reintroduce the old session-token shape.
```

Five required fields, all simple strings/timestamps. No nested
structures, no flow syntax, no multi-line block scalars.

### 4. Hand-rolled strict-shape parser

Gleam stdlib has no YAML parser. We don't pull `yamerl` (full YAML
1.1, ~5000 LOC, 100-200KB in Burrito) or shoehorn `tomerl` (full
TOML, similar size). Instead a ~50-LOC parser handles our exact
subset:

- Verify line 1 is exactly `---`
- Read lines until next `---`
- Each line splits on first `:` → trimmed key and value
- Validate key ∈ {name, type, description, created, last_accessed}
- Validate type ∈ {user, project, feedback, reference}
- ISO-8601 timestamp validation for created / last_accessed
- Reject ANYTHING else — quoted strings, flow syntax, multi-line,
  comments — with `MemoryShapeError("frontmatter must be plain
  key:value")`

Strictness is the feature. `memory_save` is the canonical writer
(typed arguments → deterministic compliant output), so the only
way to produce non-conforming files is out-of-band hand-edits.
Those fail loudly at read time, easy to fix.

### 5. Tool surface (five)

**`memory_save(type, name, description, content)`**
- Validates type ∈ {user, project, feedback, reference}
- Validates name is kebab-case, ≤ 64 chars
- Validates description is ≤ 200 chars
- Refuses to overwrite an existing entry without `overwrite=true`
- Strips `<private>...</private>` blocks (cavemem-borrowed)
- Updates `MEMORY.md` index entry

**`memory_get(name)`**
- Returns frontmatter fields + body
- Updates `last_accessed` timestamp
- Errors if name doesn't exist (with `near_misses` suggestions)

**`memory_list(type?, query?)`**
- Returns name + type + description triples
- Optional `type` filter
- Optional `query` substring match on name/description
- Sorted by `last_accessed` descending (recent-use bias)

**`memory_prune(name)`**
- Explicit delete. No batch deletes — one-at-a-time discourages
  accidental bulk wipes.
- Removes file + updates `MEMORY.md`.

**`memory_audit(stale_threshold_days?: int=30, include_duplicates?: bool=true)`**
- Walks both layers and reports dumping-ground signals before
  quotas hard-fire. Surfaces:
  - `stale` — entries whose `last_accessed` is older than
    `stale_threshold_days`. Returns `{name, type, layer,
    last_accessed, days_since_access}` sorted by
    `days_since_access` descending.
  - `duplicate_candidates` — pairs whose name-tokens (split on
    `-`) or description-tokens (split on non-alphanumeric) hit
    Jaccard ≥ 0.5. Returns `{a, b, similarity}` with names in
    alphabetic order, sorted by similarity descending.
- `include_duplicates=false` skips the O(N²) dup scan.
- LLM decides keep / merge / prune from the report.

### 6. Anti-dumping discipline

The risk: LLMs over-eager to save. Mitigations layered:

a. **Tool description rules.** `memory_save` description spells out
   "Do save: …, Do not save: code patterns (already in repo), git
   history (use `git log`), debugging solutions (the fix is in the
   commit)." Same shape as Claude Code's auto-memory rules.

b. **Per-type quotas.** Soft cap warns at 80%, hard cap rejects:
   - user: max 50
   - project: max 200
   - feedback: max 100
   - reference: max 100
   Numbers tuned to match what real projects need without trending
   toward dumping ground.

c. **Required description field.** Forces the LLM to write a
   one-line hook *before* the content. Saving generic "notes about
   X" becomes harder than saving specific "X uses fp-ts not Promise
   for async error handling."

d. **`<private>...</private>` stripping.** Lifted from cavemem.
   Anything inside the tag is dropped on save — useful for
   pre-commit redaction.

e. **`last_accessed` decay surface.** Each `memory_get` bumps the
   timestamp. Future `memory_audit` (see "Future ideas") can report
   stale entries.

### 7. Where it sits in the surface

A new `CatMemory` category, added to the `ToolCategory` enum in
`pharos/config`:

```gleam
pub type ToolCategory {
  CatRead
  CatWrite
  CatDefault
  CatDebug
  CatRaw
  CatMemory   // new
}
```

- Memory tools register under `CatMemory`.
- `default` profile resolves to (read ∪ write ∪ CatDefault ∪
  CatMemory) — memory ships in production by default.
- Users opt out via `tools = ["read", "write"]` in `pharos.toml`
  (excludes memory + debug + raw + CatDefault essentials, which is
  probably wrong — see note below).
- More likely opt-out: `tools = ["default"]` minus memory, expressed
  as `tools = ["read", "write", "runtime_set_tool_timeout",
  "runtime_effective_tool_config", "runtime_language_config"]` —
  explicit CatDefault tools without the memory category.
- No cross-process state. The filesystem is the source of truth;
  pharos has no in-memory cache between calls. Concurrent saves
  use `O_EXCL` semantics on file create to avoid races.

**Note on opt-out shape:** today's `tools = ["read", "write"]` drops
all CatDefault essentials including `runtime_set_tool_timeout`, which
the LLM-realistic recovery flow depends on. A future refinement (out
of this ADR's scope): support negation tokens (`tools = ["default",
"-memory"]`) for clean category-minus-one opt-outs.

### 8. Implementation scope (estimated)

- `src/pharos/tools/memory.gleam` — ~250 LOC (incl. two-layer routing)
- `src/pharos/tools/memory_frontmatter.gleam` — ~60 LOC parser
- `src/pharos/mcp/server.gleam` — 4 tool definitions + handlers
- `src/pharos/tools/registry.gleam` — 4 entries in new CatMemory
- `src/pharos/config.gleam` — new `CatMemory` variant + resolver
  update
- Tests: see §9 below
- Dogfood harness: see §10 below

Total: ~400 LOC + tests + harness cells. One feature branch, can
land as 2-3 commits (parser → core tools → harness).

### 9. Test plan

**Frontmatter parser (~12 cases):**

- Valid round-trip (serialize → parse → equal)
- Reject quoted strings (`name: "foo"`)
- Reject multi-line block scalar (`description: |\n  ...`)
- Reject flow syntax (`tags: [a, b]`)
- Reject unknown keys
- Reject invalid type values
- Reject malformed ISO timestamps
- Strip trailing whitespace on keys + values
- First-colon-only split (ISO timestamp values contain `:`)
- Reject missing required field
- Reject when closing `---` missing
- Reject when opening `---` missing

**Tool behaviour (~15 cases):**

- `memory_save` round-trips to `memory_get`
- `memory_save` rejects duplicate name without `overwrite=true`
- `memory_save` rejects non-kebab-case name
- `memory_save` rejects description > 200 chars
- `memory_save` strips `<private>...</private>` blocks
- `memory_save` updates `MEMORY.md` index
- `memory_save` rejects when hard-cap quota hit
- `memory_save` warns in response at 80% quota
- `memory_get` errors with `near_misses` on not-found
- `memory_get` bumps `last_accessed`
- `memory_list()` filters by type
- `memory_list()` filters by query substring (name + description)
- `memory_list()` sorts by `last_accessed` descending
- `memory_prune` removes file + index entry
- `memory_prune` errors on non-existent name

**Two-layer scoping (~6 cases):**

- `memory_save(type=user)` writes to `~/.pharos/memories/user/`
- `memory_save(type=project)` writes to `.pharos/memories/project/`
- `memory_get` checks project layer first
- `memory_get` falls back to global layer
- `memory_list` merges both, marks each with layer
- Name collision between layers: project wins, list shows both
  with layer tags

**Concurrency (~2 cases):**

- Two concurrent `memory_save` with same name: one wins, other gets
  `MemoryConflict` (`O_EXCL` semantics)
- Read-during-write: `memory_get` either sees old or new content,
  never partial

Test fixtures use `PHAROS_MEMORY_ROOT=<tmpdir>` and
`PHAROS_USER_MEMORY_ROOT=<tmpdir>` env vars (see §10) to isolate
test state. Each test sets up + tears down its own temp directory.

### 10. Dogfood harness plan

Memory tools are stateful (filesystem-backed) and project-global
(not per-language). They sit outside `PER_LANG_TOOLS`. Approach:

**Env-var isolation.** Pharos respects `PHAROS_MEMORY_ROOT` and
`PHAROS_USER_MEMORY_ROOT` env vars overriding the default
`.pharos/memories/` and `~/.pharos/memories/`. Dogfood sets both
to fresh `tempfile.mkdtemp()` paths per pass — clean state, no
pollution of the dev's real memories.

**New `MEMORY_TOOLS` cell group** in `bin/dogfood-23lang.py`,
running once per pass (not per language). Ordered chain:

1. `memory_list()` — expect empty list (clean state)
2. `memory_save(type="project", name="pass-{label}", description="probe", content="x")` — expect OK
3. `memory_get("pass-{label}")` — expect content matches
4. `memory_list(type="project")` — expect one entry
5. `memory_save` again with same name — expect MemoryConflict
6. `memory_save(..., overwrite=true)` — expect OK
7. `memory_save(type="user", name="pass-{label}-user", ...)` — expect OK in global layer
8. `memory_list()` — expect both, with layer tags
9. `memory_prune("pass-{label}")` — expect OK
10. `memory_get("pass-{label}")` — expect not_found
11. `memory_prune("pass-{label}-user")` — cleanup

11 cells total, run before the per-language loop so failures
surface fast.

**Verifier rules:**
- Cells 2-4 must PASS sequentially (chained)
- Cell 5 must FAIL with `MemoryConflict` (expected-error rather
  than transport error)
- Cell 7 verifies cross-layer writes
- Cell 10 verifies prune actually deleted

Scoring becomes: total = `(global_tools + per_lang × langs + memory_tools)`.
Pass 25+ adds memory cells; pass 24 baseline (519/616) becomes
`519/(616 + 11)` apples-to-apples or just compares per-category
deltas.

**Quota-cap test deferred from harness.** Hitting per-type caps
needs 100+ saves per cell — too expensive for every pass. Lives
in unit tests instead.

**Failure modes the harness will surface:**
- Tempdir env vars not respected → cells write to dev's real memories
  (visible immediately on first pass)
- Concurrency bugs → cell 5 might not get MemoryConflict if races
- Index file (`MEMORY.md`) drift → cell 4 list won't match what's
  on disk
- Two-layer routing bug → cell 7 might land in wrong dir

## Consequences

**Wins:**

- Cross-client portability. Claude Code, Cursor, Gemini CLI,
  ChatGPT, and any custom MCP agent see the same project memory.
- Git-friendly. Memory edits are reviewable commits. Diffs are
  human-readable. `git blame` works.
- Zero new deps. Hand-rolled parser, filesystem storage.
- Type-aware vocabulary inherited from Claude Code keeps discipline
  high.
- Transparent storage. `cat .pharos/memories/project/foo.md` works.
  Humans can browse without tools.

**Costs:**

- Solo Claude-Code users get a second memory system parallel to
  `CLAUDE.md`. Tool description must make it clear when to prefer
  which. (We expect them to converge once external users start
  bringing non-Claude clients to the table.)
- Strict frontmatter parser is loud about out-of-band hand-edits.
  Users hand-editing in Obsidian must follow the schema. Failure
  is recoverable but visible.
- Quota enforcement means LLMs will occasionally hit caps. Surface
  the prune workflow clearly in error messages.
- File-level concurrency assumes one pharos process per project.
  Multi-instance writes would need locking — out of scope for v1.

## Alternatives considered

### SQLite + FTS5 (cavemem-style)

Real schema, full-text search via BM25, ACID, single-file portable.

Rejected because:
- Loses `git diff`-ability — opaque binary blob.
- Adds C dependency to Burrito bundle (~500KB).
- Schema migrations need plumbing we don't have.
- Doesn't fit the curated-knowledge use case where humans should
  inspect/edit content directly.
- Cavemem's actual value-add is **observation logging** (timeline of
  agent actions) — different problem than project knowledge.

### Mnesia

Native BEAM, distributed-ready, transactional.

Rejected because:
- Designed for OTP-internal state, not user-facing data.
- Lives in `Mnesia.<node>/` directory — worse portability than a
  single file or a directory of `.md`.
- Schema migrations notoriously painful.
- Overkill for project notes.

### DETS

Native BEAM, simpler than Mnesia, single file.

Rejected because:
- 2GB limit (not a real concern, but architecturally arbitrary).
- KV-only — no schema enforcement.
- Opaque binary — same git-diff problem as SQLite.

### Plain markdown without frontmatter

Just `.pharos/memories/<name>.md` with the content.

Rejected because:
- No type discipline — everything becomes a single bucket.
- No `last_accessed` decay signal.
- No structured `description` to surface in `memory_list`.
- Dumping ground risk much higher.

### TOML frontmatter (`+++` fences)

We already have `tomerl` in deps.

Rejected because:
- `---` YAML fences are the markdown-ecosystem standard. `+++`
  TOML is Hugo-only.
- LLM training corpora contain millions of YAML-frontmatter
  examples and far fewer TOML-frontmatter ones.
- Tooling (Obsidian, GitHub markdown rendering, VSCode-Markdown
  preview) handles YAML frontmatter natively, TOML often needs
  plugins.
- `tomerl` is full TOML 1.0 (~3000 LOC) — overkill for 5 fields
  the same way `yamerl` would be.

### Use `CLAUDE.md` directly

Just write to `CLAUDE.md`. Skip the new tool surface.

Rejected because:
- Locks the format to Claude Code's conventions.
- Loses type-aware vocabulary.
- Cross-client portability is the explicit reason for this layer;
  reusing a single-client format defeats it.

## Shipped in v1 (originally listed as future ideas)

### `memory_audit` — shipped

Reports stale memories (`last_accessed` older than N days, default
30) and duplicate candidates (Jaccard ≥ 0.5 on name-tokens or
description-tokens). LLM decides keep / merge / prune. Surfaces
the dumping-ground problem before quota hard-caps fire.

Schema:
`memory_audit(stale_threshold_days?: int=30, include_duplicates?: bool=true)`
→ `{stale: [{name, type, layer, last_accessed, days_since_access}],
duplicate_candidates: [{a, b, similarity}], stale_count,
duplicate_count}`. Sorted deterministically: stale by
`days_since_access` desc; duplicates by similarity desc then
alphabetic.

### Per-user vs per-project scoping — shipped

Two-layer routing baked into v1 storage to avoid a breaking
migration later. `user`-type memories live at
`~/.pharos/memories/user/`, project / feedback / reference at
`.pharos/memories/` under the project root. `memory_get` checks
the project layer first, falls back to user. Both honour
`PHAROS_MEMORY_ROOT` / `PHAROS_USER_MEMORY_ROOT` env overrides for
test/dogfood isolation.

## Future ideas (deferred for v1, kept for the roadmap)

### `memory_repair`

When the strict frontmatter parser rejects a file, surface the file
contents + parser error to the LLM, ask it to emit a corrected
version, write back atomically. Avoids "your file is broken, fix it
yourself" friction.

### Cavemem-style observation log as a separate tool category

Keep this ADR's curated knowledge AND add an observation log
(`memory_log_save(kind, body)`, `memory_log_search(query)`,
`memory_log_timeline(session?)`) backed by SQLite + FTS5. Two
storage backends, two categories — curated knowledge stays
markdown, transient observations go to the log. Borrow the
caveman-grammar compression for log entries to keep storage small.

### Cross-instance sync

If a team runs pharos on a shared dev VM, multi-process writes need
file-locking (`flock` or rename-into-place pattern). Skipped in v1
because we expect one pharos per project per machine. Becomes real
when CI agents start hitting the same `.pharos/memories/`.

### Memory linking

`[[other-memory-name]]` syntax in body, parser extracts links,
`memory_get` returns the link graph alongside content. Encourages
network-of-notes structure (Obsidian-style) without bolting on a
graph database.

### Encryption-at-rest

`.pharos/memories/` with optional age/sops-style encryption for
sensitive notes. Out of scope for v1 — users can `.gitignore`
sensitive paths if needed.

### Quota auto-prune

When a quota is hit, instead of rejecting the save, automatically
prune the least-recently-used memory of that type, surface the
deletion in the response, let the LLM decide whether to restore.
Trades discipline for ergonomics — only worth if quota friction
becomes a real complaint.

## References

- ADR-009 (dogfood via Claude Code) — establishes the "MCP clients
  are first-class" stance this ADR builds on.
- ADR-026 (symbol-layer tools) — same cross-client primitive
  approach applied to LSP operations.
- Claude Code auto-memory specification — vocabulary and "when to
  save" rules borrowed verbatim.
- [JuliusBrussee/cavemem](https://github.com/JuliusBrussee/cavemem)
  — different problem shape (observation log vs curated knowledge),
  worth a follow-up integration as a separate category.
- [Obsidian frontmatter](https://help.obsidian.md/properties) —
  YAML-frontmatter convention we're following.
