# 024. LSP readiness gate via spawn-time probe, with timeout-layer consolidation

**Status:** Accepted
**Date:** 2026-05-11
**Accepted:** 2026-05-14 (validated by M14 cross-pass dogfood; see
`doc/dogfood-23lang-summary.md`)

## Context

The M14 Pass 1 dogfood (real-fixture 23-lang matrix) revealed a
cascade pathology: 16 of 23 languages short-circuited as
"LSP unresponsive" after 3 consecutive harness wall-clock timeouts.
In isolation each LSP responds in ~1-2s; in the full pass the same
LSP times out for minutes. Two findings:

1. **Pool actor serialization (fixed in M14).** The pool actor
   held its mailbox for 30-90s during `spawn_proc` inside
   `handle_get`. 23 cold-start `pool.get` calls queued behind one
   mailbox — the last caller didn't see a Proc for ~17 min. Fix
   landed: `process.spawn_unlinked` worker per cache-miss key,
   `SpawnCompleted` message fans out to a waitlist. Pool actor's
   `handle_get` now returns immediately. Architecturally correct;
   does not by itself unblock the M14 matrix.

2. **First-call-on-cold-LSP timeout (the unfixed half).** After
   the pool refactor, the FIRST call to a slow LSP still pays the
   full cold-start cost (init + indexing) on the caller's
   wall-clock. Pharos exposes a `Proc` from the pool as soon as
   the initialize handshake + optional `$/progress` drain
   complete — but for many LSPs that's not actually "ready to
   answer a real query." The LSP returns `null` for the first
   hover, or `-32801 content modified` mid-call, or sits silent
   while still indexing. The harness's 35s wall-clock fires
   before the LSP answers anything. The harness retries, the
   wall-clock fires again, and the broken-LSP short-circuit
   heuristic kicks in after 3 strikes.

The current readiness story is half-built:

- Some servers carry a `readiness_token: Option(String)` —
  rust-analyzer (`"rustAnalyzer/Indexing"`), gopls (`"setup"`),
  gleam-lsp (`"Indexing"`). Pool's spawner waits for that
  `$/progress` end event before releasing the Proc. Works for
  these three.
- Most servers don't emit a standard progress token (pyright,
  marksman, terraform-ls, vscode-json-language-server, etc.).
  For them, pool's spawner returns the Proc the instant
  initialize completes — even though the LSP may not be index-
  ready for a minute or more.
- Even for servers WITH a token, the `$/progress` end signal
  doesn't always mean "able to answer query X." gopls's
  `"setup"` token ends well before its module loader has walked
  the workspace; the first `workspace/symbol` still races.

ADR-016 introduced `request_with_content_modified_retry` to
paper over the rust-analyzer-specific `-32801` race. It works
for rust-analyzer but does not generalize.

**The probe-based answer.** Instead of trusting indirect
signals (initialize done, optional progress drain), the pool's
spawner fires a real query against the LSP and waits for a
non-error / non-null response. Only then does the pool mark the
Proc cached and release `pool.get` waiters. The probe is a
direct test of "can this LSP answer a question?" — server-agnostic
and stronger than the existing proxy signals.

**Adjacent: the timeout layer stack has accreted.** Six wall-
clock budgets currently bound spawn-time work
([doc/architecture.md](../architecture.md) timeout map rows
#6-#10):

- `initialize_timeout_ms` (handshake reply)
- `readiness_timeout_ms` (`$/progress` drain only when token set)
- `proc.wait_for_ready` outer `actor.call` = `readiness +
  5_000` slack
- `post_didopen_drained` ETS first-claim-wins barrier (35s
  per-claim TTL)
- `pool.get` outer `actor.call` = `initialize + 30_000` slack
- `request_with_content_modified_retry` mid-call rescue

This stack made sense as it grew but obscures the real budget
"how long am I willing to wait for this LSP to become useful?"
A probe phase makes some of these redundant.

## Decision

**Add an active readiness probe.** Pool's spawner worker runs a
real LSP query after `initialize` + drain, retries with backoff
until non-error / non-null response, and only then posts
`SpawnCompleted(key, Ok(proc))`. Block-by-default: callers wait
on the spawner via their existing `pool.get` actor.call.

**Track per-LSP state in the pool.** Add `LspState`:

```
Spawning → Probing → Ready → Dead          (success path)
   │           │
   └───────────┴──→ Failed                  (timeout / probe-budget-exhausted)
```

`Dead` is the existing post-mortem state (ProcDown handler
evicts the cache entry). `Failed` is the new pre-Ready terminal
state when init or probe budgets exhaust.

**Per-server probe configuration.** Add `warmup_probe` to
`ServerConfig`:

```gleam
pub type WarmupProbe {
  /// Default — `workspace/symbol` with empty query. Forces the
  /// LSP to walk its symbol index at least once. Works across
  /// rust-analyzer, gopls, pyright, marksman, terraform-ls,
  /// clojure-lsp, metals, jdtls, HLS, PLS, ELP, lua-LS,
  /// vscode-*-language-server, ruby-lsp.
  ProbeWorkspaceSymbol(query: String)
  /// `textDocument/documentSymbol` on a known fixture path.
  /// For LSPs where workspace/symbol is unreliable.
  ProbeDocumentSymbol(uri_relative_to_workspace: String)
  /// Opt-out. The LSP is considered Ready as soon as the
  /// readiness drain completes (legacy behavior). Reserved for
  /// servers where no useful probe exists.
  ProbeNone
}
```

Defaults to `ProbeWorkspaceSymbol("")` for every server. Per-
language overrides land in `languages.gleam` as needed.

**Probe loop:** exponential backoff `[1s, 2s, 5s, 10s, 10s, ...]`
capped at total `ready_timeout_ms`. On first non-error / non-
null result → transition Ready, post SpawnCompleted. On budget
exhausted → Failed, post SpawnCompleted with error.

**Timeout-layer consolidation.** Replace today's overlapping
budgets:

- **Keep** `initialize_timeout_ms` (LSP `initialize` reply).
- **Repurpose** `readiness_timeout_ms` → **`ready_timeout_ms`**:
  total budget for `$/progress` drain + probe loop combined.
  Default 60s; tunable per-server.
- **Remove** `post_didopen_drained` ETS first-claim-wins barrier
  and the 35s `proc.wait_for_ready` slack. Probe-before-Ready
  guarantees the LSP has answered ≥1 query before any `didOpen`
  fires; the race the barrier guarded against is gone.
- **Update** `pool.get`'s outer `actor.call` envelope from
  `initialize_timeout_ms + 30_000` to
  `initialize_timeout_ms + ready_timeout_ms + 5_000` — the slack
  shrinks because the probe budget is now explicit.
- **Keep** `request_with_content_modified_retry`. Probe at spawn
  doesn't cover post-spawn re-indexing (rust-analyzer's `-32801`
  on mid-call edits).

Net: spawn-time budgets drop from six to **two** (`initialize`,
`ready`) plus per-call `timeout_ms`. Architecture map row count
falls from 15 to 11.

**Two-tier typed timeout error.** Split the current
`"tool timeout: LSP did not respond in time"` into:

- **`tool timeout: LSP still initializing (Ns elapsed)`** —
  fired when wall-clock expired while LSP was in `Spawning` or
  `Probing`. Hint: "first-time cost; pass a larger timeout_ms or
  retry."
- **`tool timeout: LSP did not respond in time`** — fired when
  LSP was `Ready` but the specific call did not complete in
  budget. Hint: "LSP is responsive but this query exceeded its
  budget; pass a larger timeout_ms or narrow the query."

Distinct LLM responses: the first is "wait longer / system is
warming," the second is "specific query is heavy." Aligns with
ADR-021's "different error means different recovery action."

**Operator-facing observability.** New MCP debug tool
`runtime_lsp_state` returns `[{lang, ws, srv, state,
spawned_at_ms, probe_attempts, last_probe_ms, last_error?}, ...]`
for every cache entry and every in-flight spawn. Category:
`debug`. Cheap (dict read); useful for dogfood + ops.

## Consequences

**Easier:**

- LSP "ready" becomes a verified state, not a hopeful guess.
  Whatever signals each LSP emits (progress token / no token /
  custom messages), the probe is the universal arbiter.
- Per-call timeouts now bound only post-Ready work. Cold-start
  cost moves into `ready_timeout_ms` where it belongs and is
  visible to operators.
- Operator + LLM can distinguish "LSP still warming" from "LSP
  Ready but query is slow." Different recoveries land naturally.
- Three obsolete timeout layers retire
  (`readiness_timeout_ms` + drain slack as separate concepts;
  `post_didopen_drained` claim barrier; the 30s magic in
  `pool.get`). Architecture map is smaller and more honest.
- `runtime_lsp_state` makes the M14 dogfood (and future
  investigations) far more debuggable. Operator can see at a
  glance which LSPs are still Probing during a slow pass.

**Harder:**

- First tool call to a freshly-spawned LSP blocks longer than
  before. Pre-ADR: pool released Proc after init + optional
  drain (e.g., 5s for rust-analyzer). Post-ADR: pool releases
  Proc after init + drain + probe success (could be 30-60s for
  heavy LSPs). Tradeoff: hides cold-start cost in `pool.get`
  rather than surfacing it as a null/error tool response.
- Per-server `warmup_probe` is editorial. Most servers work
  with the default `workspace/symbol ""` but the bookkeeping
  cost grows.
- LSPs that legitimately can't answer `workspace/symbol ""`
  (some structural LSPs?) need `ProbeDocumentSymbol` or
  `ProbeNone`. Discovered empirically; needs per-server
  validation.
- `pool.get`'s outer `actor.call` envelope grows. Callers
  feeling the envelope (the harness's `bin/dogfood-23lang.py`)
  may need to bump their own wall-clock — the harness already
  uses `timeout_ms / 1000 + 45` slack which should absorb the
  shift, but worth verifying after the change lands.

**Live with:**

- Probe = one extra LSP request per spawn. Cheap by design
  (`workspace/symbol ""` is one of the fastest LSP methods),
  but it's wall-clock work that wasn't there before. Net wall-
  clock cost is roughly neutral because the probe absorbs
  cold-start cost that was previously being paid in the first
  user-facing tool call.
- LLM-facing tool surface unchanged. The probe is internal; the
  LLM never sees it as a separate call. Just sees "tool took N
  seconds" or "tool timeout: ..." with the existing recipe.
- `runtime_lsp_state` is opt-in (debug category). LLMs running
  under the `default` profile don't see it. Operators and
  agentic clients that opt in to `debug` can observe.

## Alternatives considered

- **Reject-fast with retry hint** (the option-B from
  conversation log). Pool fails the call with "LSP not ready,
  retry in Ns" and the LLM decides. Rejected: LLMs don't poll
  mid-call; this just spreads cold-start cost across N retry
  loops with transcript bloat. Existing typed-timeout +
  `runtime_set_tool_timeout` recipe is the working pattern.
- **Periodic background probe** keeping a heartbeat per LSP.
  Rejected for first cut: solves a problem we haven't seen
  (LSP went silent mid-session) and adds traffic for marginal
  benefit. Re-evaluate if real users hit that pathology.
- **Keep `post_didopen_drained` claim barrier.** Considered
  keeping it as defense-in-depth. Rejected because probe-
  before-Ready guarantees the LSP has answered ≥1 query before
  any `didOpen` fires; the race the barrier guarded against is
  structurally impossible after this ADR. Vestigial code is
  worse than no code.
- **Split `ready_timeout_ms` into `drain_timeout_ms` +
  `probe_timeout_ms`.** Considered for fine-grained operator
  control. Rejected for default: one knob is better than two
  unless operators ask. Add the split later if real tuning
  needs emerge.
- **Configurable probe success criteria** (e.g., "non-null
  response" vs "non-empty array" vs "specific symbol present").
  Rejected for first cut: empty-result-but-no-error is
  ambiguous (legitimately empty workspace vs LSP still
  indexing). Default to non-error; revisit if false positives
  appear.
