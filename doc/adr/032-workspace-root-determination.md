# 032. Workspace root determination: vendored dependencies and rootless sessions

**Status:** Proposed
**Date:** 2026-08-12

## Context

Root discovery is one function. [`workspace_root.ascend/2`](../../src/pharos/workspace_root.gleam)
walks up from the file's parent directory and stops at the **first**
directory containing **any** configured `root_marker`. First match wins,
no further inspection. `grep -rn node_modules src/ lib/` returns nothing:
pharos has no concept of a vendored or cached dependency directory.

That is fine while every marker it can hit belongs to a project you own.
It stops being fine the moment a dependency ships a marker file of its own.

### The failure, as observed in the field

Reported against pharos + typescript-language-server on an Electron/React
repo — root `tsconfig.json` with `jsx: react-jsx`, sources under `src/`,
React types in `node_modules/@types/react`.

TypeScript's markers are `["tsconfig.json", "jsconfig.json", "package.json"]`.
`node_modules/@types/react/package.json` exists and no `tsconfig.json` sits
beside it. So `goto_definition` on `useState` — the ordinary way an agent
counts uses of a library symbol — lands in `@types/react/index.d.ts`, and
the next call anchored there ascends exactly one level and roots a **second**
tsserver at `node_modules/@types/react`.

The pool keys sessions on `(language, workspace, server)`, so that is a
genuinely separate server process whose project graph is a single `.d.ts`
with no `tsconfig.json` in scope. Downstream:

- `get_diagnostics` returns parse errors that are artifacts of the missing
  `jsx` compiler option (`'>' expected`, `Cannot find name 'div'`), not
  defects in the file.
- `find_references` anchored on the declaration returns 3 locations, all
  inside that one `.d.ts`, and zero project references — a plausible,
  non-empty, wrong answer.
- Nothing in any tool response names the root that answered, so the agent
  cannot tell it has silently changed workspaces.

The reported session ended with a confidently-stated wrong reference count
plus an invented root-cause theory ("the configured project never loaded"),
which was false — first-party queries in the same session worked fine.

One claim in that report does **not** hold up and is recorded here so it is
not designed against: a `find_references` on the *import binding* in the
importing file returned two file-local results, which the report read as
evidence of file-scoping. An import specifier is a file-local declaration in
TypeScript; its references genuinely are the import plus its uses in that
file. That is correct LSP semantics, not a pharos scoping bug.

### Not a TypeScript bug

Every ecosystem that materializes dependencies to disk carries a marker
into them:

| Language | Dependency path satisfying a configured marker |
|---|---|
| typescript / javascript | `node_modules/<pkg>/package.json` |
| rust | `~/.cargo/registry/src/*/<crate>/Cargo.toml` |
| python | `site-packages/<pkg>/pyproject.toml` |
| go | `$GOPATH/pkg/mod/<mod>/go.mod` |
| ruby | `vendor/bundle/**/Gemfile` |

Rust deserves a note because `CargoWorkspacePromotion` looks like it should
save us and does not: promotion walks up from the discovered root looking
for a `Cargo.toml` containing a `[workspace]` heading, finds none above a
registry crate, and returns the registry crate directory unchanged.

### Two topologies, not one

The distinction that shapes the fix is **where the dependency lives relative
to the project root**:

- **In-tree** — `node_modules/`, `.venv/`, `vendor/`. Physically *under* the
  owning project root. An ancestor walk can reach the correct root; it just
  stops too early.
- **Out-of-tree** — `~/.cargo/registry`, `$GOPATH/pkg/mod`. Shared caches
  outside every project root. No ancestor walk from the file can ever reach
  the owning project, because the owning project is not an ancestor.

Any mechanism that only fixes in-tree deps leaves Rust and Go untouched.

### What we must not break

1. **Dependency sources stay navigable.** [ADR-029](029-custom-uri-schemes.md)
   already decided this axis: "on disk" vs "virtual", explicitly *not* "repo"
   vs "deps", and explicitly keeps `file://` covering ecosystem dep caches.
   This ADR must not walk that back. The correction is about **which session
   serves a vendored file**, never about whether that file is reachable — and
   serving it from the owning project's session strictly *improves* what you
   can do there, because the project graph is in scope.

2. **Legitimately nested projects must still root correctly.** Not every
   nested marker is vendor noise. Monorepo `packages/*/package.json`,
   `go.work` members, and a vendored dependency you have deliberately opened
   to patch are all cases where the inner root is the right answer. A blanket
   "deepest marker loses" rule is wrong.

3. **No hard failures.** If a vendor-aware ascent skips the vendor-local
   marker and finds nothing above it, the result is `NoMarkerFound` and the
   tool errors outright. For a file in a global npm install, or a registry
   crate with no enclosing workspace, that is *worse* than today's rootless
   session — an error where there used to be a degraded answer. Any skip rule
   needs a fallback.

4. **Language-neutral.** Per the project invariant, a hardcoded `node_modules`
   check in `ascend` is not acceptable; the rule belongs in the per-language
   config the same way `root_markers` does.

5. **Multi-instance safe.** No global state, per
   [ADR-030](030-process-lifecycle-hardening.md).

### The existing escape hatch, and what it is not

`root_markers` is user-overridable per language and **replaces** the default
list wholesale ([`registry.merge_one`](../../src/pharos/lsp/registry.gleam)).
Setting TypeScript's to `["tsconfig.json", "jsconfig.json"]` drops
`package.json` and makes `@types/react` non-rooting today, with no code
change.

This works, and it is worth documenting in the README as the current
mitigation. It should not be recorded as the intended design: it is a general
config override that happens to help, not a mechanism built for this. It also
costs real coverage — pure-JS projects with only a `package.json` stop rooting
entirely — so it is a per-repo choice, not a new default.

## Decision

**Deferred.** The framing below is settled; the mechanism is not, and this ADR
is Proposed until a fix lands with a dogfood run behind it.

What is decided:

1. **Rooting and reachability are separate concerns.** A vendored file must
   remain fully navigable. The question this ADR answers is only which
   session owns it.
2. **The rule is config-driven and per-language**, alongside `root_markers`.
   No hardcoded ecosystem names in `ascend`.
3. **Degradation, never hard failure.** No change may turn a working degraded
   answer into `NoMarkerFound`.
4. **Attribution ships regardless of which mechanism wins** (Option F below).
   The silent failure is separately worth fixing: every option here has a
   residue of cases it gets wrong, and attribution is what makes that residue
   visible instead of confidently wrong.

The leaning was **A and D composed behind a single resolution function**, with
F already landed as the instrument that makes the other two verifiable. B is
subsumed (D routes by active session more precisely than a prefix match would)
and C stays deferred as an optimization over D rather than an alternative to
it — provenance only exists on a round-trip, so it can never be the sole
mechanism.

**Step 1 has since run and split that pairing** (see *Implementation plan*
below). D's premise holds for rust and go and it proceeds. A's premise fails
for both TypeScript and python; for TypeScript `find_references` A is actively
worse than doing nothing; and both field-report symptoms that motivated it turn
out to reproduce under correct rooting. **A does not ship.** The gate did its
job: it killed the mechanism this ADR was leaning on hardest, and the topology
that prompted the ADR needs no rooting change at all.

### Implementation status

**F has landed for `find_references`** (`session.root_attribution/2`,
`session.attribution_note/3`). **Step 2 has landed** (`resolve_workspace` /
`resolve_workspace_or_dir` in `session.gleam`; all thirteen sites route
through it, `evict_for_uri` included). **Step 3 has
landed in its post-step-1 shape** — the out-of-tree `[D]` branch only:
`is_out_of_tree_cache_path/2` classifies by structural suffix
(`/registry/src/` for rust, `/pkg/mod/` for go — already relocation-robust,
so the step-4 `CARGO_HOME` bug does not exist in the routing list),
`out_of_tree_route_decision/2` picks the sole live workspace or floors to
ascent. In-tree paths and every unprobed language resolve exactly as before.

One decision made at implementation time that the plan below does not spell
out: **a live workspace that is itself dependency-rooted is never a routing
candidate.** Such a root is a floor artifact — an earlier cold-start call
that rooted a session at one registry crate — and routing a *different*
crate's file to it would be strictly worse than the floor. Filtering
artifacts out also means one stale floor session plus one genuine project
session still routes to the project rather than reading as ambiguous.

What remains unimplemented: step 4 (per-language config keys; both fragment
lists are still provisional constants in `session.gleam`) and the validation
dogfood run, which is what moves this ADR past Proposed.

Two notes on what shipping F taught us:

- The anomaly "the anchor file lies outside the answering root" is **vacuous**
  under ascent-based discovery: the root is by construction an ancestor of the
  anchor. The computable signal is instead "the answering root is *itself*
  inside a dependency directory," which is what the implementation tests.
- Attribution is additive, not a response-shape change. MCP already models
  `content` as an array of blocks, so the note is a second text block and the
  payload stays byte-identical in block one. That removes the ADR-023
  compatibility objection this ADR originally raised against F; only the
  ADR-006 context-cost concern survives, which is why the note is emitted
  only on the two anomaly paths and is silent otherwise.

The dependency-path fragment list lives in `session.gleam` as a provisional
constant. It decides only whether to *warn* and never influences which root is
chosen; whichever mechanism this ADR settles on should absorb it into the
per-language config rather than leaving two lists.

**Defect found by step 1 — the note's advice is wrong for library symbols.
FIXED alongside step 3.** It said *"Re-anchor on a first-party declaration
for project-wide results."* That holds for first-party symbols and fails for
the library symbols the note actually fires on: re-anchoring on a first-party
*use* of `useState` still returns only that file's uses plus the declaration
sites, because TypeScript resolves the anchor to the file-local import
binding. The note therefore sent the agent to a second wrong answer, with no
warning attached the second time. The note now says the server may keep
references dependency-scoped regardless of anchoring and recommends a
project-wide text search; the README paragraph carrying the same advice was
corrected in the same commit.

## Options under consideration

**A. Vendor-deprioritized two-pass ascent.** *Selected; step 1 of the
resolution chain.* Add a per-language
`vendor_segments` config key (`["node_modules"]`, `["site-packages", ".venv"]`,
…). First pass ascends ignoring any marker in a directory at or below a vendor
segment; if it finds a root, use it. If it finds nothing, a second pass
re-ascends accepting vendor-local markers, preserving today's behaviour as the
floor. ~20 LOC in `workspace_root`, plus config and tests. Fixes the reported
repro exactly, satisfies constraint 3 by construction, and constraint 2 for
monorepos (`packages/` is not a vendor segment). Does nothing for out-of-tree
deps. Still wrong for the deliberately-patching-a-vendored-dep case, which
then needs an explicit override.

**B. Containing-session preference.** Before discovery, if a live session's
root is a path prefix of the target file, reuse that session. No config, no
markers, handles in-tree deps for every language at once. Two problems: it
does nothing out-of-tree (the registry is under nobody's root), and it is
order-dependent — the same file roots differently depending on whether the
owning session happens to exist yet, which makes behaviour non-reproducible
across sessions and awkward to test.

**C. Request provenance.** Track which session produced each URI in
`goto_definition` / `find_references` results and route follow-up calls back
to it. Most correct answer available: it handles both topologies, needs no
per-language vendor list, and matches what actually happened causally. Costs
threading provenance through every position-anchored tool plus state to hold
the mapping. Deferred as too large to land alongside the others, not rejected.

**D. Reuse the custom-URI-scheme routing for out-of-tree dep paths.**
*Selected pending the step-1 probe; step 2 of the resolution chain, and the
one option whose ambiguity semantics must be softened rather than adopted
wholesale.*
`session.gleam` already implements "route to the sole active session for this
language," with `NoActiveSessionForLanguage` and `AmbiguousSessionForLanguage`
as the failure modes, built for `jdt://` under ADR-029. A `file://` path
classified as an out-of-tree dependency could route the same way. Attractive
because the machinery and its ambiguity semantics already exist and are
tested. Requires a way to classify "this path is a dependency cache," which is
its own per-language config problem.

**E. Do nothing; document the `root_markers` override.** Zero code. Rejected
as a terminal state — it leaves silently-wrong reference counts as the default
behaviour for every ecosystem in the table above, and the failure is invisible
to the agent. Retained as the interim mitigation to document now.

**F. Report the answering root (orthogonal; complements any of A–E).**
*Landed for `find_references`; see Implementation status above.*
Position-anchored tools returned bare LSP passthrough —
[`find_references`](../../src/pharos/tools/find_references.gleam) hands back
`Location[]` with no envelope and, unlike `goto_implementation`, still without
clipping. Naming the workspace root that answered catches the reported
incident at the first query: a root under `node_modules/` is an immediate
tell.

Worth doing first regardless of which mechanism wins, for a reason
independent of its user-facing value: **it is the instrument the other options
are validated with.** A rooting fix cannot be dogfooded without a way to see
which root answered, and the alternative — inferring it from wrong output — is
exactly what produced the false root-cause theory in the field report.

Note what F must **not** do. The field report asked for a "scope searched
(file vs project)" field. LSP exposes no such signal, so pharos would be
guessing, and a confidently-wrong `scope: "project"` is strictly worse than a
bare array — it converts an unknown into a false assurance. Report only facts
pharos actually holds: the root, and whether the anchor is outside it. This is
a tool-surface change and per [ADR-006](006-curated-tools-no-schema.md) and
[ADR-023](023-compact-response-format.md) it needs its own decision on
response shape and opt-in.

## Implementation plan

### Step 1 — probe the assumption before writing code

**Status: RUN, 2026-08-12. Evidence:
[dogfood-adr-032-step1.md](../dogfood-adr-032-step1.md).**

| Language | Topology | Mechanism | Verdict |
|---|---|---|---|
| rust | out-of-tree (`~/.cargo/registry/`) | D | **CLEARS** |
| go | out-of-tree (`$GOPATH/pkg/mod/`) | D | **CLEARS** |
| typescript | in-tree (`node_modules/`) | A | **FAILS** |
| python | in-tree (`.venv/…/site-packages/`) | A | **FAILS** |

The split falls exactly on the topology line, which is also the A/D line.
**D's premise holds for both its languages; A's premise fails for both of
its** — including TypeScript, the language that produced the report.

Two results change the plan rather than merely gating it:

1. **The reported wrong reference count is not a rooting defect.** A session
   rooted at the dependency and a session rooted at the project return *the
   same five locations*. Verified through production pharos, varying only
   `root_markers` (dropping `package.json` simulates A's skip-ascent). What
   the report attributed to a rootless session is TypeScript deliberately
   scoping reference search for `node_modules`-declared symbols — the project
   is fully loaded and the engine is project-wide capable, confirmed by
   controls.

2. **For TypeScript `find_references`, A is a net negative.** Identical
   payload, and F's note goes *silent* because the answering root is no longer
   a dependency path. Warned-and-wrong becomes unwarned-and-wrong.

The premise is therefore **per-method, not per-language**. Routing repairs
project *context* while `references` carries a server-side scope rule routing
does not reach. Step 3 must not assume that fixing the root fixes the answer;
the two are separable, and only the first is in this ADR's power.

3. **The report's other symptom is not a rooting defect either.** Found while
   verifying step 2: the bogus JSX diagnostics reproduce on a *first-party* file
   in a *correctly rooted* project (`App.tsx` errors, `Plain.ts` beside it does
   not). The likely cause is pharos passing `config.id` as the `didOpen`
   `languageId`, so every `.tsx` opens as `typescript` and tsserver never enters
   JSX mode — a `LanguageConfig` shape problem (one `id`, many
   `file_extensions`), not a workspace question. Tracked in the field report;
   it needs its own investigation and is out of scope here.

Consequently: **D proceeds for rust and go. A is unmotivated and does not
ship.** Both symptoms that motivated it reproduce under correct rooting, so
neither is evidence for a rooting change; A needs a symptom that actually
depends on the root before it is worth building. Should it ever be revived,
F's dependency-note trigger must widen beyond "the root is a dependency path"
first, or A will silence the only warning the agent gets.

This narrows the ADR considerably: what remains is D for out-of-tree caches,
plus F's already-shipped attribution. The in-tree topology — the one the field
report was filed about — turns out to need no rooting change at all.

*Execution: Opus, high effort — running the probes is mechanical; the
judgment is reading murky tsserver/pyright behaviour. Escalate to Fable
medium only if a verdict comes back ambiguous.*

Both selected mechanisms rest on a claim nobody has verified: **that the
owning project's LSP will answer a request for a file inside a dependency.**
A presupposes it for in-tree paths — the skip-ascent roots the `node_modules`
`.d.ts` at the project, so the request lands on the project session — and D
presupposes it for out-of-tree caches. It is well-founded for rust-analyzer
and gopls, which index dependency sources into the project's analysis graph,
so the file is already known to the server. It is genuinely uncertain for
tsserver and pyright.

This is a gate, not a formality, and it gates A and D alike. If tsserver
will not answer for a `node_modules` `.d.ts` under the project session, the
shared premise fails for TypeScript — the language that produced the original
report — and what remains there is the fallback floor: today's behaviour,
now at least flagged by F's note.

The probe: spawn a session from a first-party file, then send
`textDocument/references` for the dependency URI to *that* session — through
the normal `didOpen` path, exactly as the resolution chain would — and check
whether project-wide references come back. Run it per language and per
topology: an in-tree path clears A, an out-of-tree cache path clears D. Each
mechanism ships only for the languages that clear it.

### Step 2 — consolidate resolution to one chokepoint (prerequisite)

**Status: LANDED (a3a67ad).**

*Execution: Opus, medium effort — mechanical consolidation across thirteen
sites, but not low: a missed site (`evict_for_uri`, `root_attribution`)
fails silently, not loudly.*

The workspace is currently re-derived in **eleven** places in
[session.gleam](../../src/pharos/tools/session.gleam) as a duplicated
`discover_workspace` + `promote_root` pair, and a **twelfth** independent copy
lives in [diagnostics.gleam](../../src/pharos/tools/diagnostics.gleam)'s
`evict_for_uri`, which calls `workspace_root.discover_from_uri` directly and
hand-inlines its own copy of the promotion case.

That twelfth copy is a correctness trap rather than mere duplication. If
routing changes but `evict_for_uri` keeps plain ascent, eviction computes a
key no session lives under — it evicts nothing, and the retry-after-evict path
silently stops working while still appearing to run. F's `root_attribution`
(one of the eleven) is the same trap in a second costume: its doc comment
*asserts* that re-deriving via plain ascent "yields the same root the request
itself used," which is true today and false the moment the chain lands — the
note would then report a root the routing no longer uses, and attribution of
the wrong root is worse than none. Any routing change must therefore land as
a single chokepoint:

```
resolve_workspace(pool, file_uri, config) -> Result(String, SessionError)
```

Every caller routes through it, `evict_for_uri` included. This step is a pure
refactor with no behavior change; the suite must stay green across it.

### Step 3 — the resolution chain

**Status: LANDED, in the narrowed shape described below.** See
*Implementation status* for what was built and the one added decision
(dependency-rooted workspaces are not routing candidates).

> **Superseded in part by step 1's result.** The chain below is retained as the
> design that was worked out, but the in-tree branch (`[A]`) does not ship: step
> 1 found no symptom that a vendor-skipping ascent actually fixes. What remains
> to build is the out-of-tree branch (`[D]`) plus the untouched default. The
> dispatch-vs-linear-fallback reasoning still applies and is why the out-of-tree
> branch must not be reached by falling through a skip-ascent.

*Execution: Fable, high effort — the design-sensitive core: topology
dispatch, fallback semantics, constraint 2/3 interactions, and tests for
the junk-marker and unrelated-workspace cases.*

The chain dispatches on topology rather than folding both cases into one
linear fallback:

```
resolve_workspace(pool, file_uri, config):
  not a dependency path → ascend                     (today, unchanged)
  in-tree vendor path (vendor_segments):
    1. ascend, skipping vendor-local markers    [A]
    2. ascend                                   floor, never hard-fails
  out-of-tree cache path (cache fragments):
    1. sole Ready workspace for language        [D]
    2. ascend                                   floor, never hard-fails
```

An earlier draft ran A's skip-ascent on every dependency path and let
out-of-tree files fall through it to D. That linear chain has two failure
modes the dispatch avoids. Skip-ascending from a shared cache can never reach
the owning project (*Two topologies* above), but it **can** find junk: a
stray `~/package.json` or `~/go.mod` above `~/.cargo` or `$GOPATH` — common
accidents in a home directory — would win the first pass, capture a root
strictly worse than today's per-dep floor, and shadow D entirely.
Symmetrically, an in-tree file whose skip-ascent finds nothing has no claim
on whichever workspace happens to be warm: routing it via D risks answering
from an unrelated project, where the floor merely reproduces today.

Determinism is preserved wherever a deterministic answer exists: the first
two branches never consult session state. Only the out-of-tree branch reads
pool liveness — the order-dependence that disqualified option B is confined
to the one case where no ascent can succeed, so no deterministic alternative
is being displaced.

Step 3 is what satisfies constraint 3. In particular, **ambiguity must not
import ADR-029's hard error**: multiple live workspaces falls through to the
floor rather than failing. The caller is still told — the floor root is
itself inside a dependency directory, so F's dependency-scoped note fires on
exactly that answer (the multi-workspace note is reserved for
non-dependency roots).

### Step 4 — per-language dependency fragments

*Execution: Opus, medium effort — config plumbing plus README /
`example-pharos.toml` rows; the one nuance (segment vs. suffix matching
semantics) is specified below.*

The fragment list F shipped is global and provisional; step 3's dispatch
replaces it with two per-language keys, because the two topologies need
different matching semantics: `vendor_segments` for in-tree paths (a path
*segment* — markers at or below it are skipped by the A pass) and a
cache-fragment list for out-of-tree paths (a structural *suffix* matched
anywhere in the path — it classifies, and never participates in ascent).
Per-language, for two reasons.

False-positive risk drops, because a fragment need only be distinctive within
its own ecosystem — `/registry/src/` is safe to match when the language is
already known to be Rust.

More importantly, **the shipped list has a latent bug**: `/.cargo/registry/`
hardcodes the `.cargo` directory name and silently stops matching when
`CARGO_HOME` is relocated. The fix is to match the *structural suffix*
(`/registry/src/`) rather than a path anchored at the home directory. That same
property is why `/pkg/mod/` already works regardless of where `GOPATH` points.
Substring matching on the suffix is relocation-robust in a way that
absolute-prefix matching is not, and it makes the classification work
without any environment-variable expansion.

The bug is warning-only today (the list decides whether to emit a note, never
which root is chosen), so it is deliberately left in place until the
per-language split lands rather than being patched globally, which would
broaden false positives for no gain.

### Validation — the dogfood run that moves this ADR past Proposed

*Execution: Fable, medium effort — interpreting real-LSP output against
expectations is judgment-heavy and exactly where the original field report
went wrong; F's attribution note is what makes medium sufficient.*

### What this plan still does not fix

**Cold start.** If the first call in a session is anchored in an out-of-tree
dependency, D has no session to route to and the floor reproduces today's
behaviour. The in-tree branch is purely filesystem-driven and has no
cold-start hole, so the residue is narrow — but it is real and should be
stated rather than discovered. Option C is the only thing that would close
it, and it cannot: a cold URI has no provenance either.

## Consequences

Once a mechanism lands:

- Navigation into an in-tree dependency is served by the owning project's
  session, so `find_references` from a library declaration sees the project
  graph, and diagnostics stop reporting compiler-option artifacts.
- `root_markers` gains a sibling key, so the per-language schema in the README
  and `doc/example-pharos.toml` grows a row.
- Anyone deliberately rooting inside a vendored directory — patching a dep in
  place — needs an explicit override, where today it happens implicitly.
- Out-of-tree dependency caches are served by the owning session only for the
  languages the step-1 probe clears, and only once a session for that language
  exists. Both residues — unprobed languages and cold start — must be stated in
  the README rather than left for a user to discover.
- Every tool's workspace resolution passes through one function, so a future
  change to rooting has one place to land instead of twelve. That is worth more
  than this ADR's specific rule.

Until the chain lands, the `root_markers` override is the documented
mitigation, and F's note is the only signal that anything went wrong — which is
why F shipped first and independently.
