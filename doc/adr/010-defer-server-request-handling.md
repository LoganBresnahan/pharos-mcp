# 010. Defer bidirectional LSP server-request handling until pre-Tier-2

**Status:** Accepted
**Date:** 2026-05-03

## Context

The LSP wire protocol is fully bidirectional. Beyond responding to client requests, an LSP server may at any moment send the client its own JSON-RPC requests (expecting a response) and notifications (fire-and-forget). The MCP-side bridge must handle both. The current `lifecycle.request/5` only correlates client→server request/response by id and treats every other inbound message as a notification to be drained or ignored — adequate for the read-only Tier 1 surface, inadequate for anything beyond.

Two real consequences surfaced during M3 + M4 dogfooding:

- **typescript-language-server does not push diagnostics** until the client sends a `workspace/didChangeConfiguration` notification with TS-server-flavored settings after `initialized`. The server *also* pulls `workspace/configuration` from the client during initialize when configured to do so; without a handler, the request times out and tsserver enters a degraded state. As a result `get_diagnostics` returns `NoDiagnosticsObserved` for every `.ts` file. `hover`, `goto_definition`, `find_references`, `document_symbols`, `workspace_symbols` are unaffected — they are pure client→server requests with no server-side dispatch needed.

- **Tier 2 write tools cannot ship without server-request handling.** `rename_preview`, `format_document`, and `code_actions` mostly return `WorkspaceEdit` to the LLM via response payload, which works under the current model. But several language servers (notably typescript-language-server and pyright) emit `workspace/applyEdit` *requests* mid-response when computing fix-its, and rust-analyzer issues `client/registerCapability` and `window/workDoneProgress/create` requests during long-running operations. Ignoring them either stalls the operation or causes the server to abort.

Three options were considered.

**Option A — Add `workspace/didChangeConfiguration` push only.** ~1 hour. Add a `workspace_configuration: Option(Json)` field to `LanguageConfig`; after `initialized`, send a `workspace/didChangeConfiguration` notification with that payload. Configures tsserver's settings, unblocks tsserver diagnostics, leaves the server-pull case (`workspace/configuration`) and Tier 2 server-requests entirely unhandled. A patch, not an architecture.

**Option B — Full bidirectional dispatch now.** ~half-day. Rework `lifecycle.gleam`'s receive loop into a classifier that routes inbound messages by shape (response with id → resolve pending; notification → drain channel; request with id → handler registry → reply). Define a default handler set for the common server-pull surface: `workspace/configuration`, `client/registerCapability`, `window/showMessageRequest`, `window/workDoneProgress/create`, `workspace/applyEdit`. Each handler returns a typed reply. Tools register additional handlers if needed (Tier 2's `rename_preview` will want a real `workspace/applyEdit` policy).

**Option C — Defer both.** Document the gap; ship M5 (HTTP transport), M6 (Burrito + npm), M7 (extension bridge) on the existing dispatch model since none of those milestones requires server-request handling; design and implement Option B as a prerequisite stage of M8 (Tier 2) when the actual handler requirements are concrete.

The forces:

- **Pre-release status.** No external users yet. There is no time pressure to fix tsserver diagnostics today; a defect note in the README plus alternative tools (`hover`, `goto_definition`, `find_references` work fine on `.ts` files) is sufficient until distribution lands.
- **Option B's handler design space is informed by Tier 2's real needs.** Building a generic server-request dispatcher in the abstract risks shipping handlers that don't match what Tier 2 tools actually need (e.g. `workspace/applyEdit`'s policy: auto-apply, mirror to LLM, refuse?). Doing it as M8 stage 0 means the design is grounded in real handler requirements rather than speculation.
- **Option A is a partial fix that still requires Option B later.** It would unblock tsserver diagnostics but leave the architectural gap intact for M8. The work to remove the patch when Option B lands would be small but nonzero, and the tsserver-specific config payload would need to be revisited at that point anyway. In effect, Option A trades ~1 hour today against ~30 minutes of churn at M8 plus a feature that doesn't materially help dogfooding.
- **Forgetting risk.** Deferral relies on remembering to do the work before Tier 2. Mitigated by gating M8 on it explicitly in `init.md` and capturing the deferral in this ADR.

## Decision

Adopt **Option C**. Defer all bidirectional LSP server-request handling until immediately before M8 (Tier 2 tools). Implement it as **M8 Stage 0**, the gating prerequisite that must land before any Tier 2 tool code.

The deferred work, when it lands, will:

- Convert `lifecycle.gleam`'s inbound loop into a classifier that distinguishes response / notification / request by JSON-RPC shape.
- Introduce a server-request handler registry keyed by method name, with default handlers for the cross-language base set (`workspace/configuration`, `client/registerCapability`, `client/unregisterCapability`, `window/showMessageRequest`, `window/workDoneProgress/create`, `workspace/applyEdit`).
- Add a per-language post-initialize push hook that sends `workspace/didChangeConfiguration` (and any other server-specific configuration messages) before any tool-level request is allowed through.
- Provide a typed surface for individual tools to register handlers for the duration of a request, so e.g. `rename_preview` can decide its `workspace/applyEdit` policy without polluting the global registry.

Until then:

- typescript-language-server's `get_diagnostics` returns `NoDiagnosticsObserved` for every `.ts` file. README and the language-config doc-comment call this out explicitly. The four other Tier 1 tools work normally on TypeScript.
- rust-analyzer, gopls, and pyright continue to push diagnostics unprompted; M3 + M4 dogfood evidence confirms they are unaffected.
- M5 (HTTP transport), M6 (Burrito + npm), M7 (extension bridge) ship on the current single-direction dispatch model.

## Consequences

**Easier:**

- M5 / M6 / M7 are independent of LSP dispatch internals and can ship in sequence without architectural detour.
- The eventual handler-registry design will be grounded in Tier 2's real needs (concrete handler specs for `workspace/applyEdit`, `client/registerCapability`'s effect on tool routing, etc.) rather than guesswork from the read-only Tier 1 surface.
- No mid-architecture rework of `lifecycle.gleam`: the patch-then-rewrite path that Option A would have created is avoided.

**Harder:**

- TypeScript users get a degraded `get_diagnostics` until M8 stage 0. Workaround for users who need diagnostics now: run `tsc --noEmit` themselves, or use the editor's Problems panel directly.
- M8 grows in scope: it is no longer "ship Tier 2 tools" but "ship server-request infrastructure, then ship Tier 2 tools." Plan M8 accordingly.
- Anyone reading the codebase between now and M8 may wonder why `lifecycle.gleam` ignores inbound requests. The doc-comment in that file should reference this ADR.

**Living with:**

- The risk of forgetting to do the work is mitigated by:
  - Explicit "Stage 0 — server-side LSP request handling" item in `init.md`'s M8 section.
  - This ADR.
  - The M3 + M4 dogfood memory note flagging tsserver diagnostics as deferred.
  - The fact that Tier 2's first attempt will surface the gap immediately (a `rename_preview` against tsserver will fail when the server emits `workspace/applyEdit`).
- The deferral assumes pre-release status holds through M5–M7. If the project ships publicly before M8 (it should not, per project policy), the gap becomes a user-visible defect rather than a documented in-progress limitation, and the priority calculus changes.

## Alternatives considered

- **Option A (workspace/didChangeConfiguration push only).** Rejected: a partial fix that still requires Option B at M8, with the per-language config payload likely needing rework when Option B lands. Net cost slightly higher than C, value mostly limited to "tsserver diagnostics work in dogfood" which is not a current need.
- **Option B (full bidirectional dispatch now).** Rejected for sequencing, not merit. The work is correct and necessary; doing it before M5–M7 means designing handlers without Tier 2's concrete requirements in hand. Reordered to M8 stage 0 instead of dropped.
- **Manual `workspace/configuration` shim per language.** Considered as a halfway point — handle just the one server-pull request and ignore the rest. Rejected: as soon as we have the dispatch loop infrastructure for one server-request method, the marginal cost of doing the full set is low and the cost of a half-implementation is interpretive ambiguity ("which server-requests does this codebase actually handle?"). Cleaner to defer the full thing.
