# 029. Custom URI schemes: relaxed gate, config-driven registry, read-only semantics

**Status:** Proposed
**Date:** 2026-05-20

## Context

Pharos's URI gate in [session.gleam](../../src/pharos/lsp/session.gleam)
rejects any URI that is not `file://` with `NotAFileUri(uri)`. This is
correct for the languages currently exercised in the benchmark — Gleam,
Go, Python, Rust, TypeScript — where dependencies always materialize to
disk (`.cargo/registry/`, `node_modules/`, `.venv/lib/`, `$GOPATH/pkg/mod/`).
For those ecosystems, file:// covers both first-party source and deps,
and the gate is a clean safety check.

It is not correct for Java or C#. Their dependencies ship as compiled
artifacts (`.class` in JARs, IL in DLLs) with no on-disk source.
Language servers in those ecosystems address this by inventing custom
URI schemes — `jdt://` for jdtls, `csharp://` for omnisharp — that
represent virtual locations the server can materialize on demand
(decompilation or unzip + cache). When `goto_definition` lands on a
JAR class, the server returns a `jdt://contents/...` URI, expecting
the client to round-trip it through subsequent LSP calls.

Pharos's gate rejects these URIs before they reach the LSP. A Java
user calling `goto_definition` on an `import` statement gets back a
`jdt://` URI and then hits `NotAFileUri` on every follow-up. The LLM's
options collapse to grep, which can't see JAR contents at all.

Four design pivots emerged from working through this:

1. **The axis is "on disk" vs "virtual", not "repo" vs "deps".**
   `file://` legitimately covers anything materialized — including
   ecosystem dep caches. Custom schemes exist specifically for content
   that has no on-disk path. Treating the distinction as repo-vs-dep
   would prevent us from using `file://` for cargo registry deps,
   which is fine today.

2. **The LSP server already handles round-trips correctly for its own
   custom URIs.** jdtls accepts `jdt://` for `textDocument/hover`,
   `textDocument/references`, etc. without explicit `didOpen`, because
   it generated those URIs and tracks the virtual buffers internally.
   Pharos does not need to synthesize a `file://` shim — passthrough
   works if the gate stops rejecting.

3. **Discoverability is the dominant cost, not abstraction.** An LLM
   that knows `jdt://` content is reachable via `java/classFileContents`
   is rare; an LLM that sees a tool description naming `jdt://` is
   common. Whatever we ship, the LLM must be told that custom schemes
   are supported and how to use them. The cheapest place to advertise
   this is the MCP `instructions` field, which loads once at handshake.

4. **Virtual URIs are read-only by their nature.** A JAR is a compiled
   archive; the decompiled source jdtls returns has no storage to
   write back to. Even if pharos forwarded an `applyEdit` to jdtls
   with a `jdt://` URI, the edit would be in-memory at most and never
   persist. LLMs occasionally try to "fix bugs" inside dependencies;
   the right semantic is to reject pre-flight with a helpful message,
   not silently no-op.

A naïve framing of this work — "every URI-accepting tool gains a
`workspace_uri_hint` param, every tool description grows ~15 tokens
explaining when to pass it" — costs ~430 tokens of permanent context
across the ~20 affected tools. That is most of the budget for the
v1.0 release. A scheme-based session-inference design collapses the
cost to ~130 tokens by keeping the hint advert in one place (the
server instructions string) and letting pharos resolve the active
session from the scheme itself.

Java + C# are the immediate motivating users, but the same machinery
handles any future custom scheme some other language server invents.
The registry is per-language config, not hardcoded.

## Decision

Pharos accepts a whitelisted set of custom URI schemes alongside
`file://`, with the whitelist driven by per-language toml config.
Custom-scheme URIs flow through existing navigation tools (`hover`,
`goto_definition`, `find_references`, `document_symbols`, etc.)
unchanged after the gate relaxation. Session routing for non-`file://`
URIs is inferred from `scheme → language → active sessions`; the
single-workspace case (one Java workspace open) needs no extra LLM
input. A new `fetch_uri_contents` tool covers reading raw text from
virtual URIs since pharos's existing tools never returned file
contents directly. Edit-class tools reject virtual URIs pre-flight
with a teaching error.

Concretely:

**Config layer.** Each language entry in the toml override gains an
optional `custom_uri_schemes` map:

```toml
[language.java]
custom_uri_schemes.jdt.fetch_method = "java/classFileContents"
custom_uri_schemes.jdt.fetch_response_field = "contents"
```

Pharos reads this at startup and builds a registry keyed by scheme,
storing `(language, fetch_method, response_field)`. Adding a new
scheme for a new language is a config change with no code change.

**Gate relaxation.** [session.gleam](../../src/pharos/lsp/session.gleam)
keeps `file://` as the default path and adds a branch for whitelisted
schemes. The path-based workspace-root walk does not apply; sessions
are resolved by `scheme → language → active sessions`:

- Zero active sessions for the language → error suggesting how to
  open a workspace first.
- One active session → route there.
- Multiple active sessions → reject with `workspace_uri_hint` as
  the disambiguation key, listing the available workspaces.

**Tool surface.** The optional `workspace_uri_hint` field is added
to the decoder of every URI-accepting tool but is *not* advertised
in tool descriptions. Single-workspace users never pay attention to
it; multi-workspace users discover it through the disambiguation
error message, which names the field and shows the syntax.

**`fetch_uri_contents` tool.** New tool with signature
`(uri, workspace_uri_hint?) -> { uri, content, language_id }`. Looks
up the scheme in the registry, dispatches the configured fetch method,
extracts content via the configured response_field, returns a pharos
envelope. This is the only tool whose description explicitly names
custom schemes, because it's the natural entry point for "read this
JAR class."

**Edit guards.** `apply_workspace_edit`, `format_document`,
`edit_at_symbol`, and the apply path of `rename_preview` reject any
URI with a non-`file://` scheme pre-flight, with an error message
explaining that virtual URIs represent read-only library code and
pointing the LLM at the right pattern (create an override file in
the project, or change build configuration).

**LLM advert.** The MCP `instructions` string is generated at startup
from the registry. When two schemes are configured, the string reads
roughly:

> Custom URI schemes supported: `jdt://` (Java JAR contents via jdtls),
> `csharp://` (C# DLL contents via omnisharp). These flow through
> navigation tools transparently in single-workspace setups. Use
> `fetch_uri_contents` to read raw text. Edit operations on virtual
> URIs are rejected — modify deps via project overrides or build
> configuration.

Roughly ~100 tokens, loaded once per session, scales linearly with
the number of registered schemes.

## Consequences

**What becomes easier.** Java and C# users can navigate JAR / DLL
contents on day one — goto-definition into a JAR class, find-references
across the boundary, hover for types, document-symbols outline,
fetch source via `fetch_uri_contents`. No bespoke per-tool integration
work; the gate and config carry the load. Adding a new language with
its own custom scheme (Scala's metals uses `jar://`, Dart uses
`org-dartlang-sdk://`, etc.) is a toml edit, not a code change. The
LLM is taught about the boundary through a single instructions
string rather than 20 tool descriptions.

**What becomes harder.** Session inference logic in
[session.gleam](../../src/pharos/lsp/session.gleam) gains complexity
to handle ambiguity. Wrong-scheme-for-server combos
(`jdt://` passed to a python session) need to fail with a helpful
error rather than a silent empty LSP result; pharos must enforce
that mapping rather than letting the LSP server reject. Adding the
optional decoder field across ~20 tools is mechanical but unavoidable
clerical work. The instructions-string generator is one more piece
of startup wiring that must stay in sync with the registry.

**What we now have to live with.**

- *No synthesized `file://` paths for virtual URIs.* The cheapest
  composition path is direct passthrough of `jdt://` through every
  tool. We do not maintain a reverse map of synthetic `file://` ↔
  `jdt://`. The consequence is that Claude Code's built-in `Read`
  tool, which is filesystem-only, cannot read JAR contents — only
  pharos's `fetch_uri_contents` can. LLMs that reach for `Read` by
  default need to learn to use the new tool when the URI is virtual.
  The instructions string covers the discovery path.

- *No `didOpen` for virtual URIs.* We rely on the LSP server already
  knowing about virtual URIs it emitted. If a future server requires
  explicit `didOpen` with content fetched separately, we will need
  per-server `didOpen` orchestration. None of the servers we currently
  target (jdtls, omnisharp) require this.

- *Edit-reject error must be teaching, not just safe.* If the message
  is bland, the LLM will retry the same edit with different params.
  The text needs to name the alternative pattern (override file, build
  config) so the LLM picks a productive next action.

- *Discoverability fallback depends on the LLM reading the
  instructions string.* If the LLM ignores instructions and tries
  `Read(jdt://...)` first, it gets a filesystem error that does not
  mention pharos's `fetch_uri_contents`. We could mitigate by having
  pharos's tool descriptions hint at `Read` not working for virtual
  URIs, but this re-inflates the token footprint. The expected outcome
  in practice is that LLMs do consult instructions and that
  `fetch_uri_contents`'s description is enough of a beacon.

- *Real validation requires a Java workspace + jdtls install.* The
  benchmark corpora are all `file://` languages. Verifying the
  composition end-to-end means scripting a Java fixture (e.g. a Maven
  project with a few JAR deps, or pulling a public jdtls smoke
  example) and running it manually or in a separate CI job. This is
  why the work is sized as ~480 LOC + ADR + tests rather than
  ~80 LOC for the gate alone.

## Out of scope

Two related concerns surfaced while shaping this ADR and were
intentionally left out so the scope stays tight:

**1. Guarding against edits to `file://` dependencies.** Edits to
files under known dep dirs (`.venv/lib/python*/site-packages/`,
`~/.cargo/registry/`, `$GOPATH/pkg/mod/`, `node_modules/`) persist
to disk and can corrupt the user's installed dependencies. Same
class of problem as editing virtual URIs (LLM tries to "fix" library
code), worse blast radius (changes actually take effect). Detection
differs: path-pattern match against per-language dep-dir conventions,
not scheme inspection. Belongs in a separate edit-safety ADR with
its own config grammar and OS-aware path handling. Tracked in
[future-improvements.md](.private/future-improvements.md).

**2. Discoverable wrapping of uncurated LSP methods via `lsp://`
pseudo-URIs.** A separate idea in
[future-improvements.md](.private/future-improvements.md) proposes
registering `lsp://textDocument/foldingRange`,
`lsp://rust-analyzer/inlayHints`, etc. so agents can target unwrapped
LSP methods by name instead of constructing a `lsp_request_raw`
call with a string method literal. The motivation is also
discoverability, but the problem axis is different: there the
*content* is fine, the *method* is uncurated. Mixing it into this
ADR would muddy both stories. If it ever becomes load-bearing it
gets its own ADR.

## Alternatives considered

**A. `lsp_request_raw` passthrough only.** Zero new code; LLM
constructs `workspace/executeCommand` with the right method and URI.
Rejected because frontier LLMs know the existence of `jdt://` but
guess the method name unreliably (~30–50% on jdtls, far worse on
niche servers). The escape hatch exists but is not discoverable.

**B. `workspace_uri_hint` advertised on every URI-accepting tool.**
Naïve version of the relaxed-gate design. Costs ~300 tokens of
per-tool description growth on top of the instructions string.
Rejected after sizing — scheme-based inference covers the
single-workspace case for free, and the disambiguation error covers
the multi-workspace case via a single error string rather than
permanent context bloat.

**C. Materialize virtual URIs to synthesized `file://` paths.**
Pharos writes JAR contents to tmpfiles, returns `file:///tmp/pharos-jdt/...`,
and maintains a forward+reverse map so outbound LSP calls rewrite
back to `jdt://`. Composition becomes transparent to `Read` and other
filesystem-aware tools. Rejected for v1.0 because ~300 LOC of
state-management complexity (lifecycle, dedup, stale-file cleanup,
URI rewriting on every LSP message) is not justified when direct
passthrough achieves the same composition for navigation tools. Worth
reconsidering in v1.1 if real Java usage shows that LLMs reach for
`Read` despite the instructions and the `fetch_uri_contents` tool.

**D. Blob-mode `fetch_uri_contents` without relaxing the gate.** The
tool returns content, but every other URI-accepting tool still
rejects `jdt://` at the gate. Rejected because the LLM gets the
content but cannot navigate it — `find_references` from inside the
JAR class is impossible, and the LLM hits a dead end one step past
the read. Worst of both worlds: discoverable but uncomposable.

**E. Hardcoded `jdt://` support, no config.** Ship jdtls integration
inline in pharos with the scheme and method baked in. Smaller LOC
(~50). Rejected because it leaks abstraction — pharos starts to
"know about" specific language servers — and adding the next scheme
(C# omnisharp) duplicates the hardcoding. Config-driven generalizes
at modest extra cost (~30 LOC for the registry, no code change per
new scheme).
