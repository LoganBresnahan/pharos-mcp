# ADR-029 dogfood plan

**Status:** plan only — fixture + harness not built yet.
**Owner:** post-B.2 implementation (Stage C-1).
**Goal:** falsify the four assumptions baked into ADR-029 before
v1.0 ships. Each assumption is testable; each failure is recoverable.

Pharos-dev is the launcher (per `bin/pharos-dev`); the new harness
drives it the same way `bin/test-suite.py` and `bin/dogfood-23lang.py`
already do. Reuses `_pharos_drive.py` for transport + assertion
helpers.

## What we are testing

Six surfaces shipped under ADR-029. Each gets at least one cell:

| Surface | Commit | What |
|---------|--------|------|
| `runtime_server_capabilities` | `6386ca0` | tool returns expected provider keys per Ready session |
| `custom_uri_schemes` config | `781a63d` | jdt registered for java; absent everywhere else |
| Session gate relaxation | `069a89c` | jdt:// flows through hover/find_references; error envelopes correct |
| `fetch_uri_contents` | `ea1a844` | reads class-file contents from a JAR via jdtls |
| Edit rejection | `7597df3` | `apply_workspace_edit` rejects jdt:// with teaching message |
| Instructions advert | `6ac0543` | initialize response includes jdt:// advert string |

## Assumptions to falsify (ADR-029 source)

1. **jdtls accepts `jdt://` for `textDocument/*` without explicit
   `didOpen`.** Passthrough should work.
2. **The LLM reads the MCP `instructions` string and reaches for
   `fetch_uri_contents` when it sees a `jdt://` URI.** The harness
   doesn't have an LLM; for this assumption the harness only proves
   the tool exists, is discoverable in `tools/list`, and the
   instructions string mentions it. The LLM-side check belongs in
   a separate Claude-Code conversation (manual or scripted).
3. **Single-active-session inference covers the common case.** No
   ambiguity errors in a normal single-Maven-project setup.
4. **The edit-reject error teaches the LLM the right alternative.**
   The harness proves the message *contains* the teaching phrase;
   whether it actually changes LLM behavior is an LLM-side check.

## Fixture

### Java project — `bench/fixtures/java-jar-deps/`

Minimal Maven project with one external dependency so jdtls emits
`jdt://` for goto-def into the JAR.

Structure:

```
java-jar-deps/
├── pom.xml                            # depends on a small lib (e.g. commons-lang3)
└── src/main/java/com/example/Probe.java
```

`Probe.java` (under ~30 lines) imports a single method from the
dep and calls it. Goto-definition on that import should return a
`jdt://contents/...` URI. The test workspace stays small so jdtls
cold-start fits inside the test-suite's per-language timeout
(360s budget already in `languages.java()`).

### Setup automation

Add a `bench/fixtures/java-jar-deps/setup.sh` that runs `mvn
dependency:resolve` (so the dep is downloaded into `~/.m2/`). The
harness invokes this once before driving cells; subsequent runs are
no-op.

## jdtls install

Tracked separately (`bin/jdtls` must be on `PATH`). Document in
`bench/fixtures/java-jar-deps/README.md`:

```
Download Eclipse JDT.LS snapshot:
  https://download.eclipse.org/jdtls/snapshots/
Unpack and link bin/jdtls into ~/.local/bin or somewhere on $PATH.
```

If `jdtls` is missing, the harness skips the Java cells with a
clear `SKIPPED: jdtls not on PATH` message rather than failing.

## Harness — `bin/dogfood-adr-029.py`

New script modelled on `bin/test-suite.py`. Drives `bin/pharos-dev`
over stdio (HTTP twin via `--http` flag follows the same pattern
as `bin/test-suite-http.py`).

### Cells (positive path — `jdtls` present)

1. **`initialize` → instructions string contains `jdt://`.**
   Assert the substring "`jdt://`" appears in
   `response.result.instructions`. Pass criterion: exact substring
   match.

2. **`tools/list` → fetch_uri_contents + runtime_server_capabilities
   present.** Assert both tool names appear in the tools array.

3. **`hover` on `Probe.java` → succeeds.** Standard hover cell;
   spawns jdtls. Assert no isError, content non-empty.

4. **`runtime_server_capabilities` after hover spawned jdtls →
   sessions array contains java.** Assert at least one entry with
   `language: "java"`, `server_id: "jdtls"`,
   `capabilities` includes `definitionProvider`,
   `referencesProvider`, `hoverProvider`.

5. **`goto_definition` on the import line → returns `jdt://` URI.**
   Probe.java's import on line N points at a JAR class. Decode
   response, assert location URI starts with `jdt://`. Cache the URI
   for downstream cells (cell 6, 7, 8). [Assumption 1 evidence.]

6. **`hover(jdt://...)` → succeeds.** Same URI from cell 5. Assert
   no isError, content non-empty. [Assumption 1 evidence.]

7. **`find_references(jdt://...)` → returns Locations.** Same URI.
   Assert no isError, response is a non-empty array (the JAR class
   has at least one ref — the call site in Probe.java). [Assumption
   1 evidence.]

8. **`fetch_uri_contents(jdt://...)` → returns content string.**
   Assert no isError, response body parses as JSON with `uri` +
   `content` fields, `content` length > 0, content includes some
   identifier from the dep (e.g. `class` keyword). [Assumption 2
   partial — tool reachable.]

9. **`apply_workspace_edit` against `jdt://` → rejected with
   teaching phrase.** Build a fake WorkspaceEdit changing 1 char
   in the jdt:// URI. Assert isError=true AND response text contains
   "virtual URI" AND "project override". [Assumption 4 partial —
   teaching phrase present.]

### Cells (negative path — pharos config without jdtls)

Run a parallel harness with `PHAROS_TOOLS` filtering out the java
language to verify default-no-jdt behavior:

10. **`initialize` instructions WITHOUT registered schemes →
    advert absent.** Drop jdt:// from java() temporarily via env
    or skip — verify the addendum disappears when no schemes are
    registered. (Maybe skip this cell for v1.0; covered by code
    review.)

### Cells (ambiguity — assumption 3)

11. **Two Java workspaces open simultaneously → AmbiguousSessionForLanguage.**
    Create `bench/fixtures/java-jar-deps-b/` (second fixture). Open
    a file:// from each so two java sessions become Ready. Then
    call `hover(jdt://...)`. Assert isError=true AND response
    text contains "ambiguous" AND lists both workspaces.

    Cost: doubles jdtls cold-start time (~10-30s × 2). Skip in CI;
    run only when validating the multi-workspace branch.

### Regressions to gate against

12. **Existing test-suite still green.** `bin/test-suite.py` runs
    the 4-language regression (rust, go, typescript, python). Must
    pass unchanged — proves session.gleam relaxation didn't break
    file:// flows.

13. **`runtime_server_capabilities` against non-Java workspace
    returns sessions WITHOUT jdtls entry.** Verifies the tool's
    output is keyed correctly (it's not just always returning the
    one Java entry).

## Gating

| Cell | Required for v1.0? |
|------|--------------------|
| 1, 2 | yes — discoverability of B.2 surface |
| 3, 4 | yes — sanity that jdtls path works at all |
| 5, 6, 7 | yes — falsifies assumption 1 (passthrough composes) |
| 8 | yes — fetch_uri_contents end-to-end |
| 9 | yes — teaching message present |
| 11 | nice-to-have — ambiguity branch validation |
| 12 | yes — regression gate |
| 13 | yes — output correctness |

10 is optional. Anything red on cells 1–9 + 12, 13 blocks v1.0.

## What this DOESN'T cover

- **Real LLM behavior** with B.2. The harness can prove the
  surface exists and the messages are correct, but it cannot
  prove the LLM reaches for `fetch_uri_contents` on its own, or
  recovers gracefully from the teaching error. Those checks are
  follow-up "tool discovery audit" work (broader benchmark scope),
  not this harness.
- **Multi-workspace disambiguation via `workspace_uri_hint`.** v1.0
  errors on ambiguity; the hint plumbing across tools is post-v1.0.
- **Other custom schemes.** Only `jdt://` is registered today.
  `csharp://` etc. live or die by adding an entry to
  `languages.csharp()`; same harness pattern, separate fixture.

## When to run

- **Locally during B.2 development:** every commit touching ADR-029
  surfaces. Smoke-test fast iteration loop.
- **Before v1.0 tag:** full run with assumption-3 cell (multi-workspace).
- **In CI once repo flips public (Stage C-2):** add as a separate
  GHA job; cells 1–9 + 12, 13 only (skip ambiguity to keep CI cheap).
- **Manually as part of Phase 7:** route a Claude-Code conversation
  through pharos-dev with the Java fixture and observe whether the
  LLM picks fetch_uri_contents on its own. Out-of-band of this
  harness.

## File layout

```
bench/fixtures/java-jar-deps/
├── pom.xml
├── setup.sh                            # mvn dependency:resolve
├── src/main/java/com/example/Probe.java
└── README.md                           # jdtls install pointer

bin/dogfood-adr-029.py                  # the harness
bin/dogfood-adr-029-http.py             # HTTP twin (one-liner override)
```

## Open question — fixture choice

`commons-lang3` is a popular small dep. Alternative: use a JDK
class directly (no Maven dep needed; just `java.util.ArrayList`).
Goto-def into JDK classes also returns `jdt://`. JDK-only fixture
is simpler — no `mvn` step, no `~/.m2/` warm-up. Decision: try
JDK-class first; fall back to commons-lang3 if jdtls doesn't emit
`jdt://` for `java.*` classes on the test box.
