<p align="center">
  <img src="https://raw.githubusercontent.com/LoganBresnahan/pharos-mcp/main/assets/pharos.png" width="320" alt="pharos">
</p>

# pharos

**Headless LSP-MCP bridge for AI agents.** Pharos hands the same language
servers your IDE uses (rust-analyzer, gopls, tsserver, pyright, jdtls,
and 18 more) to any MCP-aware agent — Claude Code, Cursor, ChatGPT
Desktop, or your own SDK app — so the model can ask about your codebase
with type-aware navigation instead of grepping.

## At a glance — Phase 5 v1.0 final benchmark

5 languages × 70 questions × 2 arms (grep/Read baseline vs. pharos tool
surface) × 3 trials = **1986 cells, 8 hours wall**, run on DeepSeek-v4-pro
with thinking enabled. Both arms see the same questions; the only
variable is whether the agent has pharos tools available.

| Lang | Acc grep → pharos | Δ pp | Wall Δ | Cost Δ | LSP |
|------|------------------:|-----:|-------:|-------:|-----|
| python | 78 % → 85 % | **+7** | -40 % | -14 % | pyright + ruff |
| rust | 62 % → 91 % | **+29** | -45 % | 0 % | rust-analyzer |
| typescript | 63 % → 88 % | **+25** | -46 % | -33 % | typescript-language-server |
| go | 74 % → 90 % | **+16** | -35 % | -7 % | gopls |
| java | 73 % → 91 % | **+18** | -40 % | -25 % | jdtls |

**Average across the four mid-difficulty langs (excluding python, which
sits near accuracy ceiling under both arms): +22 pp accuracy, -42 %
wall time, -17 % cost.**

Methodology in 30 seconds: questions and ground truth are
*machine-generated* by querying the LSP authoritatively against random
symbols sampled from the workspace; both arms attempt the same
questions; scoring is mechanical (no human judgment). Full
methodology, per-question data, and per-kind drill-downs at
[Benchmark methodology](#benchmark-methodology).

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Language support](#language-support)
- [Tools](#tools)
- [CLI reference](#cli-reference)
- [Configuration](#configuration)
- [Benchmark methodology](#benchmark-methodology)
- [Tool reference](#tool-reference)
- [More languages](#more-languages) (+ [adding your own](#adding-your-own-language))
- [Troubleshooting](#troubleshooting)
- [Architecture](#architecture)
- [Development](#development)
- [License](#license)

## Install

Pharos is a single self-contained binary (Erlang runtime included via
[Burrito](https://github.com/burrito-elixir/burrito)). Three channels —
all produce the same binary; pick whichever fits your workflow.

### 1. npm (cross-platform — recommended for MCP clients)

```bash
npm install -g pharos-mcp
```

The post-install script copies the platform-correct binary into your
npm prefix and prints the resolved path. Add to your MCP host's
config:

```jsonc
{
  "mcpServers": {
    "pharos": { "command": "pharos" }
  }
}
```

### 2. Direct download from GitHub Releases

Grab the binary matching your platform from
[github.com/LoganBresnahan/pharos-mcp/releases/latest](https://github.com/LoganBresnahan/pharos-mcp/releases/latest):

| Asset | Platform |
|-------|----------|
| `pharos_linux_x64` | Linux x86-64 |
| `pharos_linux_arm64` | Linux aarch64 |
| `pharos_darwin_x64` | macOS Intel |
| `pharos_darwin_arm64` | macOS Apple Silicon |
| `pharos_win_x64.exe` | Windows x86-64 |

```bash
curl -L \
  https://github.com/LoganBresnahan/pharos-mcp/releases/latest/download/pharos_linux_x64 \
  -o ~/.local/bin/pharos
chmod +x ~/.local/bin/pharos
```

Or via the GitHub CLI:

```bash
gh release download v0.1.0 --repo LoganBresnahan/pharos-mcp -p 'pharos_linux_x64'
chmod +x pharos_linux_x64
```

> **Heads up:** GitHub Release assets are uploaded without an
> executable bit, so you must `chmod +x` the downloaded binary before
> running it. The npm install path handles this automatically.

### 3. Build from source

Requires Erlang/OTP 28, Elixir 1.19, Gleam 1.16+, Zig 0.15.2.
See [Development](#development).

### First-run cold extract

The first invocation extracts the Burrito payload to
`~/.local/share/.burrito/pharos_*/` (~80 MB, ~3-5 seconds).
Subsequent boots are <100 ms because the extract is cached. Run
`pharos --doctor` once after install to warm both the Burrito cache
and verify every LSP binary resolves on PATH.

[↑ top](#pharos)

## Quick start

Two-step setup:

**1. Install at least one LSP** for a language you'll use. See
[Language support](#language-support) for the full table; the
shortest paths:

```bash
rustup component add rust-analyzer          # Rust
go install golang.org/x/tools/gopls@latest  # Go
npm install -g typescript-language-server typescript  # TypeScript/JS
npm install -g pyright                      # Python
```

**2. Point your MCP client at pharos.**

Claude Code (`~/.claude.json` or per-project `.mcp.json`):

```jsonc
{
  "mcpServers": {
    "pharos": {
      "command": "pharos"
    }
  }
}
```

Cursor (per-server config UI): command `pharos`, args `[]`.

ChatGPT Desktop / Claude Desktop: same shape via their JSON config.

Restart the MCP client. The model now has tools named
`mcp__pharos__hover`, `mcp__pharos__find_references`, etc.

**Optional — warm the LSPs once on a per-project basis:**

```bash
cd /path/to/your/project
pharos warm --all       # detects languages from workspace markers, pre-indexes each
pharos warm rust go     # or name them explicitly — one or more languages
```

This makes the first MCP tool call ~3-5 s instead of ~30-60 s for
heavy LSPs like rust-analyzer or jdtls by populating their on-disk
indexes ahead of time.

[↑ top](#pharos)

## How it works

Pharos is a long-lived BEAM-VM process that the MCP client spawns as
a child for the duration of a session.

**Lifecycle of one LSP request from agent to language server:**

1. Agent calls an MCP tool over stdio: `find_references(uri, line, character)`.
2. Pharos detects the language from the file URI (extension → registry
   lookup) and looks up the configured LSP for that language.
3. If the LSP isn't already in pharos's pool for this `(language,
   workspace)`, pharos spawns it as a subprocess and runs the LSP
   `initialize` handshake plus a readiness probe per
   [ADR-024](doc/adr/024-lsp-readiness-gate.md). Cold start is
   ~3-60 s depending on the LSP (gopls fast, jdtls/metals slow).
4. Pharos forwards the request as the corresponding LSP method
   (`textDocument/references`).
5. LSP responds; pharos shapes the response into the MCP tool's
   return schema and ships it back to the agent.

**The LSP stays cached** in pharos's pool for the lifetime of the
pharos process — every subsequent tool call against the same
`(language, workspace)` reuses it. The pool also handles
multi-language workspaces (one pyright + one rust-analyzer running
side by side for the same project tree) and multi-server languages
(python uses pyright AND ruff with method routing — see
[ADR-019](doc/adr/019-lsp-multi-server-routing.md)).

**No background daemon.** Pharos lives only as long as the MCP
client that spawned it. When the client closes its end of the stdio
pipe pharos drains in-flight requests, sends `shutdown`/`exit` to
each cached LSP, removes its instance tracking dir (see
[Troubleshooting](#troubleshooting)), and halts.

[↑ top](#pharos)

## Language support

Pharos does not bundle LSPs — you install them; pharos resolves
them via `PATH` at runtime and surfaces a clear error if a binary is
missing. If you keep an LSP outside `PATH` or want to pin a specific
version, point pharos at the absolute path via `pharos.toml`:

```toml
[languages.rust]
command = "/opt/custom-rust-analyzer"
```

See [Adding your own language](#adding-your-own-language) for the
full per-language schema. Run `pharos --doctor` after install to
verify every resolved binary.

The five benchmarked in Phase 5 — follow the LSP's own install
instructions:

| Language | Server(s) |
|----------|-----------|
| Rust | [rust-analyzer](https://github.com/rust-lang/rust-analyzer) |
| Go | [gopls](https://github.com/golang/tools/tree/master/gopls) |
| TypeScript / JavaScript | [typescript-language-server](https://github.com/typescript-language-server/typescript-language-server) |
| Python | [pyright](https://github.com/microsoft/pyright) (types/hover/goto) **+** [ruff](https://github.com/astral-sh/ruff) (format/lint/fixes) |
| Java | [jdtls](https://github.com/eclipse-jdtls/eclipse.jdt.ls) (Eclipse JDT) — JDK 17+ required |

[More languages ↓](#more-languages) — also wired and ready:
C/C++, Elixir, Erlang, Gleam, Scala, Clojure, Haskell, Ruby, Lua,
Bash, Zig, Perl, HTML/CSS/JSON, YAML, Markdown, Terraform.

**Per-tool support varies by LSP** — not every LSP implements every
LSP method. See
[doc/lsp-capability-matrix.md](doc/lsp-capability-matrix.md) for the
full 23-language × 16-tool grid (regenerated from each dogfood pass).

**Don't see your language?** Any language with an LSP-compliant server
can be wired in via `pharos.toml` — full worked example at
[Adding your own language ↓](#adding-your-own-language). 23 languages
ship bundled today; the registry is just a default and is fully
overridable.

Multi-server routing is supported for languages that need it
([Python](#multi-server-languages-adr-019); see
[ADR-019](doc/adr/019-lsp-multi-server-routing.md)).

[↑ top](#pharos)

## Tools

53 MCP tools across 5 categories + 2 filter presets. The 5
categories (read, write, memory, debug, raw) partition every tool
exactly once. The 2 presets (`default`, `all`) are filter aliases
that aggregate across categories — what your MCP host sees when you
set e.g. `tools = ["default", "raw", "runtime_kill_lsp"]` (preset +
category + literal tool name — mix freely) or `tools = ["all"]` in
[pharos.toml](#configuration); full per-tool detail at
[Tool reference](#tool-reference).

| Category | Count | Examples | When you'd toggle off |
|----------|------:|----------|------------------------|
| **default** *(preset)* | 37 | Aggregates `read` + `write` + `memory` plus 5 runtime essentials the LLM uses for tool-error recovery (`echo`, `runtime_set_tool_timeout`, `runtime_effective_tool_config`, `runtime_language_config`, `runtime_server_capabilities`) | This is the shipping preset. Replace with an explicit list (e.g. `tools = ["read"]`) for tighter surfaces. |
| **read** | 22 | `hover`, `goto_definition`, `find_references`, `find_referencing_symbols`, `find_symbol`, `document_symbols`, `workspace_symbols`, `containing_symbol`, `call_hierarchy_*`, `type_hierarchy_*`, `signature_help`, `get_diagnostics`, `inlay_hints`, `semantic_tokens`, `fetch_uri_contents` | Never — these are the core LSP queries that make pharos worth running. |
| **write** | 5 | `rename_preview`, `format_document`, `code_actions`, `apply_workspace_edit`, `edit_at_symbol` | When the agent should propose edits without authority to apply them. Set `tools = ["read"]` for query-only mode. |
| **memory** | 5 | `memory_save`, `memory_get`, `memory_list`, `memory_prune`, `memory_audit` | Project-memory store ([ADR-027](doc/adr/027-project-memory-tools.md)) — toggle off if the agent doesn't need persistent notes scoped to the workspace. |
| **debug** | 20 | `runtime_processes`, `runtime_supervision_tree`, `runtime_log_tail`, `runtime_kill_lsp`, `runtime_lsp_state`, `runtime_pool_recon`, `runtime_trace_lsp`, `runtime_memory`, `echo`, `runtime_set_tool_timeout`, [full list ↓](#debug-20-tools) | Off by default beyond the 5 essentials. Opt in (`tools = ["default", "debug"]`) for dogfood / power-user installs where pharos's BEAM internals should be reachable. |
| **raw** | 1 | `lsp_request_raw` | Off by default. Opt in only when the agent legitimately needs LSP methods pharos hasn't wrapped natively. |
| **all** *(preset)* | 53 | All tools available | The "expose everything" preset (`tools = ["all"]`) — dogfood / power-user installs that want both `debug` and `raw` exposed. |

[↑ top](#pharos)

## CLI reference

Pharos has no runtime-configuration CLI flags — every knob lives in
`pharos.toml` or `PHAROS_*` env vars. Flags are operational meta
commands.

| Command | Purpose |
|---------|---------|
| `pharos` | MCP server (default — what your client invokes). Reads JSON-RPC from stdin, writes responses to stdout, logs to stderr. |
| `pharos warm <lang>...` | Pre-warm the named languages' LSPs against cwd. Spawns each LSP, runs the readiness gate, exits. Subsequent MCP-server runs in the same workspace boot ~10-20× faster because the LSPs' on-disk indexes are now hot. |
| `pharos warm --all` | Same as above but enumerates every language pharos knows about and warms whichever ones have project markers in cwd. Languages without markers (e.g. `Cargo.toml` for rust, `go.mod` for go) are skipped with a clear log line. |
| `pharos --doctor` | Self-diagnostic. Resolves config the same way a normal boot does, probes each language server's binary on PATH, reports anything that would break a real run. Doubles as a Burrito-cache warmup. |
| `pharos --cleanup` | List orphan LSP children left behind by prior pharos sessions that exited uncleanly (host crash, SIGKILL, OOM-killer). Dry-run by default — adds nothing destructive without a flag. |
| `pharos --cleanup --yes` | Reap the orphans listed by `--cleanup`: SIGTERM each, wait 5 s, SIGKILL survivors, remove their per-PID tracking directory. |
| `pharos --purge-cache` | Remove the Burrito extract cache (`<user_cache>/burrito_runtime/_/pharos/`). Next run re-extracts (~3-5 s). |
| `pharos --print-default-config` | Print the canonical `pharos.toml` starter with comments. Pipe to `~/.config/pharos/pharos.toml` to begin customising. |
| `pharos --print-language-config <id>` | Print one language's resolved registry entry (after `pharos.toml` overlays). Useful for debugging "why isn't my custom binary path being used?". |
| `pharos --version` / `-V` | Print version and exit. |
| `pharos --help` / `-h` | Print usage and exit. |

### Useful env vars

| Var | What it does | Default |
|-----|--------------|---------|
| `PHAROS_WARM_LANGS` | CSV; pharos pre-warms these languages every boot. Useful in MCP client configs where you want warm-on-every-spawn rather than the one-shot `pharos warm` CLI. | unset (off) |
| `PHAROS_LOG` | RUST_LOG-style filter (`info`, `info,pharos/lsp/pool=debug`). | `info` |
| `PHAROS_LOG_FILE` | Override the per-PID per-timestamp default log file location. | `~/.cache/pharos/log/session-<pid>-<timestamp>.log` |
| `PHAROS_HEARTBEAT_INTERVAL_MS` | Cadence of the idle-heartbeat log line (memory + LSP child count). | `60000` |
| `PHAROS_SHUTDOWN_DRAIN_MS` | How long to wait for in-flight requests before initiating LSP shutdown on SIGTERM/stdin-EOF. | `2000` |
| `PHAROS_CLEANUP_GRACE_MS` | How long `pharos cleanup --yes` waits between SIGTERM and SIGKILL on each orphan. | `5000` |

[↑ top](#pharos)

## Configuration

Pharos reads configuration in this precedence order (later wins):

1. Compiled-in defaults (no config required)
2. `~/.config/pharos/pharos.toml` — global per-user
3. `./.pharos.toml` — per-project; walked up from cwd
4. `PHAROS_*` environment variables — final override

To start customising, dump the canonical TOML with comments:

```bash
mkdir -p ~/.config/pharos
pharos --print-default-config > ~/.config/pharos/pharos.toml
$EDITOR ~/.config/pharos/pharos.toml
```

The full schema lives in [doc/example-pharos.toml](doc/example-pharos.toml).

### Tool filter (`tools = [...]`)

Pick categories or literal tool names. Default: all four categories on.

```toml
tools = ["read"]                       # query-only agent
tools = ["read", "write"]              # full LSP surface
tools = ["read", "runtime_log_tail"]   # category + one extra
tools = ["hover", "goto_definition"]   # fully explicit
```

### Per-tool timeout overrides (`[tool_config.<name>]`)

Every LSP-bound tool accepts an optional `timeout_ms` argument and has
a compile-time default (`30s` for most, `60s` for `find_references`).
Override globally or per-language:

```toml
[tool_config.format_document]
default_timeout_ms = 90000

[tool_config.find_references.java]
default_timeout_ms = 120000     # jdtls workspace-wide refs are slow
```

Resolution order (later wins):
1. Compile-time tool default
2. `[tool_config.<name>] default_timeout_ms` (global per-tool)
3. `[tool_config.<name>.<lang>] default_timeout_ms` (per-tool × per-lang)
4. Per-call `timeout_ms` argument

Recommended starting bumps for heavy LSPs:

| LSP | Tools that benefit | Suggested |
|---|---|---|
| `jdtls` (java) | `type_hierarchy_*`, `find_references`, `format_document` | 90-120 s |
| `metals` (scala) | `workspace_symbols`, `inlay_hints`, `semantic_tokens`, `rename_preview` | 60-90 s |
| `ruby-lsp` | `goto_*`, `call_hierarchy_prepare` | 60 s |
| `perl/PLS` | `find_references`, `rename_preview` | 120-240 s |
| `gopls` (big mod) | `workspace_symbols` | 90 s |
| `rust-analyzer` (monorepo) | `format_document` | 60 s |

When a tool times out the LLM sees `tool timeout: LSP did not respond
in time...` with pointers to the `runtime_set_tool_timeout` and
per-call `timeout_ms` escape hatches — so most tuning ends up happening
in-conversation, not in TOML.

### Multi-server languages (ADR-019)

A few languages route different LSP methods to different servers.
Python is the prominent case:

| Server | Scope | Owns |
|--------|-------|------|
| `pyright` | `methods = "all"` | hover, goto, references, types, signature_help, document_symbols, workspace_symbols |
| `ruff` | `methods = ["textDocument/formatting", "textDocument/codeAction", "textDocument/diagnostic"]` | formatter, lint quick-fixes, import-sort, lint diagnostics |

Routing rule per [ADR-019](doc/adr/019-lsp-multi-server-routing.md):
the first server declaring a method via `Only` wins; otherwise the
first `All`-scope server wins. Methods that produce array-shaped
results (`codeAction`, `diagnostic`) merge across every claiming
server.

Add a third server (e.g. mypy alongside pyright + ruff):

```toml
[[languages.python.servers]]
id = "mypy"
command = "mypy"
args = ["--strict"]
methods = ["textDocument/diagnostic"]
```

[↑ top](#pharos)

## Benchmark methodology

### Run shape

- **Corpora.** One open-source workspace per language. Each picked
  for being moderately complex but small enough to fully index inside
  the WSL2 box used for the run:

  | Language | Repository | What it is |
  |----------|------------|------------|
  | python | [pallets/flask](https://github.com/pallets/flask) | The Flask web framework |
  | rust | [tokio-rs/bytes](https://github.com/tokio-rs/bytes) | Byte-buffer utilities crate (used across the tokio ecosystem) |
  | typescript | [colinhacks/zod](https://github.com/colinhacks/zod) | TypeScript-first schema validation library |
  | go | [prometheus/prometheus](https://github.com/prometheus/prometheus) | The Prometheus monitoring server |
  | java | [spring-projects/spring-petclinic](https://github.com/spring-projects/spring-petclinic) | Reference Spring Boot application |

  Fixtures were cloned in May 2026.
- **Questions.** 60-70 per language, auto-generated by
  `bench/oracle.py` from random sampling of `document_symbols`
  output. No human curation. Seven question kinds spanning the
  navigation surface: `find_definition`, `find_implementation`,
  `references_count`, `symbol_kind`, `hover_first_word`,
  `hover_signature`, `call_hierarchy_in`, `containing_symbol`,
  `collision_resolve`.
- **Arms.** Same question, two tool surfaces:
  - **control** — Bash, Glob, Grep, Read (no pharos).
  - **treatment** — the same set PLUS the full pharos MCP tool surface.
- **Model.** DeepSeek-v4-pro, thinking mode on.
- **Trials.** 3 independent runs per (question, arm); per-arm n =
  base_questions × 3.
- **Run wall time.** 8 hours, 5 languages in parallel (one pharos
  process per language, isolated workspaces).

### Ground truth

Each question's ground truth is computed by `bench/oracle.py` calling
the LSP authoritatively before the run starts. The `references_count`
ground truth for "how many references does `foo` have" comes from
running `textDocument/references` on `foo` and counting. The
`find_definition` ground truth is the URI the LSP returned for
`textDocument/definition`.

This means **the LSP is the oracle for ground truth**, and the
benchmark measures whether an LLM equipped with pharos reaches the
LSP-correct answer more often than an LLM restricted to grep. That's
deliberate: the LSP IS the authoritative source for language
semantics (rust-analyzer knows whether two `fn foo`s are the same
generic instantiation; grep can't), and the hypothesis under test is
exactly that giving the agent access to that authoritative source
helps.

### Scoring

Mechanical, deterministic. No human judgment. Rules per kind in
[bench/score.py](bench/score.py):

| Kind | Rule |
|------|------|
| `references_count` | First integer in answer == ground_truth integer |
| `find_definition` / `find_implementation` | Normalised file path equality |
| `symbol_kind` | Case-insensitive SymbolKind name equality |
| `hover_first_word` | Substring match on first word |
| `hover_signature` | Substring match on type sig |

Rerunning the scorer against the same per-question JSONL yields the
same numbers; the scoring is reproducible.

### Cost — local estimate vs. billed

The per-cell `cost_usd` field is a local estimate using DeepSeek-v4-pro
promo rates (active through 2026-05-31). It underestimates the actual
DeepSeek-billed total by ~4.5× in this run (local sum $11.35 vs. actual
delta ~$50.60). The pricing constants in
[bench/harness_deepseek.py](bench/harness_deepseek.py) may pre-date a
DeepSeek rate change or there's a cache-hit vs cache-miss classification
gap; per-arm relative deltas are unaffected (both arms use the same
constants). v1.1 reconciliation item.

### Full data

- [`bench/results/v1.0-final/phase5-final-report/summary.md`](bench/results/v1.0-final/phase5-final-report/summary.md) — headline matrix + percentiles + per-kind drill-down
- [`bench/results/v1.0-final/phase5-final-report/per-question.md`](bench/results/v1.0-final/phase5-final-report/per-question.md) — every cell (1986 rows)
- [`bench/results/v1.0-final/phase5-final-report/pairs.csv`](bench/results/v1.0-final/phase5-final-report/pairs.csv) — joined control/treatment per (qid, trial); has `flip_c_wrong_t_right` and `flip_c_right_t_wrong` columns for fine-grained diff analysis

### What this bench does NOT measure

- **Code-writing tasks** (refactors, new feature implementation).
  Different methodology needed.
- **Agent reasoning quality.** A bad LLM with a good tool surface
  can still get the right answer mechanically. The control arm
  partially baselines this.
- **Production traffic patterns.** Phase 5 is synthetic by design —
  random symbol sampling, evenly distributed across kinds. Real
  agent workloads cluster heavily around a few question types.

[↑ top](#pharos)

## Tool reference

Brief per-tool summaries below. All tools accept `timeout_ms` as an
optional argument; defaults are listed in
[Configuration](#per-tool-timeout-overrides-tool_configname).

### read (22 tools)

| Tool | What it returns | Backed by |
|------|-----------------|-----------|
| `hover` | Type info + docs for the symbol at `(uri, line, character)` | `textDocument/hover` |
| `goto_definition` | URI + range of the symbol's definition | `textDocument/definition` |
| `goto_type_definition` | URI + range of the symbol's type | `textDocument/typeDefinition` |
| `goto_implementation` | URI + range list of implementations (trait impls, abstract overrides, etc.) | `textDocument/implementation` |
| `find_references` | URI + range list of every reference site | `textDocument/references` |
| `find_referencing_symbols` | One step deeper than `find_references` — returns the *containing symbol* of each reference (function name, class, etc.) | composed: `references` → `documentSymbol` per uri |
| `find_symbol` | Locate a symbol by name + optional kind across the workspace | `workspace/symbol` |
| `document_symbols` | Outline of every symbol in one file (hierarchical) | `textDocument/documentSymbol` |
| `workspace_symbols` | Fuzzy-match symbol name across the workspace | `workspace/symbol` |
| `get_symbols_overview` | Top-level outline only (no nesting) — cheaper than `document_symbols` for "what's in this file" probes | composed |
| `containing_symbol` | The innermost named symbol covering a given line | composed: `documentSymbol` → tree walk |
| `signature_help` | Function signature + active parameter for the call at cursor | `textDocument/signatureHelp` |
| `call_hierarchy_prepare` | Anchor a call-hierarchy query at a symbol | `textDocument/prepareCallHierarchy` |
| `call_hierarchy_incoming_calls` | Who calls this symbol | `callHierarchy/incomingCalls` |
| `call_hierarchy_outgoing_calls` | What this symbol calls | `callHierarchy/outgoingCalls` |
| `type_hierarchy_prepare` | Anchor a type-hierarchy query | `textDocument/prepareTypeHierarchy` |
| `type_hierarchy_supertypes` | Parent classes/traits | `typeHierarchy/supertypes` |
| `type_hierarchy_subtypes` | Child classes/implementations | `typeHierarchy/subtypes` |
| `get_diagnostics` | Errors/warnings for one file or workspace-wide | `textDocument/diagnostic` + cached `publishDiagnostics` |
| `inlay_hints` | Inline type / parameter hints in a range | `textDocument/inlayHint` |
| `semantic_tokens` | Token-level semantic classifications for syntax-aware operations | `textDocument/semanticTokens/*` |
| `fetch_uri_contents` | Read raw text behind a custom URI scheme (e.g. `jdt://` for jdtls class-file contents) — see [ADR-029](doc/adr/029-custom-uri-schemes.md) | scheme-dependent |

### write (5 tools)

| Tool | What it does | Authority model |
|------|--------------|------------------|
| `rename_preview` | Compute a `WorkspaceEdit` for renaming a symbol — does NOT apply | Caller (LLM) inspects + applies via `apply_workspace_edit` |
| `format_document` | Compute a `WorkspaceEdit` from the LSP formatter — does NOT apply | same |
| `code_actions` | Enumerate available quick-fixes / refactors at a position, each as a `WorkspaceEdit` | same |
| `edit_at_symbol` | Replace the source range of a named symbol with new text — convenience for "rewrite `fn foo` body" style edits | Returns a `WorkspaceEdit`; caller applies |
| `apply_workspace_edit` | Write a `WorkspaceEdit` to disk. `dry_run=true` by default (returns the diff); flip to `false` to actually write. Per-file atomic writes. | This is the only tool that mutates source files. |

### memory (5 tools)

Per-project key-value memory store ([ADR-027](doc/adr/027-project-memory-tools.md)).
Files live at `.pharos/memories/` in the workspace root; safe to commit
to version control if the project's policy allows. Useful for agents
that benefit from durable notes across sessions ("the auth tests use
fixture X", "this module is being refactored").

| Tool | What it does |
|------|--------------|
| `memory_save` | Write or update a memory entry by key |
| `memory_get` | Read one memory entry |
| `memory_list` | List all memory entries (paginated) |
| `memory_prune` | Delete one or more entries by key |
| `memory_audit` | Surface entries that have not been read in N days, suggest review |

### debug (20 tools)

BEAM / pharos introspection. The first 5 ship under the `default`
preset because the read/write surface points at them in tool-error
recovery recipes; the remaining 15 are opt-in via `tools = ["default",
"debug"]` or `tools = ["all"]`.

| Tool | What it does | Exposed under |
|------|--------------|---------------|
| `echo` | Round-trip an MCP message — smoke test for the transport before exercising any LSP-bound tool | `default` |
| `runtime_set_tool_timeout` | Bump or lower one tool's timeout for the current session; the LLM uses this after a timeout to retry with a wider budget | `default` |
| `runtime_effective_tool_config` | Inspect the resolved per-tool config (timeout, max bytes, etc.) after `pharos.toml` + env-var overlays | `default` |
| `runtime_language_config` | Inspect one language's resolved LSP config — "is the binary path the override I set or the default?" | `default` |
| `runtime_server_capabilities` | Report which LSP methods the spawned server advertised in its `initialize` response — useful when a tool returns "unsupported" | `default` |
| `runtime_processes` | Snapshot of BEAM processes (memory, message-queue length, registered name) — pharos's view of "what's running" | `debug` |
| `runtime_pid_info` | Drill into one pid: current function, links, monitors, trap_exit, dictionary | `debug` |
| `runtime_supervision_tree` | Dump the live supervised tree as application_controller sees it | `debug` |
| `runtime_ets_tables` | List ETS tables (size, memory, owner) — pharos uses ETS for the pool's subject bridge + diagnostics cache | `debug` |
| `runtime_memory` | BEAM memory breakdown (atom, binary, processes, code, ETS) | `debug` |
| `runtime_applications` | List running OTP applications with their start args | `debug` |
| `runtime_scheduler_util` | Per-scheduler utilization snapshot over a short window | `debug` |
| `runtime_log_tail` | Read the last N entries from the in-memory log ring (post-filter) | `debug` |
| `runtime_log_clear` | Drop the in-memory ring's contents — useful before reproducing a bug | `debug` |
| `runtime_log_level` | Get or set the current log filter spec (`info`, `debug,pharos/lsp/pool=trace`, etc.) without a restart | `debug` |
| `runtime_trace_lsp` | Enable / disable per-LSP wire trace (every `textDocument/*` request + response logged) | `debug` |
| `runtime_trace_calls` | Enable / disable per-MCP-tool call trace (every `tools/call` request + response logged) | `debug` |
| `runtime_kill_lsp` | Graceful kill of one or all LSPs in a workspace; next request lazily respawns (see [Architecture](#architecture)) | `debug` |
| `runtime_lsp_state` | Inspect cached state of one LSP — initialize-time, advertised capabilities, request counters | `debug` |
| `runtime_pool_recon` | Pool reconciliation stats: cache hit rate, leak count, ghost-subject count, top N hot keys | `debug` |

[back ↑](#tools)

### raw (1 tool)

| Tool | What it does |
|------|--------------|
| `lsp_request_raw` | Escape hatch for any LSP method pharos hasn't wrapped natively (e.g. `textDocument/foldingRange`, server-specific extensions like `rust-analyzer/inlayHints`). Off by default in the `tools = [...]` filter; enable explicitly. |

[↑ top](#pharos)

## More languages

The remaining 18 wired into pharos. Same MCP tool surface as the
benchmarked five — follow each LSP's own install instructions.

| Language | Server(s) | Notes |
|----------|-----------|-------|
| C / C++ | [clangd](https://clangd.llvm.org/) | Needs `compile_commands.json` for non-trivial projects |
| Elixir | [next-ls](https://github.com/elixir-tools/next-ls) (default) — alts: [elixir-ls](https://github.com/elixir-lsp/elixir-ls), [start_expert](https://github.com/elixir-lang/expert) | |
| Erlang | [elp](https://github.com/WhatsApp/erlang-language-platform) — alt: [erlang_ls](https://github.com/erlang-ls/erlang_ls) | |
| Gleam | [gleam lsp](https://github.com/gleam-lang/gleam) (built into compiler) | Pharos dogfoods its own gleam tree against this |
| Scala | [metals](https://github.com/scalameta/metals) | First-run bootstraps Bloop (~2-3 min); pharos timeout config covers it |
| Clojure | [clojure-lsp](https://github.com/clojure-lsp/clojure-lsp) | Native binary, no JVM cold-start |
| Haskell | [haskell-language-server](https://github.com/haskell/haskell-language-server) (`haskell-language-server-wrapper`) | Use `ghcup` to keep GHC/cabal/HLS in sync |
| Ruby | [ruby-lsp](https://github.com/Shopify/ruby-lsp) | Project needs `Gemfile.lock` (run `bundle install` first) |
| Lua | [lua-language-server](https://github.com/LuaLS/lua-language-server) | |
| Bash | [bash-language-server](https://github.com/bash-lsp/bash-language-server) | Diagnostics need `shellcheck` on PATH |
| Zig | [zls](https://github.com/zigtools/zls) | Match your zig version |
| Perl | [pls](https://github.com/FractalBoy/perl-language-server) | |
| HTML / CSS / JSON | [vscode-langservers-extracted](https://github.com/hrsh7th/vscode-langservers-extracted) (one package) | |
| YAML | [yaml-language-server](https://github.com/redhat-developer/yaml-language-server) | |
| Markdown | [marksman](https://github.com/artempyanykh/marksman) | Single Rust binary |
| Terraform / HCL | [terraform-ls](https://github.com/hashicorp/terraform-ls) | |

### Adding your own language

Pharos's bundled language list is just a default — every entry can
be overridden and any language with an LSP-compliant server can be
added in `pharos.toml` (see [Configuration](#configuration) for the
file's load order).

**Override a bundled language's binary path** (everything else
inherited from defaults):

```toml
[languages.rust]
command = "/opt/custom-rust-analyzer"
```

**Add a brand-new language** pharos doesn't bundle — Fennel as a
worked example:

```toml
[languages.fennel]
id = "fennel"                           # internal key (must match table name)
extensions = ["fnl"]                    # file extensions → this language
language_id = "fennel"                  # value pharos sends in initialize's clientCapabilities
root_markers = [".git", "fennel.fnl"]   # filenames whose presence marks the project root

[[languages.fennel.servers]]
id = "fennel-lsp"
command = "fennel-lsp"                  # must resolve on PATH or be an absolute path
args = []
methods = "all"                         # this one server handles every LSP method
# Optional: env = { FENNEL_PATH = "..." }
```

**Required keys** (everything else has a sane default):

| Key | Purpose |
|-----|---------|
| `extensions` | Filename extensions to associate with this language |
| `language_id` | The `languageId` pharos sends in `initialize`'s `textDocument/clientCapabilities` |
| `root_markers` | Filenames whose presence marks the project root (used to pick the LSP workspace) |
| `[[languages.<id>.servers]]` (≥1) | At least one server with a `command` resolvable on PATH |

**Validate** the new entry before booting an MCP client against it:

```bash
pharos --print-language-config fennel   # resolved merged config
pharos --doctor                         # probes binary + reports any issue
pharos warm fennel                      # optional: spawn the LSP once to confirm initialize handshake
```

Multi-server routing (e.g. attaching a linter alongside the main
LSP) uses the same `[[languages.<id>.servers]]` block with method
scoping — see [Multi-server languages](#multi-server-languages-adr-019)
for the rules.

[↑ top](#pharos) · [back ↑](#language-support)

## Troubleshooting

### Orphan LSP children after a hard kill

If pharos is killed via SIGKILL, OOM, host shutdown, or a crash,
the LSP children it spawned may outlive it for seconds-to-minutes
before they notice the pipe is gone. Pharos tracks every LSP it
spawns under `~/.local/share/pharos/instances/<pharos-pid>/`. To
reap:

```bash
pharos --cleanup            # dry-run: lists orphan instance dirs + their LSP children
pharos --cleanup --yes      # actually reap
```

The CLI verifies each LSP PID's process name matches what pharos
recorded before signalling, so it won't kill anything pharos didn't
spawn.

### Cold-start latency on first MCP call

The first call to a tool that needs rust-analyzer / jdtls / metals
can take 30-90 s while the LSP indexes the project. Two mitigations:

```bash
# Per-project: pre-warm once before launching the MCP client
cd /path/to/project
pharos warm --all

# Per-MCP-client-spawn: warm on every spawn
PHAROS_WARM_LANGS=rust,go,typescript pharos
```

The CLI form is cheaper if you launch the MCP client often; the env
form is convenient when your MCP client config is the only place you
configure pharos.

### Where are my logs?

Per-session per-PID log file at
`~/.cache/pharos/log/session-<pid>-<YYYY-MM-DD-HHMMSS>.log`. LRU-rotated
to keep the 10 most recent. Override with `PHAROS_LOG_FILE`.

A stable-path `~/.cache/pharos/log/last-crash.log` always points at the
most recent crash dump (if any) — useful in incident reports.

### Pharos boot panic on closed stderr

If a parent process closes pharos's `stderr` (`2>/dev/null` patterns,
some MCP clients during teardown), older versions could panic before
`main` ran and write `erl_crash.dump` in cwd. Fixed in v1.0 via
ADR-030 — pharos installs a try/catch-wrapped logger handler that
silently drops events when fd 2 is gone. If you see a crash dump,
file an issue; the dump itself goes to `~/.cache/pharos/log/`, not
cwd.

### Updating

```bash
npm update -g pharos-mcp                   # npm channel
# or direct download from GitHub Releases

# After update:
pharos --purge-cache                       # clear stale Burrito extract
pharos --doctor                            # warm fresh cache + verify
```

### Uninstalling

```bash
npm uninstall -g pharos-mcp                # if installed via npm
rm ~/.local/bin/pharos                     # if installed via direct download
rm -rf ~/.local/share/.burrito/pharos_*    # extract cache
rm -rf ~/.local/share/pharos/              # instance tracking
rm -rf ~/.cache/pharos/                    # logs + crash dumps
rm -rf ~/.config/pharos/                   # user config (only if you want it gone)
```

[↑ top](#pharos)

## Architecture

Pharos is a Gleam application running on the Erlang/OTP 28 BEAM,
distributed via [Burrito](https://github.com/burrito-elixir/burrito).
Key design choices live in
[doc/adr/](doc/adr/):

| ADR | Topic |
|-----|-------|
| [001](doc/adr/001-language-gleam.md) | Gleam over Elixir |
| [002](doc/adr/002-pollux-for-jsonrpc.md) | pollux for JSON-RPC |
| [004](doc/adr/004-distribution-npm-and-releases.md) | npm optional-deps + GitHub Releases |
| [013](doc/adr/013-supervisor-tree.md) | Supervisor tree shape |
| [017](doc/adr/017-stdio-worker.md) | Stdio transport actor |
| [019](doc/adr/019-lsp-multi-server-routing.md) | Multi-server method routing |
| [021](doc/adr/021-timeout-resolution-stack.md) | Timeout resolution |
| [024](doc/adr/024-lsp-readiness-gate.md) | LSP readiness probe |
| [029](doc/adr/029-custom-uri-schemes.md) | jdt:// / jar:// virtual URIs |
| [030](doc/adr/030-process-lifecycle-hardening.md) | Boot / shutdown / cleanup hardening |

Top-level supervision tree at runtime (per ADR-013/017):

```
pharos_root (one_for_one)
├─ log_subtree (rest_for_one)
│   ├─ ring_keeper        (permanent)
│   └─ log_writer         (permanent)
├─ pool_subtree (rest_for_one)
│   ├─ pool_actor         (permanent)
│   └─ lsp_dyn_sup        (permanent)
├─ sessions_actor         (permanent)    ◄── HTTP / Both transport
├─ http_listener_subtree  (permanent)    ◄── HTTP / Both transport
└─ stdio_worker           (transient)   ◄── Stdio / Both transport
```

Full prose architecture overview at
[doc/architecture.md](doc/architecture.md).

[↑ top](#pharos)

## Development

Requires Erlang/OTP 28, Elixir 1.19, Gleam 1.16+, rebar3 3.27+,
Zig 0.15.2 (for binary builds). Pinned versions in
[.tool-versions](.tool-versions) — `asdf install` resolves all of
them.

```bash
mix archive.install --force github LoganBresnahan/mix_gleam  # one-time
mix deps.get
mix compile
mix gleam.test
```

To run pharos against a real MCP client without rebuilding the binary,
use the dev wrapper:

```jsonc
{
  "mcpServers": {
    "pharos": { "command": "/abs/path/to/pharos/bin/pharos-dev" }
  }
}
```

`bin/pharos-dev` compiles silently (all output to stderr) and boots
Erlang directly so it picks up edits without a release build.

For a release binary:

```bash
MIX_ENV=prod mix release   # produces burrito_out/pharos_<target>
```

Multi-target build needs Zig + `xz`. Windows builds additionally need
`7z`/`7zz` on PATH.

The crash-repro suite at [bench/crash-repro/run-all.sh](bench/crash-repro/run-all.sh)
exercises six lifecycle failure modes and is gating for release tags.
Run it before pushing a tag:

```bash
MIX_ENV=prod mix release --overwrite
bench/crash-repro/run-all.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full PR flow, including
the CLA.

[↑ top](#pharos)

## License

Pharos is dual-licensed.

**Open-source**: [AGPL-3.0-only](LICENSE). Use, modify, and self-host
pharos freely under the AGPL. Network use counts as distribution — if
you operate pharos as part of a service offered to others, you must
offer the corresponding source under the same license.

**Commercial**: if the AGPL's terms don't work for your deployment
(shipping pharos inside a closed-source product, operating it inside
a managed-service offering where you can't release source), a
commercial license is available. See [COMMERCIAL.md](COMMERCIAL.md).

Contributors sign a [CLA](CONTRIBUTING.md#contributor-license-agreement)
so the project can offer both license tracks. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full flow.

[↑ top](#pharos)
