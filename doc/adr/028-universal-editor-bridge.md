# 028. Universal editor bridge: sensors and displays, never LSP host

**Status:** Proposed
**Date:** 2026-05-19

## Context

ADR-003 established a hybrid shape: pharos is a standalone binary that
always works disk-only, plus an optional VSCode extension exposes
unsaved-buffer state via a localhost HTTP endpoint. The bridge module
(`bridge/buffer.gleam`, `bridge/client.gleam`, `bridge/workspace.gleam`)
is scaffolded but the client side is still a stub
([src/pharos/bridge/client.gleam:11](src/pharos/bridge/client.gleam#L11)
— "Placeholder; lands in Milestone 7"). The VSCode extension lives in
the companion repo per ADR-007 but is not wired up end to end.

Three things changed since ADR-003 was accepted:

1. **Competitive landscape clarified.** Serena (24k★) bundles
   memory + symbol editing on top of multilspy but its open-source LSP
   backend has the same external-dependency gap pharos has — it leans
   on its paid JetBrains plugin to close it. The 1.5k★ Go server is
   minimal. The TS forks are POCs or single-language. A VSCode-only
   extension (beixiyo/vsc-lsp-mcp, 25★) takes the opposite design:
   editor becomes the LSP host, MCP server is a thin JSON-RPC wrapper
   over `vscode.executeXxxProvider`. That approach concedes BEAM's
   strength (OTP-supervised LSP lifecycle) for zero-config language
   coverage. Pharos's headless-by-default story is differentiated and
   should not be sacrificed.

2. **The unsaved-buffer feature is the floor, not the ceiling.** Once
   the binary speaks to a live editor, several additional capabilities
   come into reach that no competitor has: focus context tools,
   diff-preview UX for `apply_workspace_edit`, push-side diagnostics
   surfacing, and progress reporting. All of these are achievable
   while pharos retains full LSP ownership.

3. **Editor diversity matters.** ADR-003 leaves a footnote that
   non-VSCode editors get only the disk-based mode "unless someone
   implements a bridge extension for that editor." Six months later,
   the protocol is still unimplemented and the footnote has become a
   blocker for shipping. A protocol designed for VSCode first and
   ported "if anyone bothers" is a protocol nobody will port. A
   protocol designed for portability from day one widens the surface
   that any single plugin must cover, but ports become tractable.

This ADR makes three commitments: define the bridge's role narrowly
(it is a sensor + display, never an LSP host); enumerate the tiers of
features it unlocks beyond unsaved buffers; specify a protocol shape
intended to be portable to any editor with extension hooks.

## Decision

**The bridge is a sensor and a display. It never owns LSP request
lifecycle.** Pharos always spawns and supervises its own LSPs via the
existing OTP tree (ADR-013, ADR-017). When an editor plugin is
present, pharos consumes editor state events and optionally renders
output through editor-side display callbacks. When no plugin is
present, pharos falls back to disk reads and stderr output — exactly
the headless story of ADR-003.

This rules out the "use the editor's already-running LSP" design
(beixiyo's model) explicitly. Sustaining BEAM-supervised LSPs is
pharos's identity. Outsourcing them to an editor would invert that.

### Architectural seam

The bridge module already lives at the right layer per ADR-003:
`bridge/*` modules read editor state, which `tools/*` and the LSP
pool consult when forwarding state to LSPs. The pool itself (and the
client / port / lifecycle subsystem under `src/pharos/lsp/`) does
**not** grow a `Transport` variant. There is no bridge-proxy
transport. Editor-side LSP delegation does not exist.

### Event channels

Editor plugins speak to pharos over a single localhost transport.
Default = WebSocket on a configurable port (HTTP+SSE as fallback if
WebSocket support in a host editor is awkward; the wire format is the
same JSON). All traffic is bidirectional. The protocol is one shape
across all editors.

**Editor → pharos events.** Editor pushes state. Pharos consumes,
forwards to its own LSPs via the existing client.

- `editor/didOpen` `{uri, text, language, version}`
- `editor/didChange` `{uri, version, content_changes}` (LSP-shape
  delta or full text)
- `editor/didSave` `{uri}`
- `editor/didClose` `{uri}`
- `editor/focus` `{active_uri, cursor: {line, character}, selection:
  Range, viewport: Range, open_files: [uri]}`
- `editor/didRenameFiles` `{old_uri, new_uri}`
- `editor/didCreateFiles` `{uris: [uri]}`
- `editor/didDeleteFiles` `{uris: [uri]}`

**Pharos → editor callbacks.** Optional. Plugin advertises which it
supports during handshake. Missing-capability calls degrade silently.

- `editor/showDiff` `{workspace_edit, prompt}` → `{accepted: bool}`
- `editor/showNotification` `{level, message}`
- `editor/publishDiagnostics` `{uri, diagnostics: [Diagnostic]}`
- `editor/progressBegin / progressReport / progressEnd` (mirrors
  LSP `$/progress`)

Handshake exchanges protocol version + capability lists in both
directions. Either side can refuse a session whose version it does
not support, falling pharos back to disk-only mode silently.

### Tiers of value unlocked

The protocol enables five tiers, listed in implementation order:

1. **Live document mirroring (Tier 1, mandatory).** Editor streams
   `didOpen`/`didChange`/`didSave`/`didClose` to pharos. Pharos
   forwards to its own LSPs. Pharos LSPs see the current buffer state.
   Hover, references, diagnostics, and rename now reflect unsaved
   edits. This is the headline win and the entire reason for the
   bridge.

2. **Focus context tool (Tier 2).** New MCP tool `editor_focus()`
   returns the active URI, cursor, selection, viewport, and open file
   list. LLM uses it to answer "what is the user looking at?". Pairs
   with `containing_symbol` and `find_symbol`. No competitor exposes
   this today.

3. **Diff-preview UX for writes (Tier 3).** Pharos has
   `apply_workspace_edit` with `dry_run=true` as default. The bridge
   adds a reverse channel: pharos asks the editor to render the
   `WorkspaceEdit` as a diff for the user, await yes/no. On yes,
   pharos commits with `dry_run=false`. Closes the human-in-loop story
   for refactors and renames without inventing an in-band approval
   mechanism inside MCP.

4. **Diagnostics surfacing (Tier 4).** Pharos's LSPs already produce
   diagnostics. Today the MCP host pulls them via `get_diagnostics`.
   With the bridge, pharos pushes to the editor's native Problems
   panel via `editor/publishDiagnostics`. The user sees what pharos
   sees, in their editor, without leaving it.

5. **Progress reporting (Tier 5).** Long operations (mass renames,
   large `find_referencing_symbols` scans) emit progress events to
   the editor's native progress UI. Pharos already has the data;
   the bridge just provides the channel.

Tier 1 is required for the bridge to be worth shipping at all. Tiers
2–5 are independent and can land in any order after Tier 1.

### Universal-by-design protocol

The protocol is intentionally small and explicitly editor-agnostic.
Plugin authors implement the same JSON messages over WebSocket
regardless of host editor. The protocol document
(`doc/bridge-protocol.md`, to be expanded from ADR-003's version)
specifies wire format, capability negotiation, error semantics, and
sequencing rules. It does not reference any VSCode-specific concept.

Plugin effort by editor (rough estimate):

| Editor | Plugin language | Estimated effort |
|---|---|---|
| VSCode (covers Cursor, Windsurf, VSCodium via shared extension API) | TypeScript | ~200 LOC, ships first |
| Neovim | Lua | ~150 LOC |
| Zed | Rust (WebAssembly extension API) | ~300 LOC |
| Emacs | Elisp | ~150 LOC |
| JetBrains (IDEA, GoLand, etc.) | Kotlin | ~500 LOC, higher friction |
| Sublime Text | Python | ~200 LOC |
| Helix | Pending an extension API; bridge stays headless until then | — |

Pharos owns the protocol spec. Plugins are out-of-tree. The
`pharos-vscode` repo (the ADR-007 split) is the canonical reference
implementation; other editor plugins can live in any repo by any
author, identified by Capability Matrix entries in the protocol
documentation rather than by physical co-location.

### Plugin governance

The bridge is not a library or SDK that third parties link against.
Pharos's "plugin API" is the WebSocket wire protocol — a JSON
contract documented in `doc/bridge-protocol.md`. Plugin authors
implement the contract in whatever language their host editor's
plugin system uses. They never import pharos, and pharos never
imports them. This loose coupling is deliberate: it eliminates
build-time dependencies between pharos and its plugin ecosystem,
makes plugins releasable on their own schedules, and avoids the
problem of pharos's Gleam codebase needing to publish bindings for
seven different plugin languages.

**Repo layout.** Each plugin lives in its own repository, maintained
by its author. Reference plugins for VSCode and (eventually) Zed
ship from repos owned by the pharos project, following the ADR-007
two-repo precedent. Community plugins live wherever their authors
host them. The naming convention `pharos-<editor>` (e.g.
`pharos-neovim`, `pharos-emacs`, `pharos-jetbrains`) is recommended
for discoverability but not enforced.

**What pharos owns:**

1. **The protocol spec** (`doc/bridge-protocol.md`). Source of truth
   for plugin authors. Versioned. Each major version gets a frozen
   spec document; minor versions amend in place with a changelog.
2. **Conformance tester** (`bin/test-plugin-conformance.py` or
   equivalent). Connects to a running plugin's WebSocket, exercises
   each message type per tier, asserts plugin responses match spec.
   Plugin authors run it locally before declaring a release
   compatible with protocol version N. Same shape as the LSP test
   suites Microsoft publishes alongside `vscode-languageserver-node`.
3. **Reference implementations.** `pharos-vscode` (and potentially
   `pharos-zed` if it lands). Always pass conformance. Always
   current with the latest protocol minor. Double as living spec —
   ambiguities in `doc/bridge-protocol.md` get resolved by
   inspecting the reference.
4. **Plugin registry** (`doc/plugins.md` in this repo, or a
   dedicated `pharos-plugins-list` repo if the catalog grows).
   Pure discovery — not a package manager. Lists name, author,
   repo URL, supported protocol versions, supported tiers, status.
5. **Scaffolding** (`pharos-plugin-starter` repo or
   `pharos init-plugin <editor>` subcommand). Emits a starter
   directory with README skeleton, conformance test invocation,
   sample WebSocket client snippet for the chosen plugin language,
   and a `CHANGELOG.md` shape. Reduces "where do I start" friction
   for new authors.

**What plugin authors own:**

- Their plugin's repo, releases, and issue tracker.
- Compatibility updates when the protocol version bumps.
- Marketplace presence (VS Marketplace, JetBrains Marketplace,
  Sublime Package Control, etc.) if relevant.

**Quality bar.** Two-tier listing in `doc/plugins.md`:

- **Reference plugins** — maintained by the pharos project.
  Always pass conformance for declared tiers. Always tracking
  current protocol. Listed first.
- **Community plugins** — third-party. Listed if they meet three
  criteria: pass the conformance tester for declared tiers; ship
  a README and LICENSE; maintainer responds to GitHub issues
  within a reasonable window (target: 90 days). A quarterly pass
  over the list checks responsiveness; stale plugins move to a
  "stale" subsection. Plugins inactive for a year are removed
  with a notice.

**Versioning policy.** The protocol follows semver:

- **Major bump** (`v2.0` → `v3.0`) is breaking. Handshake refuses
  incompatible plugins. Pharos supports the last two major versions
  at any time. Deprecation cycle: one major release announces the
  deprecation, the next removes the deprecated surface.
- **Minor bump** (`v1.0` → `v1.1`) is additive. Old plugins ignore
  new fields; new plugins detect missing capabilities via the
  handshake's capability list and degrade gracefully.
- **Patch bump** (`v1.0.0` → `v1.0.1`) is documentation only — no
  wire-format change.

Capability negotiation handles minor differences across implementations
at runtime. A major mismatch produces a refused handshake plus a
stderr warning, and pharos falls back to disk-only mode.

**Stability commitments** published in `doc/bridge-protocol.md`:

- Minor versions are backward-compatible. A plugin built against
  v1.0 keeps working through v1.N.
- Deprecated messages remain functional for one full major version
  past their deprecation announcement.
- Declaring an unsupported capability is silently ignored, not an
  error. This lets plugins ship ahead of pharos catching up to a
  new capability, or pharos ship ahead of plugins.

**Bug report routing** documented in `doc/CONTRIBUTING.md`:

- Protocol ambiguity or apparent spec bug → issue on pharos repo.
- Plugin misbehaves in your editor → issue on plugin's repo.
- Pharos crashes while talking to a plugin → issue on pharos repo
  with logs; cross-link if the plugin appears to be the trigger.

Plugin READMEs link back to pharos for protocol questions; pharos
docs link out to known plugin repos for editor-specific issues. No
expectation that the pharos team triages issues in plugin repos
they do not maintain.

**Communication.** GitHub Discussions on the pharos repo serves as
the protocol-design forum. No Discord or Slack required initially —
spinning one up is cheap to defer until ecosystem activity warrants
it. Release announcements include a "Plugin compatibility" section
noting which listed plugins have been verified against the new
release.

This governance model leans on the conformance tester as the
quality gate. Curation by maintainer review is minimal — if a
plugin passes the test and has a maintainer answering issues, it
lists. The protocol becomes the contract; the test makes the
contract executable.

### Probe and fallback

The startup probe stays as ADR-003 specifies: bridge port from
`~/.config/pharos/bridge-port` or `PHAROS_BRIDGE_PORT`, GET to
`/healthz`, check protocol version. Headless mode is the default; the
binary is happy without an editor and only opts into bridge mode when
the probe succeeds.

WebSocket upgrade happens after the probe succeeds. If the handshake
fails (version mismatch, plugin refuses, transport error), pharos
logs a warning and continues in disk-only mode.

### What this ADR does not do

- It does **not** ship LSP request offload to the editor. Pharos
  spawns its own LSPs. Always.
- It does **not** introduce a transport variant in the LSP pool. The
  pool's interface to LSPs is unchanged.
- It does **not** require any editor to be running for pharos to
  work. Disk + stderr remain first-class.
- It does **not** ship all five tiers in one milestone. Tier 1 first;
  others incremental.
- It does **not** add bundled LSP installers (separate concern,
  separate ADR if revisited).

## Consequences

**Wins:**

- The headline win — unsaved buffer fidelity — is achievable while
  preserving every BEAM-side guarantee from ADR-013 / ADR-017.
- Tiers 2–5 give pharos UX capabilities (focus context, diff-preview,
  diagnostics surfacing, progress) that no listed competitor offers
  in their LSP backend. Serena offers comparable features only via
  its paid JetBrains plugin, not via LSP.
- Editor-side complexity stays small and bounded. Each plugin is
  ~150–500 LOC. Authors can port without learning Erlang, BEAM, or
  pharos internals.
- The protocol is portable from day one. New editor support is a
  plugin contribution, not a pharos core change.
- Headless story stays intact. CI, headless agents, web-based MCP
  clients see no behavior change.

**Costs:**

- The bridge protocol is now a multi-editor public contract.
  Versioning, deprecation, capability negotiation become real
  ongoing concerns. ADR-003 hinted at this for one editor; this
  ADR amplifies it.
- Reference VSCode plugin must ship alongside the binary for the
  bridge to demo at all. That work is real.
- Display callbacks (`editor/showDiff` etc.) introduce pharos →
  editor request/response semantics over the same WebSocket. Cancel
  propagation needs to be re-examined (ADR-016) so that an editor
  ignoring a `showDiff` callback does not stall an MCP tool call
  indefinitely.
- Each new tier adds surface that plugins must implement (or
  explicitly opt out of). Capability negotiation must make this
  honest — a Neovim plugin shipping only Tier 1 should still be
  useful; pharos should not require all tiers from every plugin.
- Plugin governance has ongoing overhead even with the
  conformance-test-as-quality-gate model: the pharos team owns the
  spec, the test, the registry, the scaffolding, and the
  reference plugins. Each protocol bump means updating the test
  and the reference implementations before community plugins can
  follow. Cost is bounded but real.

**Living with:**

- Editor-side state pharos consumes is trusted. A malicious or
  buggy plugin could send misleading `didChange` events and confuse
  pharos's LSPs. Mitigation: bridge probes only on localhost,
  WebSocket connections accept localhost-only by default, no
  cross-origin tolerance.
- The protocol's universality means plugins must be portable in
  spirit even when the host editor has shortcuts. Plugin authors
  may be tempted to leak editor-specific concepts (VSCode-style
  URIs, JetBrains-style scopes) into events. Spec must be strict
  about LSP-compatible shapes.
- Two-way auth/handshake is needed before Tier 3 (`showDiff`) ships,
  so that an editor cannot trick pharos into writing to disk via an
  un-prompted accept callback. Tier 1 is one-way and lower risk.

## Alternatives considered

### Editor hosts the LSPs (beixiyo / mode B)

The editor's own `vscode.executeXxxProvider` (or equivalent) becomes
the LSP backend; pharos's MCP server is a thin JSON-RPC wrapper.

Rejected because:

- Concedes BEAM's role as the LSP supervisor. Pharos's identity
  evaporates.
- Headless story dies. No CI, no agent-only use, no Claude Desktop
  without VSCode running.
- All `runtime_*` introspection tools become no-ops for delegated
  languages.
- Editor lock-in: pharos becomes a VSCode (or JetBrains, or Zed)
  plugin in disguise.
- The protocol becomes editor-specific because executeXxxProvider
  surfaces differ between hosts.

### Bridge proxies raw LSP JSON-RPC to an editor-hosted LSP

Cleaner version of "editor hosts the LSPs": the pool's transport
becomes pluggable (subprocess vs editor-proxy), and bridge mode
routes JSON-RPC frames to the editor.

Rejected because:

- Same headless loss and BEAM-role inversion as the previous
  alternative.
- Each editor must expose raw LSP frames over its plugin API.
  VSCode does not do this directly without significant plumbing
  (its LSP is wrapped inside `vscode.LanguageClient` etc).
  Beixiyo works around this with a single `execute_lsp` dispatcher
  exposed as MCP — not raw LSP.

### Disk-only forever, no bridge

Drop the bridge work entirely. Ship pharos as a pure headless tool.

Rejected because:

- ADR-003 already commits to the hybrid. Reverting would lose the
  unsaved-buffer story, which is the visible correctness gap when
  a human is mid-edit and asks an LLM for diagnostics.
- The diff-preview UX (Tier 3) is the natural answer to "how does
  an LLM safely apply a multi-file refactor without surprising the
  user?" Disk-only mode forces fully autonomous writes or rejects
  the refactor, neither great.

### VSCode-only protocol

Design the protocol around VSCode's APIs (URI shapes, scope concepts,
extension manifest). Other editors port "if interested."

Rejected because:

- Six months of ADR-003's "someone could port it" footnote shows
  this is a soft commitment that does not ship. A protocol designed
  for one editor will not be ported by anyone else.
- LSP-compatible shapes (URI, Position, Range, Diagnostic) are
  already universal. Designing around them costs nothing and gains
  portability.

## Implementation sketch

Tier 1 (mandatory before any tier ships):

- Flesh out `src/pharos/bridge/client.gleam` from stub. WebSocket
  client + JSON encode/decode + handshake.
- Add `src/pharos/bridge/server.gleam` if pharos is the listener
  (TBD: which side binds the port — protocol decision).
- Wire `editor/didOpen` etc. to the LSP pool via the existing
  `proc.send_notification` paths used for synthetic `didOpen` today.
- Update `bridge/buffer.gleam` so reads consult the bridge cache
  before falling back to disk.
- VSCode plugin: implement WebSocket client, listen to
  `vscode.workspace.onDidOpenTextDocument` etc., forward to pharos.
- Bridge protocol spec: write `doc/bridge-protocol.md` v1 covering
  Tier 1 messages, handshake, version negotiation.

Tier 2 (focus tool):

- New MCP tool `editor_focus`. Returns latest cached focus state
  from `editor/focus` events. Errors if bridge is not active.

Tier 3 (diff-preview):

- Extend `apply_workspace_edit` to optionally call `editor/showDiff`
  if the bridge supports it. New tool argument
  `preview_in_editor: bool = false`. Defaults off; LLM opts in.
- Cancel propagation: an editor not responding within a timeout
  causes the MCP call to fail with `BridgeTimeout`, not hang.

Tiers 4 & 5 (diagnostics + progress):

- Subscribe to LSP's `publishDiagnostics` notifications, forward to
  bridge if active.
- LSP `$/progress` events: bridge forwards to `editor/progress*`.

Governance scaffolding (parallel track to Tier 1):

- Write `doc/bridge-protocol.md` v1 (covered above as part of
  Tier 1 spec work).
- Author `bin/test-plugin-conformance.py` (or equivalent). Connects
  to a running plugin, runs canned scenarios per tier, reports
  PASS/FAIL per message type.
- Stand up `doc/plugins.md` registry with reference plugins listed
  and an empty community section.
- Decide whether `pharos init-plugin <editor>` subcommand is worth
  shipping in v1, or whether a `pharos-plugin-starter` repo is
  sufficient for the early ecosystem.
- Document bug-routing convention in `doc/CONTRIBUTING.md`.

## References

- ADR-001 (Gleam) — extensions are TypeScript / Lua / Kotlin / etc.,
  not Gleam. ADR-001 governs pharos source language; plugin source
  language is up to plugin authors.
- ADR-003 (standalone + buffer-state booster) — this ADR extends 003
  from a one-editor footnote to a multi-editor protocol; 003 is not
  superseded, only widened.
- ADR-007 (two-repo split) — extends naturally to N-repo plugin
  split. Reference VSCode plugin stays in the existing companion
  repo; other plugins live wherever their authors maintain them.
- ADR-013 (supervisor tree) — preserved in full; bridge does not
  alter LSP supervision.
- ADR-016 (cancel propagation) — extended to cover bridge display
  callbacks, which are new request/response pairs over the same
  transport.
- ADR-017 / ADR-017a (supervision tree wiring, lsp_proc) —
  unchanged.
- ADR-026 (symbol layer) — bridge does not alter symbol-handle
  semantics. `containing_symbol`, `find_symbol`, `edit_at_symbol`
  work identically whether file content comes from disk or bridge.
- beixiyo/vsc-lsp-mcp — the design this ADR explicitly rejects as a
  blueprint for pharos's bridge. Useful as a feature reference for
  what an editor-as-host model gets right (jdt:// resolution via
  registered handlers, focus state) and what it gets wrong (LSP
  lifecycle delegated, headless story lost).
