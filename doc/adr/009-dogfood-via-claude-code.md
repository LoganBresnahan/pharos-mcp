# 009. Dogfood the MCP server via Claude Code at every milestone

**Status:** Accepted
**Date:** 2026-05-02

## Context

The product is an MCP server whose only consumer is an LLM running inside an MCP host (Claude Code, Claude Desktop, Cursor, etc.). The interesting failure modes — wrong tool selection, confusing schemas, awkward content-block rendering, descriptions an LLM misreads — are all consumption-side and invisible to unit tests written by humans. A test that asserts "the response contains `\"text\":\"hi\"`" is correct but says nothing about whether an LLM looking at the same response can do something useful with it.

The project is being developed in conversation with an instance of Claude running inside Claude Code. That instance can be configured as a real consumer of `llm_lsp_mcp` while development is happening — restart the harness, the new tools register, the LLM uses them in the next turn. This is the most direct possible feedback loop: the same kind of consumer that will use the product in production validates each piece as it ships.

Three options were considered for testing methodology beyond unit tests:

**Option A — Unit tests only.** Continue with gleeunit alone. Fast, pure, hermetic. Misses every failure that depends on actual LLM consumption: misleading tool names, schemas an LLM struggles to fill in correctly, content blocks that read fine to a human but trip up an LLM. Risk of shipping milestones that pass tests and fail in real use.

**Option B — Add unit tests + an automated smoke test in CI.** The smoke test pipes a hand-written sequence of MCP messages through the binary and asserts on substrings of the response. Catches regressions in framing, dispatch, and main-loop behavior. Doesn't catch consumption-side issues either, but at least keeps the protocol-level contract honest in CI.

**Option C — Unit tests + CI smoke test + dogfooding via Claude Code.** Each milestone is verified by configuring `llm_lsp_mcp` as an MCP server in the developer's Claude Code at the time the milestone is implemented, then asking the in-conversation LLM to actually use the new tools on the project's own source code. The LLM reports what worked, what was confusing, and what was missing. Findings feed back into the milestone before it merges.

The marginal cost of Option C over Option B is small — restart Claude Code, ask the LLM to exercise the new tools, take notes. The marginal benefit is large — every tool description, schema, and content block format gets consumer-tested before merge by an actual instance of the kind of consumer it will face in production. The project is uniquely well-suited to this because the developer is conversing with the consumer in real time during development.

## Decision

Adopt **Option C**: unit tests + CI smoke test + dogfooding via Claude Code at each milestone.

### What dogfooding means in practice

For each milestone that adds tools or changes the protocol surface:

1. The implementation lands locally, all unit tests green, CI smoke test green.
2. The developer adds (or already has) `llm_lsp_mcp` configured in their Claude Code MCP config:
   ```json
   {
     "mcpServers": {
       "llm-lsp-mcp": {
         "command": "mix",
         "args": ["start"],
         "cwd": "/home/oof/llm_lsp_mcp"
       }
     }
   }
   ```
3. The developer restarts Claude Code (or reloads MCP config).
4. In the next conversation turn, the LLM has the tools registered as `mcp__llm-lsp-mcp__<tool_name>`.
5. The developer asks the LLM to exercise the new tools against the project's own source code: "use `mcp__llm-lsp-mcp__hover` on line 47 of `src/llm_lsp_mcp/mcp/server.gleam` and tell me what it says", etc.
6. The LLM reports:
   - Did the tool produce useful output?
   - Was the description clear enough that tool selection was unambiguous?
   - Was the input schema clear enough to fill in correctly without trial-and-error?
   - Was the content block format readable / actionable?
7. Findings are addressed in the same milestone PR before merge — naming, schema, descriptions, content blocks updated as needed.

### What gets dogfooded when

| Milestone | Dogfood target |
|-----------|---------------|
| 1 (echo server) | Claude calls `echo`, validates the plumbing |
| 3 (`get_diagnostics`) | Claude reads diagnostics for this very project's `.gleam` files |
| 4 (Tier 1 tools) | Claude uses `hover`, `goto_definition`, `find_references`, `document_symbols`, `workspace_symbols` on the project's own code |
| 5 (HTTP transport) | Claude (or any HTTP client) hits the HTTP transport and validates parity with stdio |
| 7 (extension bridge) | With `llm_lsp_mcp_ext` running in VSCode, Claude reads diagnostics on an unsaved buffer and confirms it sees the unsaved version |
| 8 (Tier 2 / write tools) | Claude requests rename previews, format previews, code actions on this project; verifies WorkspaceEdit content blocks are actionable |

### What this does not replace

- Unit tests still cover pure logic with hermetic precision (gleeunit, property tests for framing).
- CI smoke tests still gate every PR for protocol-level contract regressions.
- LSP integration tests against real language servers still validate the LSP-side plumbing in isolation from MCP concerns.

Dogfooding adds a fourth layer focused on consumption ergonomics. It is mandatory before milestone close, but it is not a replacement for the other three layers.

## Consequences

**Easier:**
- Tool descriptions and schemas reviewed by an actual LLM before merge — not after users complain
- Content block formatting (markdown, structured JSON, unified diffs) gets evaluated by the kind of consumer that will read them in production
- Self-validating project: at Milestones 3+ the project's own code is the test corpus. Bugs in tools surface as wrong answers about our own code that we can immediately spot.
- Closes a feedback loop that would otherwise only close after release
- Forces us to actually run the binary as a real MCP server at each step, not just as a thing that compiles

**Harder:**
- Every milestone requires a Claude Code restart cycle to pick up new tools — minor friction, ~10-30s per cycle
- Dogfooding is qualitative; findings are LLM-conversational rather than pass/fail. Discipline needed to track and act on them.
- Requires the developer to be actively conversing with an LLM during development. If the developer is offline or working without a Claude Code session, milestones can implement but not close until dogfooding happens.
- Tool descriptions and schemas may need iteration after the first dogfood pass — milestone PRs grow accordingly.

**Living with:**
- Dogfooding findings are not version-controlled by default. Significant findings should be captured in commit messages or as TODOs that ship with the milestone code.
- The "LLM consumer" used for dogfooding is whichever Claude version is in the developer's Claude Code at the time. As Claude versions change, conclusions about tool ergonomics may shift. Treat findings as point-in-time evidence, not eternal truth.
- The MCP server runs with full user privileges via the harness — see security note in [README.md](../../README.md). This is true of every MCP server, but worth re-stating in the context of dogfooding our own code on our own machine.

## Alternatives considered

- **Option A (unit tests only).** Rejected — the most important class of failures (consumption-side ergonomics) is invisible to unit tests.
- **Option B (unit + CI smoke).** Better than A but still misses LLM-side concerns. Adopted as a subset of C, not as a substitute.
- **Manual periodic dogfooding (after several milestones).** Considered — would be cheaper but lets ergonomic problems compound across milestones before being caught. Rejected in favor of per-milestone discipline.
- **Automated LLM-driven testing in CI** (run Claude as an MCP client in a CI job). Plausible but expensive in tokens, slow in CI, and hard to assert on. Worth revisiting if the project ever grows a real test budget.
