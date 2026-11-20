# 043. Tell servers about files changed on disk

**Status:** Accepted (2026-11-20; Logan chose option (a) and asked for the hardening below)
**Date:** 2026-11-20
**Issue:** [#10](https://github.com/LoganBresnahan/pharos-mcp/issues/10)

## Context

ADR-038 makes pharos re-sync the documents it holds open before each question. A file pharos
never opened was left to the server, on the assumption that servers which rely on their
client to watch files fall back to watching the disk themselves. That holds for
typescript-language-server, but not for gopls or pyright (measured 2026-11-18):

| server | dependency created after start | dependency deleted | dependency's signature changed |
|---|---|---|---|
| typescript-language-server | TS2307 → none | none → TS2307 | none → TS2554 |
| gopls | BrokenImport stays | stays clean | stays clean |
| pyright | reportMissingImports stays | stays clean | stays clean |

pharos neither offered nor sent `workspace/didChangeWatchedFiles`, and had no file watcher:
ADR-038 rejected one, and ADR-030 rules out NIFs.

## Options

- **(a) Scan before a question.** Walk the workspace, compare each file's stamps with what
  pharos saw last time, and send `workspace/didChangeWatchedFiles` for the differences the
  server's registered watchers match. Pure BEAM, no dependency.
- **(b) `git status --porcelain` plus untracked files** in a git workspace, (a) elsewhere.
  Cheaper, but blind to ignored files servers read (generated code, build outputs).
- **(c) A separate watcher executable** (inotify, FSEvents), the shape ADR-030 prefers over
  native code in the BEAM. Precise and nearly free per question, but new native code on two
  OSes with its own lifecycle.
- **(d) The hook path only:** the files an agent's tools touched (#6's payload knows them).
  Covers agent writes, not checkouts or builds.

## Decision

**(a), bounded and hardened.** (c) stays a later option behind the same interface
(`watch.before_question`); (d) could feed it as a fast path.

### Which servers get events

pharos offers `workspace.didChangeWatchedFiles` (`dynamicRegistration`,
`relativePatternSupport`) at `initialize`, and scans only for servers that then register
watchers: registering is how a server says it relies on its client. A server that registers
none gets no scan. Offering registration changes some servers' behaviour, not only pharos's:
a server with a watcher of its own may hand watching over to the client once offered. So
each bundled server was measured both ways (2026-11-20, a tiny project per language; probes
`watchprobe.py` and `selfwatch.py` in the session's scratchpad):

- **registers** — the watchers it registers once offered (`rel(...)` is a RelativePattern);
- **before / after / events** — a file used by the open document is created on disk, and the
  open document is re-checked. *before*: registration not offered (pharos 0.3.x); *after*:
  offered, no events sent; *events*: offered, and Created sent, as pharos now does.

| server | registers | before | after | events | bundled |
|---|---|---|---|---|---|
| rust-analyzer | `rel(**/*.rs)`, `rel(**/Cargo.{lock,toml})`, `rel(**/rust-analyzer.toml)`, its config dir | **sees** | misses | sees | not offered (`watch_files = false`): keeps its own watcher |
| gopls | `rel(**/*.{go,mod,sum,work})`, `**/*.{mod,work}` | misses | misses | sees | scanned |
| pyright | `**/pyrightconfig.json`, `**` | misses | misses | sees | scanned |
| jdtls | `**/*.java`, `**/src/**`, build files | misses | misses | sees | scanned |
| zls | `**/*.{zig,zon}` | sees | sees | sees | scanned (harmless: it reads imports from disk on demand) |
| haskell-language-server | `**/*.hs`, `**/*.lhs` (+ boot files), the `.cabal` file | **sees** | misses | sees | not offered (`watch_files = false`): keeps its own watcher |
| gleam-lsp | `**/gleam.toml` (Change only) | sees | sees | misses (sent a source file its globs don't cover) | scanned: only `gleam.toml` changes match, which pharos sends; it reads sources itself. Don't set `watch_files = true` for it: an event for a source file made it miss the change |
| clojure-lsp | `**/*.{clj,cljs,cljc,cljd,edn,bb,clj_kondo}` | misses | misses | sees | scanned |
| elp | `TARGETS.v2` / `BUCK` build files, `.elp_lint` config, in the project and the OTP install | misses | misses | misses (a `.erl` file, as `watch_files = true` would send) | scanned: only in-project build files can match. A server limit: elp acts on no event for a source file, so a module created on disk stays unknown to it until it's opened |
| next-ls | `**/*.ex`, `**/*.exs`, templates | misses | sees | sees | scanned (but see the re-check below: it acted on no event there) |
| terraform-ls | `.terraform` lock and module files | — | — | — | scanned (config files only) |
| ruff | `ruff.toml`, `.ruff.toml`, `pyproject.toml` | — | — | — | scanned (config files only) |
| typescript-language-server, clangd, perlnavigator, vscode-html/-css/-json, yaml-language-server, marksman, lua-language-server, bash-language-server | none | — | — | — | not scanned (they register nothing) |
| ruby-lsp | `**/*.rb`, RuboCop config files | misses | misses | sees | scanned |

rust-analyzer and haskell-language-server have a working watcher of their own that they stop
using when offered registration (*before* sees, *after* misses), so they aren't offered it:
their `initialize` is exactly as before. gopls, pyright and jdtls have no self-watching
fallback (*before* misses), so the scan is a pure gain for them. clojure-lsp and ruby-lsp
are the same; next-ls also caught the new file once offered registration, even before any
event. zls reads imports from disk on demand, so the scan changes nothing for it. gleam-lsp
reads its sources itself and watches only `gleam.toml`, so it gets only that, and offering
registration changed nothing for it. elp registers only build-file globs and ignores events
for source files even when sent (`watch_files = true`): a limit of elp, noted in the README.
(The first probe's fixtures for zls, clojure-lsp and next-ls drew no error; the second used
textDocument/definition on a symbol in the created file. The first probe's ruby-lsp fixture had
a Gemfile, which made ruby-lsp run bundler instead of answering `initialize`.)
`watch_files` overrides per server: `false` stops offering and scanning; `true` scans even
without registrations, matching the language's file extensions.

Re-checked by the verification (2026-11-20, its own fixtures, missing → created → changed →
deleted → recreated, hover, definition and diagnostics): gopls, pyright, jdtls and ruby-lsp
were right at once in every phase (never before #10); typescript-language-server and
rust-analyzer the same with and without #10. Where it disagrees with the table above:

- **next-ls** never acted on the change, even after 5 s, though the events it got were right.
- **clojure-lsp** acts on Created and Changed asynchronously, within about 5 s, and after a
  delete keeps reporting the deleted function's arity error.
- **zls** sees creates and deletes (without #10 it kept serving a deleted file) but not a
  signature change, with or without #10.
- **haskell-language-server** and **gleam-lsp** saw nothing on either build with those
  fixtures.

These are the servers' own limits: pharos sends the events their watchers ask for.

### The scan

- **Stamps:** each regular file's (mtime, ctime, size, inode), from the one
  `file:read_link_info` the walk makes. ctime catches a restore that keeps the old mtime
  (`cp -p`, `tar x`, `rsync -a`); the inode catches a file replaced by rename.
- **Where:** under the workspace root. Skipped wherever they are: `.git`, `.hg`, `.svn`,
  `node_modules`, `.venv`, `__pycache__`, `.gradle`, `.idea`, `.vscode`, `.zig-cache`,
  `.mypy_cache`, `.pytest_cache`, `.ruff_cache`, `.tox`, `.elixir_ls`, `.dart_tool`, `.next`,
  `.stack-work`: names that are never sources. Skipped only beside the build file that makes
  them a build's output: `target` (beside `Cargo.toml`, `pom.xml`, `build.sbt`,
  `build.gradle[.kts]`, `project.clj`), `_build` (beside `mix.exs`, `rebar.config`,
  `dune-project`), `deps` (beside `mix.exs`, `rebar.config`), `zig-cache` (beside `build.zig`),
  `build` (beside `build.gradle[.kts]`, `gleam.toml`, `CMakeLists.txt`), `dist-newstyle`
  (beside a `*.cabal` file or `cabal.project`). A `venv` is skipped when it holds `pyvenv.cfg`.
  Elsewhere those names may be sources (a Go package `deps`, a Java package `target`), so
  they're walked; so are `build/` and `dist/` beside `package.json`, which are sometimes
  sources. Plus the language's
  `vendor_segments`, a multi-segment one (Ruby's `/vendor/bundle/`) matched at the end of a
  directory's path. Symlinked directories aren't followed. Events are filtered by the server's
  watchers (globs and WatchKind) and never name a document pharos holds open, nor the
  question's own file: both are synced right after (didOpen or didChange, ADR-038).
- **Budget and interval:** a scan walks at most 200 ms (`PHAROS_WATCH_BUDGET_MS`), and never
  past the question's own deadline: it gets the lesser of the budget and half what's left of
  the call's timeout, so the reply has the other half to arrive. A question waits for its
  scanner at most the budget plus 1 s, never past its deadline, then goes on labelled. A scan
  squeezed below the budget by the deadline gives half its time to the asked file's directory
  and its ancestors and the rest to the first pass, if that hasn't finished, so a run of short
  questions still completes it; it leaves the interval, the tree's cheapness and any later pass
  as they were, so a short timeout doesn't make a small tree look expensive. The question sends
  the scanner its request and waits with a bounded receive: a reply that comes too late is
  never fatal (a timed-out `process.call` raises, and took the question with it in the first
  revision). The reply goes to an alias of the asking process, dropped when the wait ends, so a
  late reply never lands in its mailbox. The scanner keeps the events of each reply until the
  question has put them in a batch the proc has written, so a reply that came too late, or a
  question that failed before its batch, has them sent again with the next one, instead of the
  changes being lost (the scan has already recorded those files as seen).
- **The deadline, measured:** the scan fits half the time left. What follows it doesn't
  shrink with the deadline: the wait for the proc to write the sync batch (ADR-038, up to its
  own 2 s cap; cutting it short could send the question before the events) and the request
  itself. A 50 ms question answered in 74–80 ms on a 50k-file tree, a 250 ms one in 271–301 ms.
- One scanner per proc: when two questions start one at once, the one that loses the race to
  register stops on its own, without the clean-up a proc's death runs (which would drop the
  winner's registration and the proc's watchers, and no scan would run again). Each question's
  scan writes one debug line (`pharos/lsp/watch`, "watched-files scan": registered watchers,
  outcome, events), so a support log tells a skipped scan from one that found nothing. The budget is checked before each directory
  and every 64 entries inside one, so a wide directory doesn't overrun it: a visit cut short is
  dropped and done again whole by the next scan. A scan's first directory always finishes, so
  every scan makes progress; one directory's visit is therefore the most a scan can overrun.
  A workspace whose whole pass ran inside one scan in at most half the budget becomes *cheap*
  and is scanned before every question; it stays cheap while a pass still runs inside one scan
  within the budget, so one slower pass doesn't flip a small tree back and forth (and its
  labels with it). Any other is scanned at most every 2 s, resuming where the last scan
  stopped.
- **Order:** the asked file's directory and below first, then each ancestor's own files up to
  the workspace root (the nearest root-marker directory, so this is the file's package), then
  the pass in progress. A change next to the file asked about is found in the first budget even
  on a large tree. A question without a file (workspace symbols) goes straight to the pass.
- **First pass:** records the baseline, and reports every file whose mtime or ctime is at or
  after the second the server was spawned: the server may have read it before the change, or
  it may be new since. File times can't tell those apart, so it goes as Created where the
  server's watchers want creations (a server re-reads a file it already had), else as Changed
  (gleam-lsp watches `gleam.toml` for changes only). Whole seconds can only over-report.
- **Same-second changes** (git's racily-clean problem): a file stamped at or after the second
  its directory was visited is racy; its SHA-256 is kept, and a later visit that finds its
  stamps unchanged compares contents. Comparing contents, not re-reporting, because racy files
  are the ones being written during an edit loop or a build, and each spurious Changed makes
  gopls or pyright re-check a package; hashing them is cheap (page cache, few files). Over 1 MB,
  a racy file is re-reported instead.
- **Deleted:** found per directory, as names missing from its listing; a deleted directory
  takes every file recorded under it.
- One scanner actor per LSP proc holds the state. It monitors the proc and stops with it, so a
  restarted server starts a fresh baseline. Not supervised, and unlinked from the question that
  started it: a scan that fails or times out leaves the question to go on, labelled. A proc's
  registered watchers and spawn time are dropped when the pool forgets the proc, whether or not
  a scanner ever started for it.

### Freshness

The events found go to the server in the question's own sync batch (ADR-038), first, ahead of
the documents' syncs; a workspace-wide question, which syncs no document, sends them as a batch
of its own. So a batch follows every event, and ADR-038's rule applies: a diagnostics entry
cached before the batch is carried over until the server publishes again or the batch's settle
window (2 s) passes, and `get_diagnostics` waits for that within its timeout. The question
waits until the proc has started writing the batch, so it reaches the server after the events.

As first built, the events were sent on their own, outside any batch. Hover and definition were
right at once, but `get_diagnostics` right after a dependency changed answered the set cached
before the change, as fresh, in 1–16 ms, on gopls, jdtls and clojure-lsp (the verification,
2026-11-20); it was right about 2 s later, once the server had republished. A test stub that
republishes after an event shows it: the old build answers the old set, this one the new.

### Labels

An answer is complete only when a whole pass ran within its own question's scan. Otherwise it
carries one sentence naming the workspace and why: "Files changed on disk under /w may not
have reached the server yet: …. Ask again in a few seconds if this answer looks out of date."
The middle says which case it is:

- a pass under way: "pharos checked 120 of about 1400 directories before this answer and checks
  more on later questions, at most every 2 s";
- the first pass under way: "pharos is building its first record of the tree (120 directories
  so far) and adds to it on later questions, at most every 2 s";
- the scan skipped by the interval: "pharos checks a tree this size at most every 2 s and
  didn't check before this answer";
- no time left: "pharos had no time left in this question's timeout to check for them";
- the scanner not answering: "pharos couldn't check for them before this answer".

- get_diagnostics: `pharos.files_unchecked`, beside `carried_over`;
- `pharos diagnostics`: status `unsure`, reason `files_unchecked`;
- find_symbol: `files_unchecked` in its result object;
- every other tool: a second text content block.

A complete answer carries none and is byte-for-byte what it was. The second block follows
ADR-032's root attribution: the payload stays block one, so a client that reads `content[0]`
is unaffected; MCP models `content` as an array. ADR-023's compact format is a property of
block one ("a text content block"), and the note never enters it.

## Measured (2026-11-20, WSL2 ext4, warm cache)

Full scan with diff, median and range, 8 runs alternating (mtime, size) and the hardened
(mtime, ctime, size, inode):

| tree | files | (mtime, size) | hardened |
|---|---|---|---|
| synthetic, 40 packages | 2,000 | 33.6 ms (30.9–45.2) | 37.4 ms (29.9–45.6) |
| this repo (bench data, npm/ copies) | 154,752 | 5.63 s (4.60–6.56) | 5.97 s (5.08–6.43) |

The hardened compare costs 4–11% (a fixed-order run had shown +48%: order and garbage
collection). Racy files: 20 files of 25 KB hashed in 0.4 ms. Budgeted from the asked file:
the 2k tree is covered whole in the first budget (22 ms), so it is cheap and scanned every
question; on this repo the first 200 ms covers 8.5% of the files including the asked file's
directory, and a pass takes 13 budgets.

## Consequences

- gopls, pyright, jdtls and the other registering servers see files that agents, checkouts
  and builds create, change or delete, by the next question on a small tree.
- On a large tree, most answers are labelled unsure until a pass fits between two questions.
  That is the honest label; a watcher, (c), is how a large tree would get fresh answers.
- A cost per question on registering servers: about 35 ms on a 2,000-file project; at most the
  budget, and at most every 2 s, on a large one.
- rust-analyzer's and haskell-language-server's initialize is unchanged; every other server
  is offered watcher registration, which changes its spawn fingerprint (ADR-034), so daemons started before the
  upgrade don't share LSPs with ones after.
- `get_diagnostics` right after an event can wait up to the settle window (2 s) for the server
  to republish, within its timeout, as after any other change ADR-038 covers.
- Memory: the scanner holds every regular file's stamps under the root (minus the skipped
  directories), whatever the server's globs, since globs can change on re-registration. About
  430k words for 2,000 files (≈3.4 MB); a 150k-file tree costs tens of MB per watched server.
- New: `watch_files` per server in pharos.toml, `PHAROS_WATCH_BUDGET_MS`, the
  `files_unchecked` marker.
