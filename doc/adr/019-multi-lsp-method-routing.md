# 019. Multi-LSP method routing per language

**Status:** Proposed
**Date:** 2026-05-06

## Context

Today every language id maps to exactly one LSP server in
`default_registry/0` (`src/pharos/lsp/languages.gleam`). The pool spawns
one worker per `(language, workspace)` pair, and every LSP method
(hover, formatting, diagnostic, codeAction, …) is dispatched to that
single worker.

This was correct while the registry shipped one capable server per
language: rust-analyzer for Rust, gopls for Go,
typescript-language-server for TypeScript, pyright-langserver for
Python. The M9.5 dogfood surfaced the assumption's failure mode: pyright
does NOT implement `textDocument/formatting` (returns `-32601`). The
Python ecosystem expects formatting from a separate tool — black, yapf,
or **ruff**. Ruff in particular ships an LSP server (`ruff server`)
since 2024 that speaks the same JSON-RPC2 framing pharos already
handles, with first-class formatting + linting + import-sort + quick-fix
code actions, but no type inference and no hover docs.

Neither pyright nor ruff covers the full python LSP surface alone.
Editors like VS Code resolve this by running both, dispatching each
method to whichever server advertises the matching server capability.
Pharos cannot do this today: a single `LanguageConfig` carries a single
`command`, so pool can only spawn one worker per language.

The same shape applies to other languages once we look. Some examples:
- Go has gopls (most things) plus `goimports` / `gofumpt` for formatting
  preferences, plus `golangci-lint-langserver` for linting.
- Rust has rust-analyzer (most things) plus `rustfmt` (formatting) and
  external linters via clippy that some users front via a separate
  daemon.
- TypeScript has typescript-language-server (most things) plus
  `eslint-language-server` for lint diagnostics + lint quick-fixes.

Three design forces are in play:

1. **Coverage.** Pharos's value proposition is "every LSP method
   reliably for every supported language." A method that returns
   `-32601` from the configured server breaks that contract.
2. **Composability.** Adding ruff for Python should not regress
   pyright's hover/types/completion. The two complement, not replace.
3. **Resource discipline.** Each LSP is a subprocess holding its own
   in-memory index. Doubling the worker count per workspace doubles
   the steady-state memory and the cold-start time. We need workers
   only for the methods a language actually multiplexes.

Rejected upfront:

- **Replace pyright with ruff.** Loses type-aware features
  (hover signatures, goto-type-definition, completion priorities).
  Architecturally wrong — ruff does not aim to be a type-checker.
- **Shell out to `ruff format -` for python `.py` files only.** Special
  cases the abstraction. Doesn't compose to other languages
  (eslint-language-server is also LSP, not CLI). Solves one symptom,
  duplicates the framing+process-management code we already own.

## Decision

`LanguageConfig` becomes a list of `ServerConfig` entries, each with a
declared method scope. The pool spawns one worker per
`(workspace, server_id)`; tools dispatch by method to the server whose
scope covers it. When two servers claim the same method, the registry
declares a routing strategy (`primary`, `merge`, or `fan_out`). The
default strategy is `primary` — first server in the list whose scope
covers the method wins.

New shape:

```gleam
pub type LanguageConfig {
  LanguageConfig(
    id: String,
    file_extensions: List(String),
    root_markers: List(String),
    root_promotion: RootPromotion,
    servers: List(ServerConfig),
  )
}

pub type ServerConfig {
  ServerConfig(
    id: String,                   // unique within the language
    command: String,
    args: List(String),
    initialization_options: Json,
    workspace_configuration: Option(Dict(String, Json)),
    methods: MethodScope,
    diagnostics_mode: DiagnosticsMode,
    readiness_token: Option(String),
  )
}

pub type MethodScope {
  /// Server handles every textDocument.* and workspace.* method.
  /// Used for the "main" LSP per language.
  All
  /// Server handles only the listed method names. Used to layer a
  /// formatter or linter on top of the main server.
  Only(methods: List(String))
}

pub type RouteStrategy {
  /// Send the request to the first server whose scope covers it.
  /// Use for hover, goto_*, signature_help — methods that have a
  /// single canonical answer.
  Primary
  /// Send to every server whose scope covers it; concatenate
  /// `diagnostics` arrays in the response. Use for diagnostics
  /// (pyright + ruff both produce items).
  Merge
  /// Send to every server whose scope covers it; concatenate
  /// `actions` arrays in the response. Use for code_actions
  /// (rust-analyzer + clippy both contribute fixes).
  FanOut
}
```

Pool's keying changes from `(language, workspace)` to
`(workspace, server_id)`. Each `ServerConfig` is supervised
independently under `pharos_lsp_dyn_sup`, so a ruff crash does not
restart pyright. The ETS bridge (`pharos_lsp_proc_subjects`) keys
shift to match.

Tool dispatch path:

1. Resolve `LanguageConfig` for the file URI (existing).
2. For the requested LSP method (e.g. `textDocument/formatting`),
   walk `config.servers` and pick the routes — list of servers whose
   `methods` scope covers the method.
3. Look up `RouteStrategy` for the method (defaulted via a small
   per-method table; configurable via the override file).
4. Dispatch:
   - `Primary` — call the first matched server; return its result.
   - `Merge` — call all matched servers concurrently; merge result
     arrays. The response shape merge-rules live in a per-method
     mergeable function.
   - `FanOut` — same as Merge but for code-action-shaped responses.

Bundled python defaults become:

```
LanguageConfig(
  id: "python",
  file_extensions: [".py", ".pyi"],
  ...,
  servers: [
    ServerConfig(
      id: "pyright",
      command: "pyright-langserver",
      methods: All,
      diagnostics_mode: Pull,
      ...
    ),
    ServerConfig(
      id: "ruff",
      command: "ruff",
      args: ["server"],
      methods: Only([
        "textDocument/formatting",
        "textDocument/codeAction",
        "textDocument/diagnostic",
      ]),
      diagnostics_mode: Pull,
      ...
    ),
  ],
)
```

`textDocument/formatting` routes to ruff (pyright's `methods: All` does
not "win" because routing is method-aware: ruff is the first server
whose scope MATCHES that specific method most narrowly, and pyright
returns `-32601` so the implementation prefers a narrower scope match
when present).

Actually: simpler routing rule — **the first server in the list
declaring the method via `Only` wins, otherwise the first server with
`All` wins, otherwise the method is unsupported.** That gives the
override file a clear way to layer on top of `All` defaults:

```
[python.servers.ruff]
command = "ruff"
args = ["server"]
methods = ["textDocument/formatting", "textDocument/codeAction"]
```

…appended to the defaults gives ruff priority for those methods and
leaves everything else with pyright.

For python diagnostics specifically, the tool layer uses `Merge`:
both pyright and ruff produce items, and the LLM benefits from seeing
both type errors and lint errors in a single response.

Default strategy table (initial, configurable):

| Method                          | Strategy |
|---------------------------------|----------|
| `textDocument/hover`            | Primary  |
| `textDocument/definition`       | Primary  |
| `textDocument/typeDefinition`   | Primary  |
| `textDocument/implementation`   | Primary  |
| `textDocument/references`       | Primary  |
| `textDocument/documentSymbol`   | Primary  |
| `workspace/symbol`              | Primary  |
| `textDocument/signatureHelp`    | Primary  |
| `textDocument/formatting`       | Primary  |
| `textDocument/rename`           | Primary  |
| `textDocument/codeAction`       | FanOut   |
| `textDocument/diagnostic`       | Merge    |
| `textDocument/publishDiagnostics` (push) | Merge per source |
| `callHierarchy/*`               | Primary  |

## Consequences

**Easier:**
- Python coverage becomes complete: pyright handles types/hover/goto;
  ruff handles formatting/lint/quick-fixes/import-sort. Both
  contribute diagnostics. No `-32601` pothole.
- The same architecture covers TypeScript + eslint-language-server
  layering, rust-analyzer + a clippy daemon, etc., with a config-only
  change.
- Custom registries gain a real expressive surface: layer a
  workspace-specific linter without forking pharos.
- Code action UX improves: rust-analyzer's "extract function" lives
  alongside clippy's autofixes in one response.

**Harder:**
- Pool keying changes from `(language, workspace)` to
  `(workspace, server_id)`. Existing call sites
  (`pool.get`, `pool.evict`, `runtime_kill_lsp`, ETS bridge keys) all
  update. The MCP `runtime_kill_lsp` argument shape may want to
  accept `server_id` (defaulting to all servers for the language for
  backwards compat).
- Pool spawns more workers in steady state. Memory cost is roughly
  additive per server. ruff's resident set is tiny (~30MB) so pyright
  + ruff for python is a modest delta. Rust-analyzer + a hypothetical
  clippy daemon would be bigger.
- Tool result shape changes for `Merge` / `FanOut`: tool layer must
  decode N responses, merge, and re-encode. Failure modes multiply
  (one server times out while the other succeeds → partial result).
- Server-request fan-in (`workspace/configuration`,
  `window/workDoneProgress/create`) needs explicit per-server scoping.
  Today the pool routes server-requests via the proc that owns the
  client. Multi-server expands the routing fabric.

**Live with:**
- Configuration complexity rises. The override-file format must
  evolve to express server lists per language. A migration story
  for users with existing single-server overrides is required.
- Diagnostic merge ordering: when two servers both produce
  `Type 'string' is not assignable...` at the same range (because
  both pyright and ruff happen to flag it), the LLM sees duplicate
  entries unless we de-dupe. Out of scope for the first cut; mention
  in the tool description.
- Cold-start time: spawning two LSPs on first request to a python
  workspace doubles cold-start latency. Workers are still cached, so
  steady-state is unaffected. Acceptable.
- The shape change is breaking for anyone with a `PHAROS_LSP_REGISTRY`
  override file. Migration helper: pharos at boot detects an old-format
  override (single `command` field), promotes it implicitly to a one-
  element `servers` list, logs a warning telling the user to migrate.

## Alternatives considered

- **Method-only routing without a list of servers.** Single language id
  with a flat method→command map. Rejected because spawn discipline
  ties to ServerConfig identity (`workspace_configuration`,
  `initialization_options`, `readiness_token` are server-scoped, not
  method-scoped). The list-of-servers shape is the natural unit.
- **Sidecars driven via shell-out for the gap methods.** ~2 hours to
  ship for python formatting only, but doesn't compose to lint
  diagnostics or eslint and breaks the LSP abstraction. Rejected.
- **Pool-per-method instead of pool-per-server.** Tempting but a
  given server (e.g. pyright) holds methods together with shared in-
  memory state — fanning out single methods to fresh procs would
  multiply cold-starts and lose the shared cache. Pool keys on
  server identity.
- **Wait for upstream ruff to add type-checking ("ty" / Astral
  type-checker).** Plausible 2026 path. We will revisit; this ADR
  ships independently because the architecture is broader than just
  python.
