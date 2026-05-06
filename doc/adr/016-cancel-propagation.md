# 016. Cancel propagation: in-flight tracking, best-effort delivery

**Status:** Accepted
**Date:** 2026-05-06

## Context

MCP defines `notifications/cancelled` so a client can withdraw an
in-flight `tools/call` request. LSP defines `$/cancelRequest` for
the same purpose between client and language server. To honor MCP
cancellations end-to-end pharos must

1. correlate the MCP `requestId` to the in-flight LSP request,
2. emit `$/cancelRequest` to the right LSP server,
3. ideally do this WHILE the original request is still
   outstanding (in-flight), so the LSP can short-circuit work the
   LLM no longer needs.

The path from (1) to (2) is straightforward — the MCP request id
is already stamped on every log line as the correlation id, and
`pharos/lsp/proc` already exposes a `cancel/2` helper that emits
the LSP wire message. The hard part is (3): in-flight delivery on
the stdio transport requires architectural changes pharos has
been deferring.

### Why stdio in-flight cancel is hard

`pharos:main` reads stdin one line at a time and dispatches each
`tools/call` synchronously — `handle_line` blocks until the
LSP response arrives. While the dispatcher is blocked, the stdin
reader is blocked, so a `notifications/cancelled` arriving on the
same stream is not even READ until the request it cancels has
already completed.

Even if the cancel were read in time, sending `$/cancelRequest`
to the LSP must go through the Port — and Erlang's
`port_command/2` requires the caller to be the Port's owner.
Pharos's `lsp_proc` actor owns the Port and is BUSY in
`lifecycle.wait_for_response`'s blocking `receive` waiting for
the response to the original request. A cancel arriving at the
actor's mailbox queues behind the active receive and is not
processed until that receive returns.

Three potential fixes:

- **Async dispatch**: every `tools/call` runs on its own spawned
  process; the stdin reader returns immediately. The dispatcher
  process writes the response when ready. ~80 LOC + per-request
  process tracking; needs care around ordering of replies on the
  stdio output (concurrent writes must be line-atomic).
- **Split Port ownership**: introduce a tiny Port-writer process
  that owns the Port for sends; the existing `lsp_proc` keeps
  ownership for receives. Cancel sender writes via the writer.
  Splits one logical resource into two; introduces ordering
  questions between concurrent sends.
- **Process flag interrupt**: trap exits + use
  `:gen_server`-style call interruption. Nonstandard, fragile.

HTTP transport already runs each request on its own mist
connection process, so in-flight cancel works there with just
the in-flight-tracking table — no Port-ownership work needed.

## Decision

Ship the in-flight tracking table and a **best-effort cancel
handler** now. Defer the async dispatch refactor.

**Tracking table.** A public ETS table `pharos_inflight` keyed by
the MCP request id, value `{proc_subject, lsp_request_id}`. Pharos
maintains it as follows:

- `proc.request` (and `proc.request_raw`) read the caller's
  correlation id from the process dictionary (already populated
  by `mcp/server.dispatch`), insert
  `{cid, self_subject, lsp_id}` before sending the LSP request,
  delete the entry after the response (or error).
- `mcp/server` matches `notifications/cancelled` and looks up the
  table by the cancel's `requestId`. On hit, it sends
  `$/cancelRequest` via `proc.cancel/2`. On miss, it logs.

**Best-effort delivery.** Under stdio, a cancel arrives after the
request it cancels has already finished, and the table lookup
misses. Pharos logs the miss and moves on. No harm done — the
work the LLM wanted cancelled is already done. Under HTTP, the
mist connection process for the cancel runs concurrently with the
dispatcher; the table is populated, the lookup hits, and the
cancel reaches the LSP while the request is still in flight.

This is honest: stdio gets correlation + visibility but not
in-flight cancel. HTTP gets the full feature. Pharos's primary
production transport is HTTP (the bridge VS Code extension uses
it), so the most-impactful path is the one fully delivered.

## Consequences

**Easier:**
- The tracking table makes future async-dispatch work mechanical:
  the same insert/delete points carry forward, only the
  blocking-vs-spawning of the dispatcher changes.
- Visibility lands now: every cancel attempt logs the matched or
  missed mcp_id, so dogfood can quantify how often clients
  actually use the feature before we invest in the stdio refactor.
- HTTP transport users get full in-flight cancel today.

**Harder:**
- Two transports with different cancellation semantics is a wart.
  Documented loudly in the tool descriptions and the ADR; future
  async dispatch closes the gap.
- The ETS table is one more piece of mutable state in pharos's
  shared surface. Same shape as `pharos_diagnostics_cache` and
  the log-ring tables; runtime visibility via
  `runtime_ets_tables` covers it.

**Constraints on future work:**
- Async dispatch refactor needs to keep the table's invariants
  intact: inserts before send, deletes on completion AND on
  spawned-process exit. Use `process.monitor` on the dispatcher
  to clean up orphaned entries.
- The table must not grow unbounded under repeated client cancels
  that miss; deletes only fire on dispatcher completion or the
  monitor's DOWN. A periodic sweep removing entries older than
  e.g. 5 minutes is a safety net for runaway-leak scenarios.
  Defer until measurements show need.

## Alternatives considered

- **Wait for the async-dispatch refactor before shipping any
  cancel support.** Rejected: the tracking table provides
  visibility immediately; the refactor blocks on knowing which
  ordering edge cases matter, which we cannot answer without
  observation in dogfood.
- **Skip cancel entirely.** Rejected: every other LSP-bridging
  product the LLM might compare pharos to handles cancel; the
  feature gap is conspicuous and the tracking layer is small.
- **Fake cancel by returning a synthetic "cancelled" result.**
  Rejected: lying about what happened on the wire is exactly the
  kind of bridge surface the LLM should not have to second-guess.
