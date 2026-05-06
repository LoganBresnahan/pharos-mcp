# 015. Multi-root rust-analyzer via outermost Cargo workspace detection

**Status:** Accepted
**Date:** 2026-05-06

## Context

Pharos's pool keys cached LSP workers by `(language, workspace)`,
where `workspace` is the directory returned by
`workspace_root.discover_from_uri/2` — first ancestor of the file's
URI containing one of the language's configured root markers.

For rust the markers are `["Cargo.toml", "rust-project.json"]`. The
walker stops at the **innermost** match. For a Cargo workspace laid
out as

```
~/myproj/
  Cargo.toml          # [workspace] members = ["crate-a", "crate-b"]
  crate-a/Cargo.toml
  crate-a/src/main.rs
  crate-b/Cargo.toml
  crate-b/src/lib.rs
```

a hover on `crate-a/src/main.rs` returns workspace `~/myproj/crate-a`,
and a hover on `crate-b/src/lib.rs` returns `~/myproj/crate-b`. These
are different keys, so pharos spawns **two separate rust-analyzer
processes** — even though rust-analyzer started in either inner
crate would discover the outer workspace through Cargo's metadata
and index everything.

Real consequences during dogfood:

- Two rust-analyzers eating CPU/RAM where one would suffice.
- Cross-crate `goto_definition` / `find_references` work inside one
  rust-analyzer's view but not across processes — the LLM sees a
  symbol defined in `crate-a` but `find_references` from
  `crate-b/src/lib.rs` returns nothing because that's a different
  worker's view of the world.
- Diagnostics caches per-workspace; switching between sibling crates
  drops cache hits.

The same shape exists for Go (`go.work` files declare multi-module
workspaces) and TypeScript (project references via
`tsconfig.json`'s `references` array). This ADR scopes to the rust
case because that is what the dogfood matrix actually exercised;
the design generalizes.

## Decision

`workspace_root.discover_from_uri` keeps its current "first match
walking up" behavior for the generic case. For rust specifically,
introduce a post-discover **promotion** step:

1. If the discovered root is a `Cargo.toml`, parse the file (just
   the `[workspace]` section — no full TOML grammar required, a
   line-scan for the literal `[workspace]` heading is enough).
2. If `[workspace]` is present, the discovered Cargo.toml IS the
   workspace root. Use its directory.
3. If `[workspace]` is absent, walk up from the discovered root
   looking for any ancestor Cargo.toml whose `[workspace]` heading
   is present. If found, promote to that ancestor's directory.
4. If no ancestor workspace is found, use the originally
   discovered root (the innermost crate Cargo.toml).

The promotion is gated on the language being rust; other languages
keep current behavior. Per-language hooks land in the language
config:

```gleam
pub type RootPromotion {
  NoPromotion
  CargoWorkspacePromotion
  // GoWorkPromotion (deferred, same shape)
}
```

The `LanguageConfig` adds a `root_promotion` field (default
`NoPromotion`); the rust default sets it to `CargoWorkspacePromotion`.

## Consequences

**Easier:**

- One rust-analyzer per Cargo workspace, regardless of how many
  member crates the LLM touches. Memory and indexing time stay
  proportional to actual project count instead of crate count.
- Cross-crate `goto_definition` and `find_references` work
  uniformly because they all run inside the same rust-analyzer's
  index.
- Diagnostics cache hit-rate stays high when the LLM moves between
  sibling crates.
- The pool-key invariant (one Proc per `(language, workspace)`)
  remains intact — promotion just changes which directory the key
  resolves to.

**Harder:**

- One additional walking pass at root discovery time. Cost is
  bounded (a few file reads per discovery, cached per pool key
  thereafter).
- Edge case: a user opens two files, one inside a Cargo workspace
  and one in a standalone Cargo crate that happens to live INSIDE
  the workspace dir but is **excluded** from `members`. Promotion
  would route the standalone crate to the wrong rust-analyzer.
  Mitigation: when the promotion target's `[workspace.members]`
  is parseable and the file's crate path is NOT in it, fall back
  to no-promotion. Implementation defers this until a real bug
  reproduces it; the simple line-scan promotion ships first.
- Edge case: a Cargo workspace at `~/projects/Cargo.toml` covers
  hundreds of crates, and the LLM only touches one. Spawning the
  rust-analyzer with the full workspace as root means slow cold
  start (rust-analyzer indexes everything). Acceptable trade —
  the LLM was going to index the workspace eventually anyway,
  and the cache covers re-use.

**Constraints on future work:**

- The same `RootPromotion` enum slots Go's `go.work` detection
  (look for `go.work` in ancestors, promote to its dir if found)
  and TypeScript's `references` array (parse `tsconfig.json`'s
  references list). Both deferred until dogfood reproduces the
  same multi-root pain there.
- Custom language configs (registry.json overrides) cannot yet
  declare promotion; new languages added via config get the
  default `NoPromotion`. Adding configurable promotion is a
  small follow-up — the JSON decoder would accept a string like
  `"cargo_workspace"` and map to the enum.

## Alternatives considered

- **Always merge per-language into one Proc.** Rejected: one rust-
  analyzer for every rust file across all of disk would have
  enormous startup cost on machines with many unrelated projects.
  Promotion bounded by Cargo workspace boundaries gives the
  intuitive grouping users expect.

- **Demand-driven `workspace/didChangeWorkspaceFolders`.** Add
  files to an already-running rust-analyzer's workspaceFolders
  list dynamically. More complex (requires workspace-folder
  tracking per Proc) and doesn't actually solve the right
  problem — the LSP spec lets you add roots, but rust-analyzer's
  cargo metadata scan happens at initialize and adding folders
  later does not re-run the scan in all rust-analyzer versions.
  Promotion at boot avoids this fragility.

- **Outermost-marker walk for all languages.** Could subsume the
  rust case without a per-language hook. Rejected: most other
  languages' root markers are leaf-level (`package.json`,
  `pyproject.toml`) and walking past them lands in unrelated
  parent dirs. Cargo's `[workspace]` is the explicit "this is
  the real root" signal that rust gets but others lack.

- **Detect via cargo metadata shellout.** Run `cargo metadata
  --no-deps` and parse the JSON to find the workspace root.
  Authoritative but ~200ms per discovery on a cold cache, and
  pharos's per-tool latency budget can't absorb that for the
  first request after process start. Line-scan is good enough.

- **Read the full TOML.** Use a TOML parser dep to read the
  workspace section robustly. Premature: the line-scan handles
  every layout we observed in the wild and the parser dep adds
  weight for one feature.
