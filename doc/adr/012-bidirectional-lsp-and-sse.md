# 012. Bidirectional LSP server-request handling: registry, sessions, and SSE

**Status:** Accepted
**Date:** 2026-05-04

## Context

ADR-010 deferred bidirectional LSP server-request handling to "M8 Stage 0" — a gating prerequisite that must land before any Tier 2 tool code. This ADR pins the design decisions that Stage 0 will build against, before the implementation begins, so the registry shape, session lifecycle, and SSE protocol are not litigated mid-implementation.

The work spans two layers that meet at one tool flow:

- **LSP-facing.** Each LSP server is reached over a child-process stdio pipe with `Content-Length` framing. The current `lifecycle.gleam` receive loop only correlates response-by-id and drains everything else. Server-initiated requests (`workspace/configuration`, `client/registerCapability`, `workspace/applyEdit`, `window/showMessageRequest`, `window/workDoneProgress/create`, `client/unregisterCapability`) are silently dropped — adequate for Tier 1, breaks Tier 2.
- **MCP-facing.** Stdio transport is single-session implicit. HTTP transport (M5) accepts one-shot POSTs but has no session identity, no way for pharos to push a request to a specific MCP client, and no way for a client to respond to such a request. Tier 2's `rename_preview` may surface a `workspace/applyEdit` from the LSP that needs to reach the MCP client and return a verdict.

Eight decisions were aligned through walkthrough discussion. Each has options enumerated; the Decision section records the choice, this section records the forces.

### 1. Handler registry scope

Where do server-request handlers live? Three shapes considered:

- **Per-LSP-Client** — registry attached to each Client struct. Each language has its own table because per-language config (`workspace/configuration` answers) differs by server.
- **Global** — single Dict shared across all LSP clients. Simple but couples languages.
- **Per-LSP-Client + per-call override stack** — defaults on the Client; a tool's call site pushes additional handlers onto a stack that pops when the call returns.

The forces: per-language config is the strongest reason against global. Override stack is the strongest reason for per-call extension — `rename_preview` wants `workspace/applyEdit` to **capture** the edit while the global default **declines** it, without mutating the Client's persistent state.

### 2. Default for unknown server-requests

Server sends a method we don't have a handler for. JSON-RPC `error` reply with code `-32601` ("Method not found") vs accept-no-op `{result: null}` vs log-and-noop. Spec compliance argues for `-32601`. Visibility argues against silent acceptance: if a new server-request method appears in dogfood, we want to see the failure and add a handler intentionally rather than silently breaking server semantics.

### 3. HTTP `Mcp-Session-Id` lifecycle

Four sub-questions: where is the id issued (header / body / both), validation policy, eviction window, and stdio handling.

- **Header-only.** Body stays clean MCP. Avoids dual sources of truth.
- **Required from the second request onward.** First `initialize` issues the id; every subsequent request must carry it; missing or unknown id → `400 Bad Request`.
- **Idle 30 minutes, hardcoded.** Time arbitrary but bounded. MCP host should retry `initialize` on session-loss errors per spec; if dogfood pain shows up, hardcode becomes an env var.
- **Stdio: implicit single session.** No header, no validation. Stdio transport is a 1:1 pipe by definition.

### 4. Per-language config push timing

After `initialized`, send `workspace/didChangeConfiguration` with the language's payload. Two timing questions:

- Sync (block tool dispatch until the push flushes) or async (fire-and-forget, race risk)? **Sync.** tsserver's diagnostic gating depends on the config arriving before the first request — async creates flaky dogfood.
- Failure handling (refuse to start the LSP) or warn-and-continue? **Warn-and-continue.** Most servers degrade gracefully without the config; full refusal is too strict. Log the failure and let dogfood surface real problems.

### 5. Per-tool handler override API

Three shapes considered:

- Tool-entry-param: `Option(Dict(String, Handler))` on every tool entry signature. Explicit but pollutes signatures even when no override needed.
- Context-object passed through call chain. Implicit, requires plumbing through every layer.
- Stack manipulation API: `with_handler(client, method, handler, fn)` closure. Override is scoped to the closure body; pops automatically on return.

The closure form mirrors Erlang's `try/after` and Elixir's `Process.put/get` patterns for scoped state. The handler signature is `fn(Int, Dynamic) -> Result(Json, HandlerError)` (request id + params → reply body or error). Type-checked at compile time.

`rename_preview` is the exemplar use case: install a `workspace/applyEdit` handler that captures the edit into a process Subject and returns `{applied: true}` to the server, runs the rename request, then reads the captured edit from the Subject after the closure returns.

### 6. `$/progress` tracking and `readiness_token`

The find_references content-modified workaround at [src/pharos/tools/tier1/find_references.gleam](src/pharos/tools/tier1/find_references.gleam) is sleep + retry on `-32801`. Brittle: 1s delay can be too short on large workspaces, multiple retries amplify latency, and the heuristic is rust-analyzer-specific.

LSP defines `$/progress` notifications keyed by tokens. rust-analyzer emits `rustAnalyzer/Indexing` with `begin` / `report` / `end` states. gopls uses `setup`. pyright uses `Indexing`. tsserver uses none — operations are instant once configured. Tracking these tokens in the Client lets tools wait deterministically for the server to be ready instead of guessing at sleep durations.

Two design choices:

- **Storage.** Inside the `Client` struct's state. Pool is single-actor; no concurrency to coordinate. Each Client has its own progress map.
- **Per-language token name.** Add `readiness_token: Option(String)` to `LanguageConfig`. `None` means no wait needed (tsserver). Tools call language-agnostic `wait_for_ready(client, timeout_ms)`; the function looks up the token via the Client's config.

API:

```gleam
pub fn wait_for_token_end(client, token_name, timeout_ms) -> Result(Client, _)
pub fn wait_for_ready(client, timeout_ms) -> Result(Client, _)
pub fn token_state(client, token_name) -> Option(ProgressState)
```

`find_references` becomes `use client <- result.try(wait_for_ready(client, 30_000))` then the LSP request. The retry-on-content-modified path is removed.

### 7. `workspace/applyEdit` default behavior

LSP's `workspace/applyEdit` is the server requesting that the client write changes to files. Three behaviors a client can implement: decline (`{applied: false}`), capture (return `{applied: true}` and stash the edit instead of writing), or auto-apply (write files immediately).

pharos's role is LLM bridge, not autonomous editor. Auto-apply silently mutates user files without LLM/human consent — wrong default. Capture is the right behavior for tools that want to surface the edit to the LLM (`rename_preview`, `code_actions`), but applying it globally would mean every server-emitted edit reaches the LLM regardless of context — noisy.

The right default is **decline.** Tools that need the edit override per call. A future explicit `apply_workspace_edit` MCP tool (post-M8) lets the LLM apply edits intentionally when the workflow calls for it.

### 8. HTTP server-initiated request delivery

Tier 2 tools over HTTP need a route from pharos back to the originating MCP client when an LSP issues a server-request. Three options:

- **SSE** (`/mcp/events` keep-open response stream) + `/mcp/respond` POST endpoint for client → pharos response correlation. Standard MCP HTTP transport pattern. ~1-1.5 days of work.
- **Long-poll endpoint.** Functional but ugly; client polls `/mcp/poll` for pending server-requests.
- **Defer.** Stdio gets full Stage 0 server-request handling; HTTP gets `501 Not Implemented` for any tool flow that triggers a server-initiated request.

The forces: HTTP transport is for headless agents, CI use cases, Claude Desktop. Most Tier 2 dogfood happens over stdio (Claude Code default). Deferring SSE saves a day but means HTTP can't do the full Tier 2 surface, which leaks into M10's public-release story. Locking the protocol shape now means later additions don't break clients.

Three sub-decisions for SSE shape:

- **Correlation id source.** Pharos generates a UUID per server-request, sent in the SSE event, expected back in `/mcp/respond` body. Decouples the HTTP wire from LSP's internal int ids.
- **Concurrent in-flight server-requests.** Allow concurrent, dispatch by id. rust-analyzer overlaps progress notifications with applyEdit requests; serialization would deadlock.
- **Auth.** `Mcp-Session-Id` header on the SSE GET, validated identically to other HTTP requests. Reuses session-id machinery from decision 3.

## Decision

Adopt the following design for M8 Stage 0:

1. **Handler registry scope.** Per-LSP-Client default registry attached to the `Client` struct. Per-call override via a stack pattern (see decision 5). No global registry.

2. **Unknown method default.** JSON-RPC error response with code `-32601` ("Method not found"). No silent accept.

3. **HTTP `Mcp-Session-Id`.** Header-only, issued in `initialize` response, validated on every subsequent request, idle eviction at 30 minutes hardcoded. Stdio is implicit single-session.

4. **Per-language config push.** Sync after `initialized`, before tool dispatch unblocks. On send failure: log and continue.

5. **Per-tool handler override.** Closure-scoped API:

   ```gleam
   pub fn with_handler(
     client: Client,
     method: String,
     handler: Handler,
     body: fn(Client) -> a,
   ) -> a
   ```

   The override is in effect for the duration of `body`, popped automatically on return.

6. **Progress tracking.** Tracker lives in the `Client` struct. Per-language `readiness_token: Option(String)` field on `LanguageConfig`. Defaults populated for the four bundled languages: `rustAnalyzer/Indexing` (rust-analyzer), `setup` (gopls), `Indexing` (pyright), `None` (tsserver). `find_references`'s sleep-and-retry path is removed in favor of `wait_for_ready/2`.

7. **`workspace/applyEdit` default.** Decline (`{applied: false, failureReason: "not_supported"}`). Tools that need the edit (`rename_preview`, `code_actions`) install a capture handler via `with_handler` for the duration of the call.

8. **HTTP server-initiated request delivery.** SSE endpoint + correlation:

   - `GET /mcp/events` — per-session SSE stream. Required header: `Mcp-Session-Id`. Heartbeat: comment-line `:keepalive` every 15 seconds.
   - `POST /mcp/respond` — body shape `{request_id: <uuid>, result | error: ...}`. Pharos correlates by uuid and resumes the originating LSP flow.
   - **Correlation ids** are pharos-generated UUIDs, distinct from LSP-internal integer ids.
   - **Concurrent server-requests** per session are allowed and dispatched by uuid.
   - **Authentication** is `Mcp-Session-Id` header on the SSE GET, validated against the same session table used for regular requests.

### Implementation order

```
ADR-012 (this document)
   ↓
0A. Inbound classifier extension (lifecycle.gleam)
   ↓
0B. Handler registry + 6 default handlers
   ↓
0C. workspace_configuration field + sync push after initialized
   ↓
0F. $/progress tracking + readiness_token
   ↓
0G. Verify tsserver diagnostics + find_references regressions fixed
   ↓
0D. Mcp-Session-Id + SSE + /mcp/respond
   ↓
0E. with_handler scoped override API
   ↓
Stage 1: Tier 2 tools (read deep cuts → workspace_edit_render → edit-as-data → lsp_request_raw)
```

0E lands when 1B's first edit-as-data tool needs it; until then the default decline path is sufficient.

## Consequences

**Easier:**

- Tier 2 tools have a clear contract: install the handler you need with `with_handler`, the rest is the default path. No registry-mutation gymnastics, no global state to reason about.
- tsserver diagnostics regression closes naturally as a side effect of 0C (config push). No standalone fix needed.
- find_references content-modified retry disappears; replaced with deterministic wait_for_ready. Less brittle, less code.
- Per-language progress-token config is one-line additive; new servers added later just declare their token.
- HTTP SSE protocol shape is locked now, so any future MCP host that uses pharos's HTTP transport sees a stable wire from M8 onward. M10 public release does not break clients on a v0.2 → v0.3 SSE addition.

**Harder:**

- The receive loop in `lifecycle.gleam` becomes a multi-classifier dispatcher. Reading the code is harder than the current sequential drain. Mitigation: small classifier with a single match on a tagged Classified variant and clear handler-table dispatch.
- Two correlation id systems live in pharos: LSP request ids (integers, scoped to a Client) and SSE server-request ids (UUIDs, scoped to a session). Bridging them in `rename_preview` requires care. Mitigation: a single helper `with_captured_apply_edit/3` that hides the bridging from the tool author.
- HTTP transport gains a stateful component (session table). M5 was deliberately stateless. Eviction logic and stale-session handling become surface area worth testing. Mitigation: hardcoded 30 minute idle eviction is simple; revisit only if dogfood surfaces issues.
- SSE adds a long-lived connection per session. Memory and process count grow with concurrent MCP clients. For dogfood (1-2 clients) this is a non-issue; for headless-agent fleets (M10+) it becomes a capacity concern. Mitigation: M9 polish revisits idle eviction and connection caps.

**Living with:**

- The `with_handler` closure form requires every Tier 2 edit tool to remember to install its override. Forgetting it means the server's applyEdit is silently declined and the tool returns an empty edit. Mitigation: tool tests should send a synthetic applyEdit through a fake LSP and assert the captured shape.
- 30 minute eviction is arbitrary. Most MCP host idle scenarios are shorter (LSP cold-start re-warming dominates). Configurable later if needed.
- SSE GETs are kept open; ngrok/cloudflared/typical reverse proxies idle-timeout at 60-120 seconds. Pharos's 15s heartbeat defeats most proxies but not all. Documented in `bridge-protocol.md` once that exists.
- `workspace/applyEdit` decline-by-default means a server that emits an applyEdit outside the rename/code-actions path (e.g. an autoformatter that wants to reformat-and-write) silently fails to write. This is the correct safety default for an LLM bridge but could surprise direct LSP-passthrough users. Documented in tool descriptions.

## Alternatives considered

- **Global handler registry.** Simpler than per-Client but couples per-language config across servers. Rejected for clarity, not for cost.
- **Tool-entry-param override (`Option(Dict(...))`).** Explicit but pollutes every tool's signature. Rejected; closure scope is cleaner.
- **Auto-apply default for `workspace/applyEdit`.** Considered briefly. Silent file mutation under LLM agency without explicit confirmation violates the safety stance. Rejected.
- **Method-not-found vs accept-noop for unknown server-requests.** Accept-noop trades visibility for permissiveness. Rejected; visibility wins.
- **Long-poll instead of SSE.** Functional but uglier wire. Rejected once SSE was decided to be in-scope for Stage 0.
- **Defer SSE entirely; HTTP returns 501 for Tier 2 flows that need server-requests.** Saves ~1 day of Stage 0 work. Rejected because locking the protocol shape now is more valuable than the day saved, and M10 public release plans cleaner with HTTP at full Tier 2 parity.
- **Reuse LSP integer request ids for SSE correlation.** Leaks LSP internals into the HTTP wire. Rejected; UUIDs decouple the layers.
- **Serialize concurrent server-requests per session.** Simpler dispatcher but deadlocks against rust-analyzer's overlapping progress + applyEdit. Rejected.
- **Async (fire-and-forget) `workspace/didChangeConfiguration` push.** Faster handshake but creates race conditions where the first tool call arrives before the server has the config. Rejected; sync push is the right default.
- **Per-Client progress tracker as a separate actor.** More flexible but unnecessary — pool is single-process, no contention. Rejected; in-Client state is simpler.
