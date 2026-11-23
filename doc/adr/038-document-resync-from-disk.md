# 038. Re-sync open documents from disk on every question

**Status:** Accepted (2026-11-18); known limit F4 addressed by [ADR-039](039-tsserver-diagnostics-asked-directly.md)
**Date:** 2026-11-16, revised 2026-11-18 after review (deleted files, the settle window, which
servers watch the disk, and one known limit on TypeScript)
**Issue:** [#3](https://github.com/LoganBresnahan/pharos-mcp/issues/3)

## Context

pharos told a language server about a file once and never again. `pool.gleam`'s
`handle_ensure_open` kept an `opened` set keyed by `(language, workspace, server_key, uri)`. The
first question about a file sent `textDocument/didOpen` at `version: 1`. After that the key was
present, so the call did nothing and dropped the `content` that `session.gleam` had just
re-read from disk. The set was cleared only when the server was evicted (idle stop, crash,
`daemon stop`). Nothing in `src/` sent `didChange`, `didSave`, `didClose` or
`workspace/didChangeWatchedFiles`. `initialize` even told servers so: it advertised
`synchronization.didSave: false` and `publishDiagnostics.versionSupport: false`.

Under LSP an open document belongs to the client. "The document's content is now managed by
the client and the server must not try to read the document's content using the document's
Uri". Only `didClose` hands it back to the disk. So once a file had been asked about, every
later answer described the text it had then: diagnostics, hover, definition and references.
That held for the file itself and for every answer that depends on it, such as a type defined
there or a reference found there. It lasted until the server stopped. This was verified on
2026-11-13 against pharos 0.2.2 with pyright and ruff (repro in #3). Two things made it worse:

- **The shared daemon** (ADR-034). One session's first question pinned the text for every
  session.
- **The diagnostics cache** (`diagnostics_cache.gleam`). Nothing knew which text an entry
  described, so a stale entry was served as current. The cache also outlived an LSP restart.

Opening each file only once was deliberate. The cache's FFI module said why: "to avoid
rust-analyzer's content-modified cancellations". On any write, rust-analyzer cancels every
in-flight query, and that request fails with `-32801`.

pharos's job in the stack (geex's `doc/stack.md`, rule 1: "content meets on disk") is to answer
about what is saved. Agents write with their own tools, editors save, and pharos never receives
file text from a peer. That only works if a change on disk reaches the server. #6 (the
post-edit diagnostics hook) and the trial in #7 measure nothing until it does.

What servers do after a change matters for diagnostics, and they don't agree. This was checked
in the source on 2026-11-16 and is to be confirmed in the dogfood:

- gopls re-publishes the changed file after every change ("diagnostics should be re-sent after
  each change", golang/go#50267). It does **not** re-publish other files whose diagnostics
  stayed the same; the review measured that on 2026-11-18.
- rust-analyzer does **not** re-publish diagnostics that haven't changed (`diagnostics.rs`,
  `set_native_diagnostics`: "don't signal an update if the diagnostics are the same"). So an
  edit that leaves a file's errors as they were produces no publish at all. Its `cargo check`
  results arrive later, after `didSave`, as further `publishDiagnostics`. `$/progress` only
  reports that the check is running or has finished.
- rust-analyzer and pyright both stamp a publish with the document's version at the time they
  publish, not the version they analysed (rust-analyzer's `main_loop.rs`, pyright's
  `getClientVersion()` read when the entry is built). So a publish's `version` proves nothing
  about freshness. It only lets a client discard a publish that admits to being old.

## Decision

On every question to a server, pharos brings every document it holds open on that server back
in line with the disk. It also keeps track of which text each cached diagnostics entry
describes. It does not watch files.

**What gets sent.**

- The pool keeps, per document, the version and SHA-256 last sent, whether it is open, and when
  it was last the subject of a question. A closed document keeps its version, so a reopen goes
  out at the next version and never goes backwards.
- A question first asks the pool which documents are open on that server. The caller (never the
  pool actor) reads each of them, plus the file asked about, and hashes them. The pool then
  plans every document:
  - **The subject:** open it if it isn't open (version 1, or one past its last version), re-sync
    it at version + 1 if it changed, and otherwise leave it. If its file is gone (or isn't
    text), close it if it's open and never open it: it is answered as a file that never
    existed.
  - **The other documents:** only the ones still open, and they are never opened. Each one is
    re-synced if it changed, closed if its file is gone, and otherwise left.
- Only the subject counts as "used" for recency, at planning time. At most 32 documents stay
  open per server. Past that, the least recently used are closed (never the subject), and the
  server goes back to the disk for them. pharos doesn't send
  `workspace/didChangeWatchedFiles`, so a change to a file pharos doesn't hold open reaches
  a server only if the server watches the disk itself. Measured on 2026-11-18 (a file created,
  deleted or changed after the server started, asked about from the file importing it):
  typescript-language-server sees all three; gopls and pyright see none. rust-analyzer is not
  measured. That gap is pharos-mcp#10, not this ADR (ADR-043 closes it).
- The proc, which holds the server's `textDocumentSync` capability (resolved the way VS Code's
  client does it), writes the notifications:
  - **Open:** `didOpen`. pharos opens what it asks about whatever `openClose` says, which is
    today's behaviour.
  - **Close:** `didClose`.
  - **Change, sync kind Full or Incremental:** one `didChange` whose single content change
    carries only `text`, with no `range` and no `rangeLength` (amended (A), below: an
    Incremental server now gets the same text as a replace ranged over the whole document). LSP 3.17 says such an event "is
    considered to be the full content of the document". It doesn't say whether a server that
    advertises Incremental must accept it. gopls accepts exactly one such event and rejects a
    batch. Versions only have to increase ("doesn't need to be consecutive"). Then `didSave`
    when the server asks for it: the options form's `save` (`true`, or `{includeText}` to send
    the text too), or the number form, which VS Code treats as a save without text. The file
    really was saved, and some servers only run their heavier checks on save (rust-analyzer's
    `cargo check`).
  - **Change, sync kind None:** `didClose`, then `didOpen` at the new version. That's never a
    second `didOpen` without a close, which the spec forbids. Since pharos opened the document
    anyway, it mirrors that on change, and a server that really reads the disk ignores both.
    Sending such servers nothing at all, `didOpen` included, waits on a capability survey of
    the bundled servers.
- `initialize` changes to match: `synchronization.didSave: true` and
  `publishDiagnostics.versionSupport: true`.

**How the pool, the proc and the caller agree on order.**

- **The pool never waits on a proc.** It used to call the proc synchronously, so a proc busy
  with a long request (procs run one request at a time) blocked the pool actor, and every
  session with it, for up to 5 s. Now the pool records the plan and sends the proc one batch
  message. Every batch comes from the pool actor, and a single sender keeps each document's
  syncs in version order.
- The pool writes an **expected** row per synced document, `(uri, server, proc) → version`,
  when it records the sync. The proc writes a **stamp**, `(uri, server, proc) → (sequence,
  version)`, right after it writes the notifications. The caller polls the stamps until every
  open document has reached its expected version. It checks once immediately, because an idle
  proc stamps within microseconds, then backs off, for up to 2 s. Only then does it send its
  question. The stamp is the acknowledgement, and anyone can see it. It also covers the fast
  path: a caller that finds nothing to send still waits for an earlier caller's sync that may
  still be queued.
- A failed write puts a failure marker in the stamp, so waiters stop at once. The proc keeps
  running: a write fails only when the port is gone, the question that follows fails, and the
  tool layer's transport-error path evicts the proc and retries. Stopping the proc instead
  would restart it under `pharos_lsp_dyn_sup`, whose restart limit every LSP in the daemon
  shares.
- Every cache row is keyed by the proc as well as `(uri, server)`. In a shared daemon one URI can
  be open under the same server id in two procs: a dependency file routed to whichever workspace
  asks (ADR-032), or two ADR-034 spawn variants. A proc's rows are dropped when the pool closes
  it or sees it die.

**Knowing which text a diagnostics entry describes.**

- Each entry is stamped with a node-wide monotonic sequence number when the proc caches it. The
  proc both writes the syncs and reads the publishes, in one actor, so an entry and a sync
  stamp order exactly.
- A file's diagnostics depend on the other files the server has. So the pool also numbers each
  batch it sends a proc, and the proc stamps the batch, with the time, as it starts writing it.
- An entry is **fresh** when the stamp shows its document's expected version written and the
  entry came after it, and the last batch on the proc is written and the entry came after it
  or that batch's **settle window** (2 s from the write) has passed. It is **carried over**
  otherwise: it describes an older text, the server held back an unchanged set, or a sync isn't
  written yet. An entry from before pharos closed the document, or while a close is on its
  way, is **missing**, like no entry at all: it describes text pharos no longer holds open,
  possibly a file that's gone. Nothing is dropped on a sync, so a server that publishes before
  the lookup is never wiped.
- So after another document changes, an unchanged file is carried over only for the window.
  Past it, a server that hasn't re-published the file is taken to have left its diagnostics as
  they were. gopls and rust-analyzer never re-publish an unchanged set, so without the window
  such a file would stay carried over until its own diagnostics changed. An entry from before
  the document's **own** latest sync stays carried over past the window: the server has said
  nothing about the text it has now.
- A publish whose `version` is lower than the version that proc last synced is not cached. That
  only catches publishes that admit to being old (see Context). Freshness comes from the stamp
  order.
- **Known limit (F4): "fresh" means published after the sync, not computed for the new text.**
  The two coincide only when the server can't publish a set it computed before the change, and
  a publish's `version` doesn't show which (Context). typescript-language-server sends no
  `version` at all. Its diagnostics come from tsserver's asynchronous re-check of every open
  file, so a set computed for the previous text can arrive just after the change and read as
  fresh. The review measured it on 2026-11-18. Another file was opened, so a re-check was in
  flight, and then a.ts was saved clean and asked about at once. All 8 of 8 trials came back
  with the old errors, unmarked. On the wire the stale set arrived 25 ms after the `didChange`,
  and the correct one 356 ms after. gopls wasn't affected (0 of 10). pyright and ruff are asked
  directly (Pull), so they aren't exposed. rust-analyzer isn't measured. The fix is to ask
  tsserver for the file's diagnostics directly, which a probe showed answers for the new text
  every time: pharos-mcp#13.

**What `get_diagnostics` does with that.**

- **Fresh:** answer from it.
- **Carried over:** wait for what is left of the last batch's settle window. The window runs
  from the write, not from the question, so asking again later doesn't wait again. If a fresh
  entry comes, answer from it. If the window passes and the entry was carried over only by
  other documents' changes, it is fresh by then. Otherwise answer from the carried-over entry
  and say so in the result (`pharos.carried_over`).
- So `pharos.carried_over` means one of two things. Either the server hasn't published since
  **this** file changed: it held back an unchanged set, or it hasn't finished. Or the call's own
  timeout ended inside the window after another file changed. Once a file that didn't change
  itself has sat out one window, it is never marked. A consumer (#6) should take a marked
  answer as unsure. An unmarked answer was published after this document's own latest sync.
  It describes the current text only when the server can't publish a set computed before the
  change. After another file's change, it is current only as far as the window can tell
  (Consequences). On TypeScript the server can publish a set computed before the change
  (F4, above), so #6 must not take an unmarked TypeScript answer as current until
  pharos-mcp#13 lands.
- **Missing:** wait for a first publish. That includes a deleted file asked about: its old
  entries are not served, and a server that clears a closed document's diagnostics publishes an
  empty set for it.
- Both waits come out of the call's own `timeout_ms`. They poll the cache from the caller's
  process and no longer drain inside the proc actor (`WaitForPublish` / `drain_loop` are gone).
  That drain held every session's requests to that server for the whole wait. The proc already
  caches publishes while idle (`handle_port_message`) and while in a request
  (`lifecycle.wait_for_response`).
- **A server that reports nothing in time is named, never counted as clean.** The multi-server
  merge path used to turn a timeout into `[]`, which reads as a file with no errors. It now
  lists those servers under `pharos.not_reported`, and a merge where no server reported is
  `NoDiagnosticsObserved`. A pull answer with no items is now an empty list, not "nothing
  observed".

Out of scope:

- Files pharos doesn't hold open, such as a `git checkout` or files nobody has asked about.
  Servers that watch the disk see those changes; gopls and pyright don't (measured above).
  Telling them is `workspace/didChangeWatchedFiles` from pharos: pharos-mcp#10.
- Knowing when a server's diagnostics have *settled*, for example rust-analyzer's `cargo check`
  arriving seconds after its native diagnostics. #6 needs that, and #3 doesn't.

## Consequences

- Answers follow the disk: for the file asked about, for the files it depends on that pharos
  has open, and for every session sharing the daemon. TypeScript diagnostics also have F4
  (below).
- Each question reads and hashes up to 32 open files on that server. That's cheap next to an
  LSP round trip, and it's why the cap exists.
- The question's own timeout starts after the stamp wait. So when a proc is busy, a call's wall
  time can exceed its `timeout_ms` by up to the 2 s cap. Past the cap the question is sent
  anyway; it still queues behind the sync, and the expected rows keep the diagnostics answer
  honest. A per-request deadline that covers the whole call joins the roadmap item "a tool call
  outlived its own `timeout_ms`".
- Right after an edit, `get_diagnostics` can take up to the 2 s settle window on a server that
  held back unchanged diagnostics, and its answer is then marked carried over. On a server that
  hasn't finished analysing within the window, the carried-over answer can miss new errors.
  The marker says so, and #6's settle logic is where that gets solved properly.
- After another file's change, the first question about an unchanged file can wait out the
  rest of the window; later ones don't wait. A server that takes longer than the window to
  re-publish a file affected by another file's change gets an unmarked answer from before the
  change. That is the window's trade: without it, every question about an unchanged Go file
  cost 2 s and came back marked for good (measured on gopls, 2026-11-18).
- **F4, a known limit on TypeScript.** Right after a change, while tsserver is still re-checking
  open files, `get_diagnostics` can return the previous text's diagnostics, unmarked. That lasts
  until the re-check publishes: about 0.35 s on a small project, longer on a big one. #6
  waits on pharos-mcp#13 for it.
- A deleted file asked about is closed, and nothing pharos cached about its old text is served
  again. A server that doesn't watch the disk (pyright) can still resolve the deleted file from
  what it read before, until pharos-mcp#10.
- Re-syncing causes `-32801` for in-flight rust-analyzer queries only when a file really
  changed (the hash check). Within one proc, requests run one at a time, so pharos never sends
  a change while one of its own requests to that server is in flight. Every request tool
  already goes through `session.request_with_content_modified_retry` (retries at 1 s and 3 s).
- **`didSave` makes rust-analyzer run `cargo check` after every re-sync of a Rust file, in the
  project's own target directory.** pharos's rust-analyzer config sets `checkOnSave: true`,
  `check.command = "check"` and no `cargo.targetDir`. So an agent's own `cargo build` or
  `cargo test` can wait on "Blocking waiting for file lock on build directory". pharos never
  sent `didSave` before, so this cost is new. For #7 it's part of what arm 3 costs, and the
  trial measures it. `cargo.targetDir` would separate the two at the price of a second build
  directory; that is a later, per-language config decision.
- An edit pharos makes itself (`apply_workspace_edit`) is picked up the same way, on the next
  question.
- pharos still answers only about saved text. Unsaved editor buffers remain ADR-028's territory.
- `doc/architecture.md` changes in the same commit: the request lifecycle, what blocks, and the
  timeout map.

Follow-up data, from the dogfood and the 23-language sweep:

- Each bundled server's `textDocumentSync` (`change`, `openClose`, `save`), which decides
  whether None-kind servers should get nothing at all.
- Whether each Tier-1 server accepts a range-less change.
- Which servers publish only on change.

**Amendment (as built, 2026-11-20; #30).** A publish stamped after
a document's sync could still describe the text before it. rust-analyzer republishes at the new
version with cargo check's results from the last check, and replaces them only when the check
it reruns on save ends, about 2 s later. So right after an agent fixed a Rust error,
`get_diagnostics` returned the old error as fresh. Since #12 pharos advertises
`window.workDoneProgress`, and rust-analyzer brackets each check in a progress token
(`rust-analyzer/flycheck/0`). Push mode now waits while the server still works on the sync:
- The proc records every `$/progress` it reads, stamped with the cache's sequence.
- `get_diagnostics` waits while a progress that began after the document's latest sync is
  running.
- A sync on a server configured to start a check on save waits up to its
  `save_check_grace_ms` for that check's begin to land (cargo check's comes just after the
  save). rust-analyzer has 500 ms; every other bundled server has 0.
- A progress running past 30 s is taken as stuck and no longer holds answers.
- The wait never passes the call's deadline. If the deadline comes first, the entry is answered
  marked carried over (unsure), never as fresh.

As first built, the grace went to every server that had reported progress at least once. That
cost ~0.5 s on the first question after an edit on gopls (0.515 s median against 0.003 s,
verifier), which reports progress but starts no check on save. And a server whose first progress
was a check on save got no grace at all: its first post-save answer could be taken as fresh
before the check began (3 runs in 600 in the stub). The grace is now a per-server setting,
`save_check_grace_ms` (pharos.toml, per language or per server), applied whether or not the
server has reported progress before. That removes both: gopls and the rest pay nothing, and a
configured server is covered from its first sync. A server that starts a check on save without
being configured can still be answered from before the check in the gap between the sync and
the check's begin.

Progress is tracked per server, not per document: a check one edit starts holds answers about
every document on that server while it runs (within each call's deadline, and the 30 s stuck
limit). That's deliberate: cargo check (and gopls's or pyright's analysis) covers every file, so
the other files' cached diagnostics are just as stale until it ends. The price is that a
long-running unrelated progress (a re-index) also holds answers while it runs, never past the
call's deadline. On the bundled ones, a follow-up question after an
edit costs up to the 500 ms grace on rust-analyzer only, and waits for cargo check there
(seconds, bounded as above).

**Amendment (A) (2026-11-20; #38, #35; replaces the #38/#35 amendment).** A re-sync's
`didChange` now takes the form the server's sync kind asks for:
- **Incremental:** one content change replacing the whole document, from (0,0) to the end of the
  text last sent to that server, recorded when it was sent (lines end at `\r\n`, `\n` or a lone
  `\r`; characters are UTF-16 code units, the spec's default, which pharos doesn't negotiate away).
- **Full:** the range-less full text, as before.
- **None:** close and reopen, as before.

`full_change_as_range` (pharos.toml, per language or per server) forces either form: `true` the
ranged one, `false` the range-less one, whatever the sync kind. Set per language, it applies to
the language's primary server and wins over that server's own key, as every per-language knob
does. Unset, which is every bundled
server, follows the sync kind. `pull_after_change_ms` stays a ruby-lsp-only setting (50 ms): it
can answer a pull that arrives right behind a change about the text before it.

Why: LSP 3.17's Incremental kind reads "documents are synced by sending the full content on open.
After that only incremental updates to the document are sent". A replace ranged over the whole
text is such an update; the range-less form is the Full kind's. ruby-lsp 0.26.11 advertises
Incremental and raises on the range-less form (`NoMethodError` in `Document#push_edits`), keeping
the old text, and its maintainers closed two reports calling that a client bug. The #38 fix
turned the ranged form on for ruby-lsp alone; (A) makes it the rule.

Evidence (verifier, 2026-11-20, pharos 7435276): every bundled server, each form, a chain of 16
edits × 3 (error moving, growth to ~100 lines and back, CRLF and back, no final newline, an emoji
as the last character, a one-character tail change), each followed by `get_diagnostics` and
`document_symbols`, judged against a cold open of the same text. "lines" = the lines carrying a
diagnostic match; "sym" = the documentSymbol answer matches.

| server | sync | range-less: lines, sym | ranged: lines, sym | note |
|---|---|---|---|---|
| rust-analyzer | Incr | 47/47, 47/47 | 47/47, 47/47 | |
| gopls | Incr | 47, 47 | 47, 47 | |
| typescript-language-server | Incr | 47, 47 | 47, 47 | |
| pyright (+ ruff, merged) | Incr | 47, 47 | 47, 47 | |
| **ruby-lsp** | Incr | **5/47, 5/47** (keeps the opened text; `Error processing textDocument/didChange` ×47) | **47, 47** | the only server where the form matters |
| zls | Incr | 47, 47 | 47, 47 | |
| clangd | Incr | 47, 47 | 47, 47 | |
| hls | Incr | 47 (3 unsure), 47 | same | no republish when diagnostics are unchanged, either form |
| perlnavigator | Incr | sym 95/95, diag 84/95 | sym 95/95, diag 82/95 | stale Perl::Critic entries in both forms |
| vscode-html / -css / -json | Incr | 47, 47 | 47, 47 | html has no diagnostics |
| yaml-language-server | Incr | 47, 47 | 47, 47 | |
| terraform-ls | Incr | 47, 47 | 47, 47 | |
| elp | Incr | 90/95, sym 95 | 89/95, sym 95 | an empty-then-real publish, both forms |
| jdtls | Incr | 91/95, sym 95 | 94/95, sym 95 | an interim empty publish, both forms |
| lua-language-server | Incr | 95/95 (1 unsure), sym 95 | 95/95 (9 unsure, each right, 2.04 s), sym 95 | see below |
| next-ls, clojure-lsp, marksman, gleam-lsp, bash-language-server, metals | Full | as ranged | right, with the same exceptions in both forms: next-ls's document symbols empty (an ArithmeticError inside it), marksman 6 unsure, metals offline lagging | under (A) they get range-less |

No Incremental server did worse with the ranged form, CRLF and UTF-16 tails included, and none
negotiated an encoding other than UTF-16. lua-language-server is the one soft difference: after
a ranged edit to a line carrying an unchanged diagnostic it sometimes publishes nothing, so
pharos waits 2 s and answers carried over (the content right every time). Clean-to-clean edits
behave the same in both forms (verifier's follow-up), and its real problem, no publish at all for
a file clean from open, predates (A) and is #46. So lua-ls follows the rule like the rest; the
setting can still force it range-less.

The earlier amendment's caution (a wrong end position would corrupt every Incremental server)
is what the evidence answers: the end is the end of the exact text pharos last sent, recorded as
sent, and all 18 Incremental servers agreed with it on every edit.

**A lone `\r`** (one not followed by `\n`) was the exception that evidence didn't cover: its
chain had none. LSP 3.17 counts one as a line break, and so does pharos's end, but
rust-analyzer, clangd and ruby-lsp count lines at `\n` only, and gopls tolerates one stray `\r`
but not a file of them (verifier-two, 2026-11-20). After pharos has sent such a text, the next
ranged change's end lies past their last line: rust-analyzer, gopls and ruby-lsp keep the old
text, and clangd drops the document, until it's reopened. So when the text last sent to a server
has a lone `\r`, a change that would go ranged goes as `didClose` + `didOpen` instead, as for
sync kind None: right whatever the server's line counting. Counting lines at `\n` only instead
isn't an option: typescript-language-server, pyright, jdtls and lua-language-server follow the
spec and would keep a stale tail. The range-less form has no end to misplace, so a Full server
is unaffected.

**Amendment (#45, 2026-11-20): interim and phased publishes.** The freshness rule takes the
first publish after a sync as the answer. Three servers publish one change in steps, and an
answer taken between the steps was unmarked and wrong (verifier's sweep on 7435276):

- **Phased publishes, per server: `publish_settle_ms`** (pharos.toml, per language or per
  server; Logan's choice). After the first publish that follows a sync, get_diagnostics waits
  until the server has published nothing more for that long, never past the call's deadline,
  and answers the latest. If the deadline comes first, the latest is answered marked as carried
  over. Bundled: elp 50 ms (it publishes `[]` then the real set at the same version on 280 of
  288 edits, at most 7 ms apart; pharos answered the `[]` about 5% of the time) and
  perlnavigator 1000 ms (polish 8: each check publishes `perl -c`'s new set with the previous
  check's Perl::Critic set, then the right set 307-336 ms later up to load 4 and 385-807 ms at
  load 10; the first measurement, "at most 58 ms apart", came from edits sent faster than the
  checks ran, and was 100 ms),
  and, since #46, lua-language-server 1000 ms (a partial or stale set, then the full one: on
  Kong up to 0.4 s apart quiet and at load ~4, 0.7 s with every core busy; 1-6 ms on a small
  project; verifier-two saw its first phase answered in 23 of 64 answers at 0).

  lua-language-server's largest gap between the phases of one change (raw, 2026-11-22; burners
  stopped by PID):

  | project | quiet | 4 busy loops | 12 busy loops (every core of 8) |
  |---|---|---|---|
  | small (2 files), 12 changes | 2 ms | 2 ms (load 2.5) | 6 ms (load 7.8) |
  | Kong, kong/db/schema/init.lua, 8 changes | 397 ms (load 2.9) | 400 ms (load 4.1) | 704 ms (load 11.2) |

  1000 ms is 2.5× the quiet and load-4 worst and 1.4× the saturated one, half the 2 s
  carried-over wait (Logan: correct before fast; 800 was the faster option). Every lua answer
  after a publish pays it, small projects included. A limit: at twice as many busy loops as
  cores (16 on 8, load ~9), verifier-two saw phase gaps of 0.9-1.6 s on settled Kong opens, and
  2 of 8 answered a partial set marked fresh (kong/init.lua 15 of 27, runloop/handler.lua 14 of
  32); quiet and at 8 loops, none. An adaptive settle is #54, after 0.4.0.
  perlnavigator also repeats its set about every 300 ms, so its value must stay well under
  that: at 500 ms the wait ran past the repeats, about 800 ms per answer. Every other server
  has 0 and is unchanged.
- **An unversioned empty publish from a server that versions its publishes is provisional.**
  It counts as carried over while the last batch's settle window runs, until a later publish
  replaces it; past the window it is the answer. clangd publishes such a `[]` on the didClose of
  a reopen, 6 ms before the real set (verifier-two). A server that never versions (jdtls, the
  tsserver path) is untouched.
- **A reopen sends didSave** when the server asks for saves, as a change does: rust-analyzer
  re-runs cargo check, and its entries from the text before the reopen are waited out like
  after any change (#30).

Two more cases, each a per-server value (Logan's choice, polish 2):

- **An empty answer waits: `empty_publish_settle_ms`.** jdtls sometimes publishes an interim
  `[]` without a version before the real set (about 0.5 s later, once in 62 edits a second apart,
  verifier-two), and it never versions a publish, so the provisional rule above can't see it.
  When the publish an answer would take is empty, get_diagnostics waits until that long after
  the sync's first publish, whatever the previous answer was, then answers the latest. A fixed
  window, not quiet: jdtls republishes `[]` about 0.95 s after a clean edit, and with quiet that
  repeat started the wait again (a clean answer took about 1.05 s, verifier). Bundled: jdtls
  600 ms, which covers the 0.49 s case with room and ends before the repeat, adding about 0.6 s
  to a clean answer only; others 0. With rapid edits the real set can still never come for an edit (1–4% of answers):
  then nothing tells that `[]` from a clean result.
- **The open's own answer waits: `open_settle_ms`.** perlnavigator publishes `[]` about 35 ms
  after a didOpen and Perl::Critic's set about 355 ms (3 of 3 cold opens, 344–357 ms); with 100 ms
  of quiet the open's answer was `[]`, unmarked. An answer while the document's latest sync is its
  didOpen waits until that long after the open's first publish, a fixed window like the empty
  one: perlnavigator publishes at about 35, 340, 1035 and 1345 ms after an open, then stops, and
  with quiet a question landing near the later two waited about 0.65 s more. Bundled:
  perlnavigator 650 ms (Critic's set came 299–394 ms after the open's first publish in
  verifier's runs, the next repeat about 1 s after it; the open's answer costs about 0.7 s),
  others 0; changes after the open are unaffected.
- **perlnavigator's stale Perl::Critic lines were pharos answering too early (polish 8).** After
  an edit, Critic entries seemed to keep the lines they had before it (15 of 15 edits in
  verifier's chain). That set was the first of the check's two publishes, which carries the
  previous check's Critic findings; the right set follows about 0.3 s later. It was listed here
  as a server limit until verifier read perlnavigator's validatePerlDocument; with a 1000 ms
  settle the answer is the right set.

**Amendment (#46, 2026-11-22): silence after an open, lua-language-server.** lua-language-server
publishes nothing for a file clean from its open, and nothing after a change that leaves a file's
diagnostics as they were (ranged or range-less), so `get_diagnostics` waited its whole timeout on
a clean file and answered carried over after ~2 s on an unchanged one. It has no pull diagnostics
(no `diagnosticProvider`, none registered dynamically, `textDocument/diagnostic` answers -32601),
so a timer is all pharos has.

Logan's option (1): silence counts only after the open. With `silence_settle_ms` set, no publish
since the document's didOpen counts as "clean" once the open and the last progress end are both
`silence_open_floor_ms` old and no progress is running; then the answer is `[]` (or a set
published before the open), marked `pharos.assumed_current`. After an edit silence never counts:
the wait is the old one, and with no publish the last set is answered marked carried over. A file
answered `[]` that way and still unpublished is recorded as assumed clean (not as a publish), so
an edit of it waits the settle and answers `[]` carried over in ~2 s, not its whole timeout.

Why not after edits: a timer can't tell "unchanged" from "not yet". Logan first chose a 600 ms
silence after edits too (option (a)); verifier-two's review found lua-language-server publishing
a change 1.33 s after it on Kong with no load (2 of 3 first edits of a 78 KB file), 0.94 s at
load ~25, and pharos noticing a publish on the wire up to 0.56 s late under load; a proxy
delaying publishes past ~0.75 s turned every error edit into the old set answered as current
(8 of 8). Each was a stale set claimed current, the one wrong answer the rule must not give.

Measured for the open (raw lua-language-server, a small project and Kong): an open's first publish
comes 623-905 ms after it with no progress on a small project (625-636 ms at load ~4, 873-1423 ms
with every core of 8 busy; a reopen after close up to 1.03 s); on Kong nothing for ~830 ms, then
"Loading workspace" progress to 4.3-5 s (15-23 s with every core busy), and the publish 90-130 ms
after it ends (129-340 ms busy), for a 4-line file. A big file takes longer: verifier-two's cold
opens of Kong's 2691-line kong/db/schema/init.lua published 488-584 ms after the load ended quiet
and 590-908 ms with 8 busy loops. The first version counted the floor from the didOpen only and
600 ms after a progress end, so that file came back `[]` as current (4 of 5 runs loaded, 1 of 9
quiet; #46 B2). The floor now counts from the later of the open and the last progress end, 2000
ms, over twice the worst gap; "Diagnosing workspace" begins 1.1-1.4 s after the load ends and
holds silence off from then. Small cold opens of a file with errors (up to 32 busy loops, load
~28) never came back `[]` either. Limits: while
"Diagnosing workspace" progress runs (Kong: until ~25-30 s after start) silence doesn't count, so
a clean file there waits as before; and on a machine slower than these, a file with problems whose
first publish comes after the floor would be answered clean; `silence_open_floor_ms` can be
raised for that. Bundled: lua-language-server 600 and 2000, others 0.

rust-analyzer needed no value: each edit publishes twice about 90 ms apart, and
#30's save-check grace already holds the answer for the second (24 of 24 right).

**Amendment (#56, 2026-11-23): elp, a reopen's clear and batch order; silence rejected.** elp 1.1
publishes a file only when its set changes (crates/ide/src/diagnostics_collection.rs: empty to
empty is no change), so a clean Erlang file gets no publish and `get_diagnostics` waits out its
timeout. It has no pull diagnostics. Two hardening changes ship; neither changes what elp answers
in pharos's usual traffic, where every change goes with a didSave (elp's sync capability asks for
it) and elp's didSave runs its checks of every open file again:

- **A reopen's clear isn't an answer** (`empty_after_close_is_clear`, elp). elp publishes `[]`
  without a version as it reads a didClose; on a close and reopen in one batch (a change to a text
  with a lone CR, amendment (A)) it lands after the reopen. The #45 rule already holds such a set
  as interim while the versioned one may follow (it came 108 ms later on real elp). If the reopen's
  checks are lost and none follows, the answer is now "no publish", not the close's `[]` at the
  deadline.
- **The asked file's didOpen goes last in its batch.** elp checks open files on a task pool, a
  write to its database cancels a running check, elp 1.1 drops a cancelled check's result (`.ok()`
  in crates/elp/src/snapshot.rs), and only a didOpen or didSave runs its checks again. Measured on
  elp directly, a didChange with no didSave after a file's didOpen lost that file's set 16 of 16
  times (none before it). In pharos's traffic the didSave that follows re-runs the check; the order
  covers a server whose changes go without one.

Rejected for 0.4.0, the #46 silence rule for elp (silence after an open counts as clean). It was
built with guards (no write after the open or in its batch, no outstanding project reload) and
failed verification: elp's lint run is one task over every open document, file by file, with no
progress and its results sent at the end (+1.17 s with 10 open documents), so a file was answered
`[]` while elp still computed findings for it. elp's per-file `telemetry/event`
(`NativeDiagnostics`, `ParseServerDiagnostics`) marks each file's end, but a run cancelled by a
didOpen sends one for every file it cut short, after that didOpen, so "every open file has
reported since the latest didOpen" can be met early. A rule with one open document per elp and
that telemetry is the plan after 0.4.0 (#56). A limit that predates 0.4.0: a first answer can be
elp's compiler set before its lint set arrives, unmarked.

## Alternatives considered

- **A batch of only `didOpen`s doesn't count for freshness.** It fixes the case the review hit
  first (gopls, after merely opening another file), but gopls stays quiet after real changes
  elsewhere too, and on a server that doesn't watch the disk, opening a file can change what
  others resolve to. The settle window covers both.
- **A quiet period after a publish without a `version`** (for F4): wait until no newer publish
  for the file has come for some time Q before trusting one. It adds Q to every TypeScript
  answer after a change. It still fails when tsserver's re-check outlasts Q, which grows with
  the project. Asking tsserver directly (#13) is deterministic. In the 2026-11-18 probe it cost
  no more than waiting for the correct publish: 3-20 ms for a small file, about 0.8 s for a
  5000-line one.
- **Carried over until the server re-publishes the file** (revision 3). On gopls that meant
  every question about an unchanged file waited 2 s and came back marked, for good, after any
  other file opened or changed: a signal #6 can't use.
- **Re-sync only the file asked about.** This was the first and second drafts. Every other
  document pharos had opened stayed frozen, because pharos had opened it, and answers about the
  current file depend on them.
- **Drop the file's cache entry on change and wait for a fresh publish.** This was the first
  draft. rust-analyzer doesn't re-publish unchanged diagnostics, so the most common edit, one
  that leaves the errors as they were, would wait out the 20 s timeout. That wait drained inside
  the proc actor, holding every session's requests to that server, and ended in "no
  diagnostics". A drop placed after the write could also wipe a fast server's fresh publish.
- **An acknowledgement message from the proc to the caller.** This was the second draft. It
  doesn't cover a caller that finds nothing to send while an earlier caller's sync is still
  queued, and it relies on messages from two senders arriving in causal order, which the BEAM
  guarantees only per sender pair. The stamp covers both.
- **Stop the proc when a sync write fails.** That restarts it under a supervisor whose restart
  limit every LSP in the daemon shares.
- **`didClose` + `didOpen` on every change.** This works everywhere, but it throws away the
  per-document state servers keep, and many servers clear a closed document's diagnostics. It is
  kept only for sync kind None.
- **Compare mtimes instead of content.** It's cheaper, but two writes in one tick look the same,
  and checkouts and some editors keep or reset mtimes. The read happens anyway, so hashing it is
  the honest test.
- **A file watcher in pharos.** That means native code or a polling loop (no NIFs, ADR-030), and
  it would re-sync files nobody is asking about. pharos answers questions, so syncing when one
  arrives is enough.
- **Only `workspace/didChangeWatchedFiles`.** It doesn't change an open document's text, which is
  the client's copy.
- **Pull diagnostics everywhere.** `textDocument/diagnostic` sidesteps both the stale-publish
  race and the unchanged-set suppression. It's already used where a server's pull is reliable
  (`diagnostics_mode = Pull`), and switching a server stays a per-language config decision,
  not part of this ADR. The dogfood (2026-11-16) found a related problem that predates this
  ADR. rust-analyzer advertises `diagnosticProvider`, and pharos advertises
  `textDocument.diagnostic` to every server. So rust-analyzer serves its own diagnostics by
  pull only, and pushes only `cargo check` results. pharos runs it as Push, so a never-edited
  Rust file gets no diagnostics until its full timeout, and native-only errors never arrive.
  The smallest candidate fix is to advertise pull only to the servers pharos runs in Pull mode.
  That fix, and which other Push-mode servers advertise `diagnosticProvider`, is follow-up
  work. It decides whether #7 can use Rust.
