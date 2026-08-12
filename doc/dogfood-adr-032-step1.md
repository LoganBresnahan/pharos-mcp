# Dogfood — ADR-032 step 1: will the owning project's LSP answer for a dependency file?

**Date:** 2026-08-12
**Gate:** [ADR-032](adr/032-workspace-root-determination.md) step 1
**Result:** **A fails for both its languages; D clears for both of its.** Plus one
finding that reframes the original field report.

## What was being tested

ADR-032 selects two mechanisms that share one unverified premise: *the owning
project's LSP will answer a request for a file inside a dependency.* Option A
(vendor-skipping ascent) needs it for in-tree paths; option D (route out-of-tree
cache paths to the live session) needs it for out-of-tree paths. Step 1 is an
empirical gate on that premise, per language and per topology.

## Instrument

`probe.mjs`, a standalone LSP driver speaking the protocol directly over stdio.
Pharos itself cannot run this probe: routing a dependency URI to the project
session is precisely the thing that does not exist yet.

The driver mirrors
[`session.build_initialize_params`](../src/pharos/tools/session.gleam) and
`build_client_capabilities` verbatim — same `processId: null`, `rootUri`,
`clientInfo`, per-server `initializationOptions`, and the
`workspace/didChangeConfiguration` + `workspace/configuration` answering that
tsserver gates behaviour on. The point is to probe the same client production
uses, not a hand-rolled approximation.

Sequence per run: `initialize` at the **project** root → `didOpen` a
**first-party** anchor → poll `documentSymbol` until the project is genuinely
loaded → `didOpen` the **dependency** file → `hover` (sanity) →
`textDocument/references` with `includeDeclaration: true`.

**Clearance criterion:** at least one returned reference in a first-party file —
under the project root and not inside the dependency tree.

Fixtures are minimal and purpose-built (`fx-ts`, `fx-py`, `fx-rs`, `fx-go`), so a
verdict is attributable to the server rather than to repo-specific accidents.

## Results

| Language | Server | Topology | Mechanism | Verdict |
|---|---|---|---|---|
| typescript | typescript-language-server 4.4.x / TS 6.0.3 | in-tree (`node_modules/`) | A | **FAILS** |
| python | pyright-langserver | in-tree (`.venv/…/site-packages/`) | A | **FAILS** |
| rust | rust-analyzer | out-of-tree (`~/.cargo/registry/`) | D | **CLEARS** |
| go | gopls | out-of-tree (`$GOPATH/pkg/mod/`) | D | **CLEARS** |

The split falls exactly on the topology line — which is also the A/D line.

### rust — CLEARS

Anchor `fx-rs/src/main.rs`, dep
`~/.cargo/registry/src/index.crates.io-*/hex-0.4.3/src/lib.rs`, symbol `encode`.
3 references, including `./src/main.rs`. rust-analyzer indexes registry sources
into the project graph, and a query anchored in the registry answers with
project hits.

### go — CLEARS (after a fixture correction)

Anchor `fx-go/main.go`, dep `…/pkg/mod/github.com/google/uuid@v1.6.0/version4.go`,
symbol `New`. 3 references, including `./main.go` and `./other.go`.

**The first run reported FAILS and was wrong.** The fixture had no `go.sum`, so
the module never loaded; the tell was `hover` returning
`func New() invalid type` rather than a resolved signature. After `go mod tidy`
and a clean `go build ./...`, the same probe cleared. Recorded because it is the
exact failure mode ADR-032 warns about — reading murky output as a verdict — and
because `hover` returning a nonsense type is a cheap, reliable health check to
run before believing any reference count.

### typescript — FAILS

Anchor `fx-ts/src/App.tsx`, dep `node_modules/@types/react/index.d.ts`, symbol
`useState` at its declaration. **5 references, all inside `index.d.ts`. Zero
first-party.** `hover` at that position resolves correctly
(`function React.useState<S>(initialState…)`), so the session understands the
file; it simply will not search the project from it.

Three controls establish this is a real refusal, not a cold project:

1. **The configured project is loaded.** `workspace/symbol "Other"` returns
   `Other @ ./src/Other.tsx` — a file never opened. tsserver has the tsconfig
   project, not a single-file inferred one.
2. **The reference engine is project-wide capable.** A first-party declaration
   (`sharedFn` in `src/helper.ts`) returns 5 refs across `helper.ts`, `App.tsx`,
   and `Other.tsx` — including files never opened.
3. **Opening more first-party files changes nothing.** Same 5 dep-internal refs
   before and after `didOpen` of `Other.tsx`.

So TypeScript deliberately scopes reference search for symbols declared under
`node_modules`. Routing cannot fix what is a deliberate server-side scope.

### python — FAILS

Anchor `fx-py/src/app.py`, dep `.venv/…/site-packages/requests/api.py`, symbol
`get`. **1 reference — the declaration itself.**

Same control standard: a first-party declaration (`shared_fn` in
`src/helper.py`) returns 5 refs across `helper.py`, `app.py`, and `other.py`, so
pyright's engine is project-wide capable. Re-run with a direct
`from requests.api import get` (no re-export chain, which was the plausible
confound) — still 1. `hover` resolves the signature correctly throughout.

## The finding that reframes the field report

ADR-032's context attributes the reported wrong reference count to the rootless
session. **It is not caused by rooting.** Running the identical query against a
session deliberately rooted *at* the dependency (today's behaviour) and against
one rooted at the project returns **the same 5 locations** either way.

Confirmed through real pharos, not just the probe. `mcp-drive.mjs` drives
`mix start` over stdio and calls `find_references` on the dep URI, twice, varying
only `root_markers`:

| `root_markers` | Root chosen | Payload | Attribution note |
|---|---|---|---|
| `[tsconfig, jsconfig, package.json]` (today) | `…/node_modules/@types/react` | 5 locations, all in dep | **fires** |
| `[tsconfig, jsconfig]` (**simulates option A**) | `…/fx-ts` (the project) | 5 locations, all in dep | **silent** |

Dropping `package.json` makes `@types/react` non-rooting, so ascent reaches the
project — which is what A's skip-ascent produces. This runs A's routing through
production pharos without implementing A.

**For TypeScript `find_references`, option A is a net negative.** It delivers a
byte-identical wrong answer and *removes* F's warning, because the answering root
is no longer a dependency path. The agent moves from warned-and-wrong to
unwarned-and-wrong.

The premise is **per-method, not per-language**: routing repairs project
*context* (completions, module resolution) while `references` carries its own
server-side scope rule that routing does not touch.

An earlier draft of this report claimed A was still justified by the report's
*other* symptom — the bogus JSX diagnostics. **That claim was wrong**; see the
next section.

## Third finding: the JSX diagnostics are not a rooting defect either

Found incidentally while verifying step 2, by running `get_diagnostics` through
pharos against the fixture. Under **correct** rooting, on a **first-party** file:

| File | Root | tsconfig | Diagnostics |
|---|---|---|---|
| `src/App.tsx` (JSX) | `fx-ts` ✓ | `jsx: react-jsx` | `[1005] '>' expected`, `[1005] ';' expected` … |
| `src/Plain.ts` (no JSX) | `fx-ts` ✓ | same | **none** |

Both files are first-party, in the same correctly-rooted project, under a
tsconfig that sets `jsx: react-jsx`. A correctly-opened `.tsx` should parse JSX.
It does not — and the error is at the JSX attribute (`<div onClick=…`), the
signature of a parser that was never put in JSX mode.

**Likely cause, and it is not ADR-032's.**
[`session.ensure_doc_opened_for_server_id`](../src/pharos/tools/session.gleam)
passes `config.id` as the `didOpen` `languageId`:

```gleam
pool.ensure_open(pool, config.id, workspace, server_id, file_uri, config.id, text)
//                                                                 ^^^^^^^^^ languageId
```

So every file in the typescript family opens as `"typescript"` — `.tsx`, `.jsx`,
`.js`, `.mjs` alike. tsserver keys its parser on that value, and `typescript`
disables JSX. `LanguageConfig` has one `id` and a *list* of `file_extensions`,
so the shape cannot currently express `.tsx → typescriptreact`.

Not proven to the standard of the other findings: an isolated harness could not
reproduce it, because tsserver would not publish diagnostics there under any
`languageId` — 0 in both arms, an instrument failure rather than a null result.
The evidence is the pharos-side pair above plus the code path. Stated as
**likely**, needing its own confirmation.

**Why it matters here:** it removes A's last motivation from the field report.
Both of the report's symptoms now reproduce under correct rooting, so neither is
evidence for a rooting change. A is not merely demoted — as of this report it is
**unmotivated**, and would need a symptom that actually depends on the root
before it is worth building. This is out of ADR-032's scope and wants its own
investigation; the language-neutrality invariant makes it a config-shape
question (per-extension `language_id`), not a one-line patch.

## Second finding: F's note gives advice that does not hold

The shipped note says *"Re-anchor on a first-party declaration for project-wide
results."* For a **library** symbol in TypeScript that is false. Re-anchoring on
`App.tsx`'s own `useState` call returns 8 refs across `App.tsx` and
`index.d.ts` — and still misses `Other.tsx`, which also calls `useState`.

TypeScript resolves that anchor to the file-local import binding, so the result
is that file's uses plus the declaration sites. The advice is sound for
first-party symbols (control 2 above) and misleading for library ones. Worth
correcting independently of which mechanism wins, since F has already shipped.

## Reproducing

Harness and fixtures live in the session scratchpad, not the repo — they depend
on a populated `~/.cargo/registry` and Go module cache.

```sh
node probe.mjs --lang rust --root fx-rs --anchor src/main.rs \
  --dep ~/.cargo/registry/src/index.crates.io-*/hex-0.4.3/src/lib.rs \
  --symbol encode --decl-pattern '^pub fn encode<T'
```

Before believing any `FAILS`, check `hover` at the same position resolves a real
type, and run the first-party control for that language. Go failed both on the
first attempt and the verdict was wrong.
