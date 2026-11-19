# Dogfood — ADR-038: do answers follow the disk on real servers?

**Dates:** 2026-11-16 (revision 3), 2026-11-18 (the tree after review)
**Gate:** [ADR-038](adr/038-document-resync-from-disk.md) validation, issue
[#3](https://github.com/LoganBresnahan/pharos-mcp/issues/3). ADR-038 was accepted on
2026-11-18.
**Result:** **16 of 16 real-server checks pass on the tree after review.** Revision 3 passed
11 of 11 on 2026-11-16.
Three coverage limits and four review findings are recorded below; one finding (F4) is a known
limit on TypeScript, tracked in pharos-mcp#13. Two problems that predate #3 are recorded too:
rust-analyzer's own diagnostics never arrive (#8), and pyright and gopls take about 58 s to
start.

## What was being tested

The gleeunit suite covers the planning (what each document needs sent) and the stamp
bookkeeping. `test/daemon/integration.py` drives the whole path against `bin/_stub_lsp.py`.
Neither can show that a real server answers about the text on disk after pharos re-syncs it.
ADR-038 claims exactly that:

- for the file asked about;
- for the files it depends on that pharos holds open;
- for every session sharing the daemon.

## Instrument

[`bin/dogfood-adr-038.py`](../bin/dogfood-adr-038.py). It edits files on disk between questions
and checks that the answers follow. Run it as:

```sh
mix release.dev
python3 -I bin/dogfood-adr-038.py <scratch-dir> [rust,python,ts,go]
```

- **pharos under test:** the release in `_build/prod/rel/pharos`, in daemon mode, with a
  private `PHAROS_RUNTIME_DIR` and `XDG_STATE_HOME` under the scratch dir. Each run starts its
  own daemon and stops only that one, so the daemon other sessions use is never touched. The
  run's logs land in `<scratch-dir>/state/pharos/log/`.
- **Fixtures:** throwaway projects written fresh by each run under the scratch dir: a two-file
  crate, a one-file Python project, a two-file TypeScript project, and a three-package Go
  module.
- **Servers:** whatever is first on `PATH`; the run prints their versions.
- The 2026-11-16 runs used an earlier copy of the driver from the session scratchpad. It had
  the same checks except the gopls and deleted-file ones.

### Servers

| Server | Version |
|---|---|
| rust-analyzer | 1.94.0 (4a4ef49 2026-03-02), with cargo 1.94.0 |
| pyright | 1.1.409 |
| ruff | 0.15.12 |
| typescript-language-server | 5.1.3, with TypeScript 6.0.3 (node v25.4.0) |
| gopls | v0.21.1 (go 1.26.2); 2026-11-18 only |

### Each server's `textDocumentSync`, as pharos recorded it from `initialize`

| Server | `textDocumentSync` | `diagnosticProvider` | pharos mode |
|---|---|---|---|
| pyright | `2` | none | Pull |
| ruff | `{change: 2, openClose: true, willSave: false, willSaveWaitUntil: false}` | `{identifier: "Ruff", interFileDependencies: false, workspaceDiagnostics: false}` | Pull |
| typescript-language-server | `2` | none | Push |
| rust-analyzer | `{change: 2, openClose: true, save: {}}` | `{identifier: "rust-analyzer", interFileDependencies: true, workspaceDiagnostics: false}` | Push |
| gopls | `{change: 2, openClose: true, save: {}}` | none | Push |

All five accept a full-text change (Incremental, kind 2). The three that use the options
form open and close documents. Under VS Code's resolution, rust-analyzer and gopls get a
plain `didSave`, and so do pyright and typescript-language-server, from the number form.
ruff's options form has no `save`, so it gets none.

## Results

### 2026-11-16: revision 3, 11 of 11

| Check | Verdict | Evidence |
|---|---|---|
| rust: comment-only edit keeps the error, well under 20 s | PASS | 0.16 s, `E0308` (rustc) |
| rust: fixing the error clears it | PASS | `[]` in 0.11 s |
| rust: reintroducing the error shows it | PASS | `E0308` in 0.11 s |
| rust: lib.rs sees b.rs's new signature | PASS | `E0061` (rustc); see limit (b) |
| rust: hover in lib.rs shows b.rs's new signature | PASS | `pub fn helper(x: i32, y: i32) -> i32` |
| rust: shared daemon, session A never sees -32801 while session B edits | PASS | 1049 hovers, no error |
| python: diagnostics follow the save (the #3 repro) | PASS | pyright `reportReturnType`, `reportUndefinedVariable`, `reportUnusedExpression`; ruff `F821`; 0.02 s |
| python: hover on a line that only exists in the new text | PASS | `(function) undefined_name: Unknown` |
| python merge: comment-only edit, both servers report | PASS | no `pharos.not_reported` |
| ts: comment-only edit keeps the error | PASS | `TS2322`, 0.41 s |
| ts: a.ts sees b.ts's new signature | PASS | `TS2554` with `TS2322`, 0.41 s |

The first run that day failed the last check: a.ts's diagnostics stayed "fresh" after b.ts
changed. Freshness was tracked per document only, and a.ts's own text hadn't changed. That
gave revision 3 its per-proc batch stamp: any batch on a proc makes earlier entries on it
carried over. The rerun passed all 11. geex-pharos-mod, the session that reviewed revision 3 on 2026-11-16,
then reran the rust section on its own
scratch root and got 6 of 6, with 1041 hovers in the shared-daemon check.

That run used the revision 3 tree before its three small follow-up fixes. Those fixes were
checked with the unit suite and the daemon integration suite, not on real servers. The
2026-11-18 run below covers them.

### 2026-11-18: the tree after review, 16 of 16

The release was rebuilt from the final tree. The table is the full run; the rust section's
times come from a rerun of that section alone, explained below the table.

| Check | Verdict | Evidence |
|---|---|---|
| rust: comment-only edit keeps the error, well under 20 s | PASS | 0.16 s, `E0308` (rustc) |
| rust: fixing the error clears it | PASS | `[]`, 0.16 s |
| rust: reintroducing the error shows it | PASS | `E0308`, 0.16 s |
| rust: lib.rs sees b.rs's new signature (E0061, via cargo check) | PASS | `E0061`, 0.23 s; see limit (b) |
| rust: hover in lib.rs shows b.rs's new signature | PASS | `pub fn helper(x: i32, y: i32) -> i32` |
| rust: shared daemon, session A never sees -32801 while session B edits | PASS | 807 hovers, median 0.003 s, max 0.03 s |
| python: diagnostics follow the save (the #3 repro) | PASS | the same four as on 2026-11-16, 0.02 s |
| python: hover on a line that only exists in the new text | PASS | `(function) undefined_name: Unknown` |
| python merge: comment-only edit, both servers report | PASS | no `pharos.not_reported` |
| ts: comment-only edit keeps the error | PASS | `TS2322`, 0.41 s |
| ts: a.ts sees b.ts's new signature (TS2554) | PASS | `TS2554` with `TS2322`, 0.41 s |
| ts: a deleted file asked about, hover no longer describes it | PASS | `{"contents": []}` |
| ts: a deleted file asked about, no diagnostics from its old text | PASS | `[]` at once |
| go: after another file opened, the unchanged file is answered unmarked, at once the second time | PASS | 2.04 s, then 0.00 s, `UnusedVar` both times |
| go: after a change in another package, the same | PASS | 2.04 s, then 0.00 s |
| go: a.go sees b.go's new signature | PASS | `WrongArgCount` with `UnusedVar`, 1.08 s |

The full run overlapped heavy load from other work on the machine (a 5-minute load average of
7 on 8 cores). Its rust answers took 0.53 to 0.95 s, and the shared-daemon check made only 42
hovers. That check still passed, but the run doesn't show where the hovers' time went: pharos
doesn't log its `-32801` retries. Rerun alone at lower load, the rust section passed 6 of 6
with the times in the table. The driver now prints the hover timings, so a slow run shows up.
The full run's cold starts were: rust-analyzer R1 120.34 s and R1b 20.22 s (no answer, #8);
pyright 64.70 s; gopls 58.59 s; TypeScript 1.18 s.

### The shared-daemon run

Two sessions join the same daemon and the same rust-analyzer. Session A hovers lib.rs in a
loop. Meanwhile session B rewrites b.rs six times and asks for diagnostics after each write,
which re-syncs b.rs every time. A must never see `-32801 ContentModified`: pharos only sends
a change when a file's hash changed, and every request tool retries `-32801`
(`session.request_with_content_modified_retry`). The hover counts were:

- 868 and 1049 in the two 2026-11-16 runs;
- 1041 in geex-pharos-mod's run;
- 42 in the loaded full run on 2026-11-18, and 807 in the rerun (median 0.003 s, max 0.03 s).

None saw an error.

## Coverage limits

**(a) The carried-over path has run only against the stub.** Every real rust-analyzer answer
after the first re-sync was fresh `cargo check` output, in 0.11 to 0.16 s, because a two-file
crate checks that fast. No answer carried a `pharos.carried_over` note. The path's only
coverage is the stub scenarios:

- `resync_unchanged_diagnostics`: a server that skips publishing an unchanged set;
- `resync_settles_after_window`: the settle window after another file changed.

The driver prints each answer's freshness but asserts on it only in the gopls checks. There,
pharos answers the unchanged file unmarked once the settle window has passed.

**(b) On rust-analyzer, E0061 doesn't prove the re-sync of other open documents.** E0061 comes
from `cargo check`, which reads the disk whatever rust-analyzer holds in memory. There the
evidence is the hover, which rust-analyzer answers from memory. On TypeScript, `TS2554` does
prove it, because tsserver answers from its in-memory program. On Go, gopls's `WrongArgCount`
proves it too: gopls answers from the client's copy of a file the client holds open, and it
doesn't watch the disk (F3). So b.go's change can only have reached it through pharos's
re-sync.

**(c) The TypeScript checks never had a re-check in flight.** Each TypeScript question here came
after tsserver had published for the previous change, so none of them could meet F4 (below):
a set computed for the previous text arriving just after the change. Their passes say nothing
about that case. The race script of the session named `verifier` and the #13 probe do exercise it.

## The rust-analyzer cold-open finding (pharos-mcp#8, predates #3)

The first question about a never-edited Rust file gets no diagnostics at all:

| Step | Time | Answer |
|---|---|---|
| R1: a cold `get_diagnostics`, `timeout_ms` 120000 | 120.02 to 120.34 s | "No textDocument/publishDiagnostics notification was received" |
| R1b: asked again 8 s later, `timeout_ms` 20000 | 20.03 to 20.22 s | the same |
| R2: after a comment-only edit, whose re-sync sends `didChange` + `didSave` | 0.16 s | `E0308` from `rustc` |

The cause: rust-analyzer advertises `diagnosticProvider`, and pharos advertises
`textDocument.diagnostic` to every server. So rust-analyzer serves its own diagnostics by
pull only, and pushes only `cargo check` results. pharos runs it in Push mode, so the first
diagnostics arrive only once a `didSave` starts `cargo check`, and rust-analyzer's own
diagnostics never arrive. Every rust-analyzer answer in these runs had source `rustc`, and
none came from rust-analyzer itself. The cause is on `main` before #3. In these runs the
first `cargo check` ran only after a re-sync's `didSave`, which #3 added. Tracked in #8, which decides
whether the trial (#7) can use Rust.

## Review findings (2026-11-18)

The review of 2026-11-18 was a different session from geex-pharos-mod: the one named `verifier`.
It checked revision 3 against pyright, ruff, TypeScript and gopls in its own clone.
It reported three findings (F1-F3), none blocking. Their fixes are in this tree, with ADR-038
revised to match. Its later check of the final tree found F4 (below), which is recorded as a
known limit, not fixed here.

**F1: a deleted file asked about was still answered from its old text** (TypeScript, Go,
Python). The subject was synced only when it could be read, so pharos kept the old text open.

- Now the subject is read like every other open document. If its file is gone, pharos closes
  the document if it's open and never opens it, as for a file that never existed.
- Nothing cached about the closed document's old text is served again. The cache reads it as
  missing, from the moment the close is planned.
- Covered by unit tests, by `resync_subject_deleted`, and by the driver:
  - TypeScript: hover `{"contents": []}`, and an empty diagnostics set at once.
  - gopls: `no package metadata for file` on hover, and an empty set in about 1 s.
  - Python: pyright's hover returns `null`. Its pull diagnostics return one item, "Source
    file could not be read". ruff didn't answer within the 5 s timeout and is named under
    `pharos.not_reported`. Neither shows the old text's diagnostics. The driver records this
    without asserting, because pyright doesn't watch the disk (F3).

**F2: on gopls, an unchanged file paid 2 s and came back marked carried over on every call
after anything else happened on that server.** That held after another file was opened or
changed, in any package. gopls never re-publishes a file whose diagnostics didn't change, so
the marker lasted for good. #6 would have stayed silent on every Go file after the first edit.

- Now the settle window runs from when the proc wrote the batch, not from the question.
- Past the window, an entry carried over only by other documents' changes counts as fresh.
  One from before its own document's latest sync stays marked carried over.
- A call whose own timeout ends inside the window is answered marked.
- An earlier attempt made batches of only `didOpen`s not count. Measurement showed it covered
  only the open case.
- On gopls, the first question after another file opens or changes now waits out the rest of
  the window, about 2.04 s, and comes back unmarked. The next takes 0.00 s. Both cases pass
  in the driver.

**F3: pyright and gopls don't watch the disk.** For a file pharos never opened, created,
deleted or changed after the server started:

- typescript-language-server sees all three changes;
- gopls and pyright see none;
- rust-analyzer is not measured.

ADR-038 had said that servers fall back to watching on their own; it now says exactly the
above. The fix is to send `workspace/didChangeWatchedFiles` from pharos: pharos-mcp#10, not
part of #3.

**F4: on TypeScript, a set computed for the previous text can be served as fresh.** The
session named `verifier` found this in its check of the final tree, later on 2026-11-18. Logan decided to land
#3 with it recorded as a known limit; the fix is pharos-mcp#13, and #6 waits on it.

- typescript-language-server publishes with no `version`. Its diagnostics come from tsserver's
  asynchronous re-check of every open file. If a change lands while a re-check is running, the
  re-check's set for the old text can arrive after the `didChange`. pharos orders by arrival,
  so it caches that set as fresh.
- Repro, `verifier`'s race script:
  1. 10 busy open files;
  2. a.ts open with errors;
  3. another file opened, which starts a re-check of every open file;
  4. at once, a.ts saved clean and asked about.
  - Results: `[2322, 2552]` in 0.06 s, unmarked; `[]` 1 s later.
  - 8 of 8 on the final tree and 8 of 8 on revision 3. Without step 3, 0 of 6.
- On the wire, through a logging proxy:
  - the `didChange` at version 6;
  - a publish with no version and codes 2322, 2552, 25 ms later;
  - the correct empty publish 356 ms after the change.
- gopls: 0 of 10. pyright and ruff are asked directly (Pull), so they aren't exposed.
  rust-analyzer isn't measured.
- ADR-038 records it as a known limit. Its line that #6 can take an unmarked answer as current
  is replaced by the following. An unmarked answer was published after the document's own
  latest sync. It describes the current text only when the server can't publish a set computed
  before the change. After another file's change, it is current only as far as the settle window
  can tell, on every server. On TypeScript the server can publish such a set, so #6 must not
  take an unmarked TypeScript answer as current until #13 lands.
- The probe for #13 used a raw LSP client and the same race, outside pharos. A
  `typescript.tsserverRequest` for tsserver's synchronous diagnostics, sent right after the
  `didChange`, answered for the new text in 59 of 59 trials. The race hit in 46 of them. It
  took 3 to 20 ms for small files and about 0.8 s for a 5000-line file, about when the correct
  publish arrives. It includes a tsserver plugin's diagnostics.

## Other observations

**pyright and gopls take about 58 s to start, before #3 runs at all.** Each run's daemon log
shows the gap between `spawn_started` and the readiness probe:

- pyright: 57.8 s on 2026-11-16;
- gopls: 58.5 s on 2026-11-18 (58.59 s to the first answer in the full run; pyright's first
  answer took 64.70 s under load);
- pyright: 58 s on 2026-11-13, with pharos 0.2.2, in the installed pharos's own session logs.

That 2026-11-13 run came before #3 existed, so this predates #3. Both servers have a readiness
token (`Indexing`, `setup`). typescript-language-server has none and starts in under a second.
The 60 s default `ready_timeout_ms` fits the gap, which suggests the post-initialize readiness
drain runs to its cap. Not investigated further. It is outside #3.

## Related

- [ADR-038](adr/038-document-resync-from-disk.md): the decision this run gates.
- [ADR-034](adr/034-shared-daemon-and-native-shim.md): the shared daemon the second session joins.
- `test/daemon/integration.py`, scenarios `resync_*`: the same behaviour against the stub.

## Addendum, 2026-11-18: F4 fixed by asking tsserver (#13, ADR-039)

The driver's ts section gained a hard check of F4's race. Ten busy open files, a file with
errors, another file opened (tsserver starts re-checking every open file), then the file saved
clean and asked about at once, eight times. On the #13 branch, with typescript-language-server
answering through `diagnostics_mode = "tsserver"`, all 8 came back clean, the slowest in 0.01 s
(load average 1.77). On 0.3.0 the review's run of the same race came back stale 8 of 8. The other
ts checks passed too, now in 0.01 s where the push path took 0.41 s: the comment-only edit, a.ts
seeing b.ts's new signature (TS2554, the other-open-document re-sync), and the deleted file.
Coverage limit (c) above no longer holds for that check.

