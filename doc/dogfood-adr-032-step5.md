# Dogfood — ADR-032 step 5: does routing answer better than flooring?

**Date:** 2026-09-01
**Gate:** [ADR-032](adr/032-workspace-root-determination.md) validation — the run
that moves the ADR past Proposed
**Result:** **All nine hard cells pass. Routing reaches first-party files the
floored session structurally cannot see** (7 project references vs 0). Two
corrections to the instrument were needed first, both recorded below.

## What was being tested

Steps 2-4 landed the mechanism: one workspace-resolution chokepoint, out-of-tree
dependency paths routed to the live workspace, and both path-fragment lists moved
into per-language config. The gleeunit suite covers the *decision* — which
workspace `resolve_workspace` picks. It structurally cannot cover the claim the
ADR actually makes: **that routing a registry-crate file to the owning project's
session produces a better answer from a real language server.**

Step 1 established this distinction the hard way. TypeScript rooted *correctly*
under option A and still answered wrongly, because tsserver scopes reference
search for symbols declared under `node_modules` regardless of root. "The routing
works" and "the defect is fixed" are different findings, and only the second one
retires the ADR.

## Instrument

[`bin/dogfood-adr-032.py`](../bin/dogfood-adr-032.py) — nine cells against real
rust-analyzer and gopls, driving pharos over stdio via `bin/_pharos_drive.py`.

Each batch spawns a **fresh pharos**. That is load-bearing, not tidiness: the
pool keeps sessions warm across calls, so a cold-start cell sharing a process
with a warm one silently tests the warm path twice.

| Fixture | Path | Why |
|---|---|---|
| rust project | `~/game` | 499 lock packages, direct dep on `hecs`, `hecs::World` used in 3 first-party files |
| rust dependency | `hecs-0.10.5/src/world.rs` | defines `World` — the symbol the project imports |
| go project | `tmp/fixtures/go` (prometheus) | real module graph |
| go dependency | `azcore@v1.21.0/core.go` | in the project's `require` set |
| second rust project | `~/ts-wasm-spike` | enables cell 9 (ambiguity) |

## Results

| Cell | Verdict | Evidence |
|---|---|---|
| 1 rust cold start floors to the registry crate | PASS | floored at `hecs-0.10.5` |
| 2 rust warm call routes to the project session | PASS | single session at `~/game` |
| 3 routed `find_references` carries no dep-scope note | PASS | note silent |
| 4 floored `find_references` DOES carry the note | PASS | note fires |
| **5 routed answer reaches first-party files the floor cannot** | **PASS** | **routed 7 project refs, floored 0** |
| 5b OBSERVE reference-set shape | — | routed=53 (7 first-party), floored=128 (0 first-party) |
| 6 `dependency_cache_fragments = []` disables routing | PASS | registry-rooted session reappears |
| 7 go cold start floors to the module cache | PASS | floored at `azcore@v1.21.0` |
| 8 go warm call routes to the project session | PASS | single session at the fixture root |
| 9 two live workspaces floor rather than hard-erroring | PASS | see below |

### Cell 5 — the ADR's claim, and why totals are the wrong metric

Anchor `hecs-0.10.5/src/world.rs:48:11`, symbol `World`.

| | total refs | **in the project** | inside the dependency |
|---|---|---|---|
| routed (session at `~/game`) | 53 | **7** | 46 |
| floored (session at `hecs-0.10.5`) | 128 | **0** | 128 |

The routed hits land in `src/core/mod.rs`, `src/core/systems/decay.rs`, and
`src/core/systems/gravity.rs` — the project's real uses of `World`.

**The floored session returns 2.4x MORE references and not one of them is in the
project.** It is rooted at the crate, so it sees that crate's own tests and
examples and nothing else. Any metric based on total count therefore reads a
correct routing result as a failure — which is exactly what an earlier revision
of this harness did. The criterion is step 1's: *at least one reference in a
first-party file*, which the floor structurally cannot produce.

This is the finding that separates rust/go from the option-A languages. tsserver
and pyright refuse to search the project from a dependency declaration no matter
how the session is rooted; rust-analyzer and gopls do search it, so routing
converts a useless answer into a correct one.

### Cell 9 — ambiguity degrades, it does not fail

Two live rust workspaces (`~/game` and `~/ts-wasm-spike`), then a dep-anchored
call. Per ADR-032 constraint 3, two-plus candidates must fall back to plain
ascent rather than becoming ADR-029's hard failure. The call returns a floored
answer with the attribution note attached: degraded, never silent, never an
error.

## Two corrections to the instrument

Recorded in full because both produced a confident, wrong verdict first — the
same failure mode step 1 warns about.

### 1. The anchor was a crate-private test helper

The first run reported **"NO WIDENING, routed=0 floored=26"** and looked like a
real refutation of the ADR.

It was not. `anchor_from_symbols` took the first symbol of an acceptable kind
anywhere in the file, and landed on `fn assert_all` inside aho-corasick's
`mod testoibits` — a **test-only helper in a transitive dependency**. Zero
downstream references is the arithmetically correct answer for such a symbol,
whether routing worked or not. The cell measured nothing.

Fixed by pruning test modules (the module name is the only signal available —
`#[cfg(test)]` is invisible over LSP) and ranking symbols the project actually
names ahead of the rest.

### 2. The dependency was transitive, and then the file was wiring-only

`rust_dependency_source` walked `Cargo.lock` in file order, so it picked
`aho-corasick` — a transitive crate nothing in the project names — no matter
what the project directly depends on. Direct `[dependencies]` are now tried
first.

That was still not enough. The common Rust layout makes `src/lib.rs` module
wiring plus `pub use` re-exports, so for `hecs` the only symbols it *declares*
are two crate-private macros; `World` lives in `world.rs`. `document_symbols`
reports what a file declares, not what it re-exports, so the anchor has to sit
at the definition. Selection now looks for the crate file that defines a symbol
the project imports.

A first attempt at that matched on a bag of every identifier in the project and
picked `query.rs`, because hecs defines `View` and any project with a camera
also contains the word "View". The match is now against names the project
imports **from that specific crate** (`use hecs::{...}`, `hecs::World`).

**The ranking cannot manufacture a pass.** It only orders candidates; routing
still has to return the project's references for the cell to observe anything.

## One environmental finding, not a pharos defect

Cell 7 failed on the first pass with:

```
LSP spawn failed: initialize handshake failed: client transport failure
```

Root cause is in the debug log, and it is asdf, not pharos:

```
No version is set for command gopls
Consider adding one of the following versions in your config file at
  <module-cache-dir>/.tool-versions
```

This machine's `GOPATH` is `~/.asdf/installs/golang/1.26.2/packages`, so the Go
module cache lives **inside asdf's own install tree**. pharos spawns each LSP
with cwd = workspace root; for a dependency-rooted cold start that cwd is inside
asdf's installs, where the shim's cwd-walk resolution finds no version. The shim
prints to stdout and exits, and pharos correctly reports a dead transport.

Controls: `gopls` starts fine at that same root when invoked directly (so it is
not the read-only `dr-xr-xr-x` cache dir), works from every ordinary cwd, and
cell 7 passes with `ASDF_GOLANG_VERSION=1.26.2` set. Unrelated to ADR-032 — the
log shows the call taking the unchanged ascent path
(`fell back to ascent … ready_workspaces=0`).

**Anyone re-running this on an asdf machine whose GOPATH sits under
`~/.asdf/installs` needs `ASDF_GOLANG_VERSION` set, or cell 7 fails for reasons
that have nothing to do with routing.**

## Verdict

ADR-032's mechanism and its claim both hold for the two languages step 1
cleared. The ADR moves from Proposed to Accepted.

Residues, unchanged and still worth stating in the README:

- **Cold start.** A first call anchored in an out-of-tree dependency has no
  session to route to and floors, reproducing pre-ADR behaviour with the
  attribution note attached. Cells 1 and 7 assert exactly this.
- **Unprobed languages.** Only rust and go have been cleared empirically. The
  other 21 fall through to plain ascent.
