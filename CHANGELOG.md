# Changelog

All notable changes to pharos-mcp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A `file://` URI with a host other than `localhost` is refused as not local, as RFC 8089
  reads it. That includes a relative `file://src/a.ts`, which reads as the host `src`, where
  0.3.5 resolved it against the working directory. The error says what to send instead:
  `file:///absolute/path` (or `file://localhost/absolute/path`, now accepted). Paths given
  to `pharos diagnostics` and the captAInHook payload aren't URIs and are unaffected (#24).
- `find_symbol` on a cold session retries an empty search on every server for 3 s after the
  first file opens, and for 1.5 s after a server's indexing progress ends, instead of a
  per-server table counted from spawn: servers missing from the table got no wait at all, and a
  real miss on bash-language-server or next-ls in the first 20 s could take up to 15 s. pyright
  (10 s) and bash-language-server (6 s) keep longer graces, for big projects they index without
  reporting progress, and bash-language-server now analyses up to 5000 files in the background
  (its default 500 left half of a large shell repo unfindable) (#44).
- `find_symbol` on elp resolves `module/function` and a module. elp 1.1's workspace search finds
  modules only, and its documentSymbol has no module node, so `util/helper` and `util` were
  not found. A module hit named like its file is now read as that file's root, and a bare name
  that isn't found says the server finds modules only (`workspace_symbol_modules_only`, bundled
  for elp) (#40).
- `find_symbol Type/method` drills on rust-analyzer and gopls. rust-analyzer puts methods under
  `impl T` symbols beside the type, and gopls names them `(T).m` at the top level, so a path
  through the type never matched. Both layouts now read as the type's members; a bare method
  name still matches once (#50).
- get_diagnostics no longer answers a server's first, partial publish as the settled set. elp
  publishes `[]` and then the real set for each change, and perlnavigator `perl -c`'s findings
  and then Perl::Critic's; an answer taken in between said "no errors" or missed the critic's
  entries, unmarked. pharos now waits until such a server has published nothing more for its
  `publish_settle_ms` (elp 50 ms, perlnavigator 100 ms, others 0; never past the call's
  timeout). An empty set published without a version, from a server that versions its
  publishes (clangd, when a document is reopened), no longer counts as the answer while the
  real one may follow, and a reopened document is saved when the server asks for saves, so
  rust-analyzer re-checks it (#45).
- get_diagnostics on jdtls waits up to 600 ms of quiet before answering an empty set (jdtls can
  publish an interim `[]` without a version about 0.5 s before the real one), and on
  perlnavigator the first answer after opening a file waits up to 400 ms (its Perl::Critic
  findings come about 0.35 s after the open). `empty_publish_settle_ms` and `open_settle_ms` set
  either for any server (#45).
- pharos answers a server's `workspace/diagnostic/refresh`, `workspace/semanticTokens/refresh`,
  `workspace/inlayHint/refresh`, `workspace/codeLens/refresh`, `workspace/inlineValue/refresh`
  and `workspace/foldingRange/refresh` requests with an empty success, as VS Code does. They were
  refused as an unknown method, about one per edit on rust-analyzer. pharos keeps none of those
  results, and asks afresh on every question; a server pharos pulls diagnostics from is told it
  may ask for a diagnostics refresh (#49).
- `find_symbol` finds a generic class on jdtls. jdtls names it with its type parameters
  (`Box<T>`, `Pair<A, B>`), so a strict match never found the project's class: `Box` answered
  the JDK's `javax.swing.Box`. Type parameters are now stripped for the strict match, in path
  segments and from a query of `Box<T>` too, on jdtls only (`generic_names_carry_params`): other
  servers name generics bare and keep angle brackets in real names (clangd's `operator<=>`). A
  class's or enum's own constructor (`Pair(A, B)`) no longer answers beside it (#39).
- A file that changed on disk reaches the server in the form its sync kind asks for: a server
  that syncs Incrementally gets a replace ranged over the whole document, a Full one the whole
  text as before. Through 0.3.5 every server got the range-less form, which LSP defines for the
  Full kind only and which ruby-lsp rejects: after its first edit, every answer about a Ruby file
  described the text before it. Measured on every bundled server: no Incremental server answered
  worse. After a text with a lone carriage return (one not followed by a line feed), which
  servers count as a line break or not, the next change reopens the document instead.
  `full_change_as_range = true | false` forces either form for a server (ADR-038
  amendment (A)).
- get_diagnostics on a file deleted from disk, on a pull server that answers a null report for
  a document it doesn't hold (ruby-lsp), answers that no diagnostics were observed. It used to
  fail with "diagnostic response decode failed" and restart the server.
- Files changed on disk that pharos never opened reach the servers that rely on their client to
  watch files (gopls, pyright, jdtls and others). Before, a file a checkout or a build created,
  changed or deleted stayed unknown to them: an import of a new package stayed broken. pharos
  now offers servers file-watcher registration, scans the workspace before a question for
  changes, and sends each server, as `workspace/didChangeWatchedFiles`, the ones its watchers
  match, in the question's sync, so get_diagnostics doesn't answer diagnostics cached before
  the change as fresh. A small tree is scanned whole before every question. A large one is
  scanned at most every 2 s, 200 ms at a time (`PHAROS_WATCH_BUDGET_MS`, and never past the
  question's timeout), starting next to the file asked about, and an answer given before the
  scan has covered the tree says so: a second text block, `pharos.files_unchecked` in
  get_diagnostics, `unsure` from `pharos diagnostics`.
  rust-analyzer and haskell-language-server aren't offered registration and keep their own
  watchers. `watch_files = false`
  turns it off for a server, `true` forces it (#10, ADR-043).
- pharos.toml values that used to do harm are ignored, with a warning, and the default stays
  (#32):
  - an unknown `diagnostics_mode` keeps the bundled mode (it was read as push, which left a
    pull or tsserver server's diagnostics waiting on publishes that never came);
  - a `tools` list in which no entry names a tool, category or preset keeps the earlier
    setting, `"default"` unless an earlier file set one (it exposed no tools at all; an
    explicit `tools = []` still does);
  - an `initialize_timeout_ms` of 0 or less keeps the bundled timeout (the handshake timed
    out at once, so the server never started);
  - a `[tool_config]` `default_timeout_ms` of 0 or less keeps the tool's built-in default
    (every call timed out at once);
  - a negative `idle_stop_secs` keeps the bundled idle limit, as a negative
    `PHAROS_LSP_IDLE_SECS` already did (the server was never stopped);
  - an empty entry in `file_extensions` is dropped (it claimed every file for that language).
- The project config may be named `pharos.toml` as well as `.pharos.toml`: the nearest
  directory up from the working directory holding either is read. Where both are,
  `.pharos.toml` is read and `pharos.toml` is ignored with a warning. A plain `pharos.toml`
  used to be ignored without a word. The nearest directory with either name wins, so a
  `sub/pharos.toml` now beats a `parent/.pharos.toml` it used to be skipped for. The global file stays `~/.config/pharos/pharos.toml`,
  and the project walk never reads it as a project file. A `.pharos.toml` in the global
  directory (never read) now warns (#32).
- `[bridge] port` is gone from the example config and `--print-default-config`: nothing reads
  it, since the editor-extension listener isn't built. A config that sets it still loads, with
  a warning.
- pharos.toml warns, once per file content, on stderr and in the daemon's log, about: a key it
  doesn't know (with the likely key it misspells); a value of the wrong type; a value it can't
  use as meant (an unknown `transport` or `diagnostics_mode`, a timeout of 0 or less, an empty
  `command`, an empty file extension, a `log.filter` clause it skips), saying what pharos does
  with it; an unknown tool or language in `[tool_config]` or entry in `tools`; and a missing
  key a table needs (a new language's `command` and `file_extensions`, a `[[servers]]` entry's
  `id`, a URI scheme's `fetch_method`); a key in the wrong table (`methods` belongs in
  `[[languages.<id>.servers]]`). How the file applies is unchanged; these used to pass
  without a word. Older names it still reads, such as `readiness_timeout_ms`, don't warn
  (#32).

## [0.3.5] — 2026-11-19

### Fixed

- A project whose path holds a character a URI escapes (a space, `#`, `%`) or a non-ASCII one
  couldn't be asked about. Through 0.3.4, an escaped URI (`my%20proj`) was never decoded, so
  no workspace root was found. A raw one reached the root but waited out the timeout on a
  Push server: the server published under its own escaping, and the diagnostics cache
  matched URIs as strings. And any non-ASCII path named a different file, because the file
  and spawn calls read each UTF-8 byte as a character. Now:
  - `file://` URIs are decoded and encoded (as vscode-uri does). A `uri` argument is always
    decoded, so a raw URI holding a literal `%XX` reads it as an escape; send escaped URIs.
  - The tools' `uri` arguments and the diagnostics cache use one canonical spelling.
  - Paths reach the file system as their own bytes.
  - `pharos diagnostics` escapes the paths it is given.
  - The captAInHook payload (`pharos-hook.sh`) keeps a touched path with a space whole.
  - `edit_at_symbol`'s drift check reads escaped paths, instead of quietly skipping (#16).
- `apply_workspace_edit` answered "Applied edits." with `isError: false` even when no file was
  written. Now any failed file marks the result an error (files are written one by one, so a
  partial failure leaves the edit half-applied), the header says what landed ("No edits
  applied", "Applied edits to 1 of 2 file(s)…"), and failed files are listed first (#22).
- On a fresh typescript-language-server session, `find_symbol` failed with tsserver's
  "No Project." until something had opened a file. Once that was fixed, it still said
  `not_found`, because tsserver's first symbol search after opening sees only the opened
  file. Now it opens `scope_uri` and, on a Tsserver-mode server, has tsserver load the
  project before searching (#21).
- The release workflow waited only 15 minutes for npm to serve the platform packages, and a
  re-run then failed on "release already exists". It now waits up to 60 minutes with backoff,
  and a re-run reuses an existing release that is published and holds exactly the run's
  files (#19).

### Changed

- The log writer closes its file when stopped, so the last lines are on disk once it has
  exited (#18).

## [0.3.4] — 2026-11-19

### Fixed

- A `.tsx` file reached tsserver as plain TypeScript (and a `.js` or `.jsx` file as
  TypeScript) whenever tsserver took the file's kind from pharos, which is whenever the file
  wasn't already loaded with its project: the first file asked about in a fresh daemon, a new
  file, a file outside every tsconfig. pharos sent the language's id, `typescript`, as every
  document's `languageId`. Now each opens as `typescriptreact`, `javascript` or
  `javascriptreact` by its extension (#17, ADR-041).

### Added

- `document_language_ids` in a language's `pharos.toml` table: the `languageId` per file
  extension, for a language whose server parses its dialects differently (ADR-041).

## [0.3.3] — 2026-11-19

### Changed

- `pharos diagnostics` reports a file whose project tsserver couldn't name with the reason
  `project_unknown` (it was `no_project`, which read like a real absence). The name matches
  the `pharos.project_unknown` marker, the way `carried_over` and `not_reported` do.

### Fixed

- In the `tsserver` diagnostics mode, `get_diagnostics` asks for the file's project after the
  diagnostics, not before them under a 2 s cap. tsserver answers in order and the first request
  after an edit or a cold open waits for the program to update, so the cap ran out whenever
  tsserver was busy and a hook read the file as unsure (#7's dry run: 11 checks).
- The captAInHook payload treats Claude Code 2.1's subagent tool, `Agent`, like `Task`: a call
  to it makes the next Stop check afresh.

## [0.3.2] — 2026-11-19

### Added

- **`pharos diagnostics [--json] [--timeout-ms N] FILE...`**: files'
  diagnostics through the shared daemon, for hooks and scripts that
  aren't MCP clients. Each file comes back `ok`, `unsure` (pharos marked
  the answer) or `failed`; it exits 0 once the daemon answered. It runs in
  the native shim, so it answers in milliseconds on a warm daemon
  ([ADR-040](doc/adr/040-diagnostics-cli-and-captainhook-payload.md); #6).
- **A captAInHook payload, `integrations/captainhook/pharos-hook.sh`**, in
  every release: after the agent's edits it hands back the new errors in
  the files it wrote, and at the end of the turn blocks once if new errors
  remain. TypeScript for now; it is arm 3 of the pharos trial (#7). See
  [integrations/captainhook/README.md](integrations/captainhook/README.md).
- **TypeScript answers name the file's tsserver project**
  (`pharos.project`), which the payload uses to keep to one tsconfig's
  program.

## [0.3.1] — 2026-11-18

### Fixed

- **TypeScript diagnostics answer for the text the server has now.**
  typescript-language-server publishes without a version, so right after
  a change, while tsserver was re-checking open files, `get_diagnostics`
  could return the previous text's errors, unmarked (0.3.0's known limit).
  pharos now asks tsserver for the file's diagnostics directly, through
  typescript-language-server's `typescript.tsserverRequest`. If that
  fails or runs out of time, the answer comes from the publishes, marked
  `pharos.carried_over`. Answers after a change are also faster. The new
  `diagnostics_mode = "tsserver"` turns this on for a server ([ADR-039](doc/adr/039-tsserver-diagnostics-asked-directly.md); #13).

## [0.3.0] — 2026-11-18

### Fixed

- **Answers follow the disk.** pharos told a language server about a file
  once and never again, so after the first question every answer
  (diagnostics, hover, definitions, references) described the text the
  file had then, for every session sharing the daemon, until the server
  stopped. Now every question re-reads the file asked about and every
  other document pharos holds open on that server, and sends what changed:
  one full-text `didChange`, plus `didSave` when the server asks for it.
  At most 32 documents stay open per server. A file asked about that has
  been deleted is closed, and nothing pharos cached about its old text is
  served again ([ADR-038](doc/adr/038-document-resync-from-disk.md); #3).
- **`get_diagnostics` says when it isn't sure.** An answer the server
  hasn't re-published since the file changed is marked
  `pharos.carried_over`. When another file changed, the server gets a 2 s
  settle window from the change to re-publish; after that, its silence
  counts as "unchanged". A server that reported nothing in time is named
  under `pharos.not_reported` instead of being counted as clean, and the
  wait no longer holds other sessions' requests to that server.
- **Known limit, TypeScript:** right after a change, while tsserver is
  still re-checking open files, `get_diagnostics` can return the previous
  text's diagnostics, unmarked, until that re-check publishes: a few
  hundred milliseconds on a small project, longer on a big one (#13).

### Changed

- **Apple silicon builds need macOS 15.** GitHub retired the macos-14
  runner, so the Apple silicon build moves to macos-15, as the Intel build
  already was on macos-15-intel. With no deployment target pinned, the
  build's minimum follows the runner's SDK: 0.2.2's Apple silicon build
  needs macOS 14, and 0.3.0's needs 15, as the Intel build already did
  (ADR-035, amended; #11).

- **The release workflow can finish a release that npm was slow to serve.**
  Each npm publish skips a version npm already has. A manual run with
  `republish: <version>` publishes what's missing from that version's
  GitHub release, then smokes it (the smoke step was skipped on the first
  such run, because `build` didn't run; fixed). 0.2.2 needed this: npm took about
  55 min to serve its two arm64 packages, so `pharos-mcp` 0.2.2 went out
  later than the GitHub release (ADR-035 §7).

## [0.2.2] — 2026-10-19

### Fixed

- **Nothing an LSP started outlives it any more.** When pharos stopped
  a language server (idle stop, eviction, session end, `pharos daemon
  stop`), the server exited, but what it had started in its process
  group could keep running: rust-analyzer's in-flight `cargo check` and
  its build script were measured still alive 120 s later, on Linux and
  macOS. Now each server's process group gets a grace period, then
  TERM, then KILL, and `daemon stop` waits for that
  ([ADR-037](doc/adr/037-lsp-process-group-reaping.md)).
- **A pharos that died hard is cleaned up after.** When a daemon or
  server starts, it reaps what pharos processes that were SIGKILLed or
  OOM-killed left behind. `pharos --cleanup` now also reaps a group
  whose leader already exited, and it identifies each server by its
  start time, so a reused pid is never signalled. Records from before
  0.2.2 are removed without signalling anything.
- **`pharos --print-language-config <lang>`** shows languages that
  pharos.toml adds, and overrides of bundled ones. Through 0.2.1 it
  showed only the bundled defaults.
- **README: adding a language.** The example used keys pharos doesn't
  read (`extensions`, `language_id`, `methods = "all"`, `env`); it
  now uses `file_extensions`, and says that `id` sets the
  `languageId`. The `--cleanup` section no longer claims a
  process-name check it never made.

### Changed

- **`initialize` sends pharos's OS pid as `processId`** (it was `null`),
  so servers that watch their client exit by themselves if pharos dies
  without closing their pipes. Nine of the 23 bundled servers do,
  including pyright, typescript-language-server and the vscode-langservers.

## [0.2.1] — 2026-10-19

### Added

- **`pharos self update | rollback | prune | uninstall`**: pharos
  manages its own install, with no installer URL to keep
  ([ADR-036](doc/adr/036-self-management-commands.md)). `self update
  [--version V]` runs that release's install.sh; the others run the
  install.sh each version now ships with. None of them starts the
  Erlang runtime. Installed with npm, `self update`, `rollback` and
  `uninstall` print the npm command to run instead. A pharos 0.2.0 has
  no `self` yet: update it one last time with the install.sh one-liner.
- **`install.sh --prune`**: remove every version but the current and
  the previous one, unless a running pharos uses it, without
  downloading anything.

### Changed

- **`pharos self prune` replaces `pharos --purge-cache`.** It also
  removes what pharos 0.1.x unpacked under
  `~/.local/share/.burrito/pharos_*` that nothing running uses.
  `--purge-cache` still works for this release, as a deprecated alias
  that runs `self prune`.
- `pharos --help` lists `warm` and the `self` commands, and
  `--print-default-config` describes the real tool presets and
  categories (the `default` preset, 22 read tools, memory).
- install.sh's message on an unsupported OS says to use WSL on Windows,
  not npm.

### Fixed

- **Docs: RHEL 9 isn't supported.** Its glibc is 2.34, below the 2.35
  floor; 0.2.0's notes listed it. Ubuntu 22.04, Debian 12, Fedora 36
  and RHEL 10 or newer are.
- **Docs: the README still described 0.1's process model** ("no
  background daemon"), the `PHAROS_CLEANUP_GRACE_MS` variable (which
  never existed), and `PHAROS_WARM_LANGS` as working everywhere. It is
  direct mode only: the shared daemon doesn't warm per session.

## [0.2.0] — 2026-10-19

0.2.0-rc.1, the same code, was its release candidate.

pharos 0.2 changes how it runs and how it ships. MCP client configs keep
working unchanged: the command is still `pharos`.

### Added

- **One shared pharos per version, started on demand.** Each MCP session
  now runs a small native `pharos` that connects to a shared daemon for
  its version, starting it if none runs, and the daemon exits once it has
  been idle for 30 minutes. Sessions on the same project share their
  language servers, so a second Claude session on a warm repo answers at
  once instead of paying rust-analyzer's or jdtls's cold start again, and
  N sessions cost one set of LSPs instead of N
  ([ADR-034](doc/adr/034-shared-daemon-and-native-shim.md)). Each
  session keeps its own tool filter, timeout overrides, project config
  (`.pharos.toml` above its working directory) and environment, which
  its LSPs run with. With `PHAROS_MODE=direct` or `--direct`, a session
  runs in its own process as before.
- **`pharos daemon status|stop [--all]`** to see and stop daemons.
- **install.sh**: `curl -fsSL https://github.com/LoganBresnahan/pharos-mcp/releases/latest/download/install.sh | sh`
  installs into `~/.local/share/pharos/versions/<version>/`, links
  `~/.local/bin/pharos`, checks sha256, keeps the previous version for
  `--rollback`, and removes older ones once no running pharos uses them.
- **Language servers stop after 30 idle minutes** (2 hours for Java,
  Scala and Haskell) and restart on the next call; `idle_stop_secs` per
  language, or `PHAROS_LSP_IDLE_SECS`, changes it, and `0` never stops.
- **`env_keys`** per language (e.g. `VIRTUAL_ENV` for Python): sessions
  that disagree on them get separate LSPs instead of sharing one.

### Changed

- **No more Burrito.** Each platform ships its release unpacked, built
  natively per target with a statically linked OpenSSL; nothing extracts
  at run time, and there is no cache to warm or purge
  ([ADR-035](doc/adr/035-releases-without-burrito.md)). After
  `npm install -g pharos-mcp`, `pharos` is the native binary on Linux and
  macOS: no node process per session.
- **Windows is no longer supported natively.** pharos 0.2 runs on Linux
  and macOS; on Windows, install it inside WSL (pharos-mcp@0.1.4 was the
  last native Windows build).
- **Linux needs glibc 2.35 or newer** (Ubuntu 22.04, Debian 12, RHEL 9 or
  newer). pharos 0.2 needs glibc 2.35+ (Alpine/musl and older distros
  aren't supported yet); pharos-mcp@0.1.4 still runs there.
- **`PHAROS_INSTALL_DIR` now means install.sh's install root** (default
  `~/.local/share/pharos`), not Burrito's extraction directory.
  `PHAROS_BIN_DIR` sets where the `pharos` link goes.
- **`pharos --purge-cache`** now only cleans up after 0.1.x: it removes
  `~/.local/share/.burrito/pharos_*` unpacks no running process uses, and
  touches nothing else there.
- **Logs and crash dumps moved to `~/.local/state/pharos/log/`**
  (`$XDG_STATE_HOME` honoured; the directory is 0700, crash files 0600).
  0.1.x wrote to `~/.cache/pharos/log/`.
- `runtime_set_tool_timeout` lasts until the session ends.
- OTP 28.1.1.

### Fixed

- **A cancelled request is really cancelled.** `notifications/cancelled`
  forwarded `$/cancelRequest` but never stopped pharos's own worker, so
  the reply still went out. The worker is now killed first, and no reply
  is sent.
- **pharos exits in about a second**, not six, when its client closes
  stdin or it is stopped: the LSP pool ignored the supervisor's shutdown
  and was killed only after a 5 s timeout.
- **Project memories land in the project**: the `.pharos/memories` layer
  resolved against the server process's working directory, not the
  session's.
- The release boots in embedded mode, with a build-time check of its
  boot script; a fresh build no longer ships the ADR-011 `hpack_erl`
  wrapper app with an unbootable path.

## [0.1.4] — 2026-07-10

### Fixed

- **`--version` and MCP `serverInfo` no longer drift from the release.**
  pharos's own version was hardcoded as a string literal in five source
  files; 0.1.3 bumped the package metadata but not those literals, so it
  shipped identifying itself as `0.1.2` to every MCP client. The version
  is now read once at runtime from the OTP application `vsn` (derived
  from `mix.exs` / `gleam.toml`), and CI asserts `pharos --version`
  matches the release tag so this can't recur.

## [0.1.3] — 2026-07-10

### Changed

- **License: relicensed from AGPL-3.0-only to Apache-2.0.** Pharos
  is now permissively licensed — free to embed and ship inside
  closed-source and commercial products, with an express patent
  grant and no network-use source-disclosure obligation. The former
  dual-license commercial track (`COMMERCIAL.md`) is retired, and
  the Contributor License Agreement is replaced by a lightweight
  [Developer Certificate of Origin](DCO) sign-off (`git commit -s`),
  enforced by a new DCO check in CI.

## [0.1.2] — 2026-06-03

Bug-fix patch release. Repairs `pharos --doctor` and
`pharos --purge-cache`, both of which silently pointed at a path
Burrito never creates on every supported platform. No tool-surface
or MCP-protocol changes.

### Fixed

- **`pharos --doctor`** now reports the real Burrito cache root
  (`$XDG_DATA_HOME/.burrito` or `~/.local/share/.burrito` on Linux,
  `~/Library/Application Support/.burrito` on macOS,
  `%LOCALAPPDATA%\.burrito` on Windows) and a non-zero cache size
  after a warm run. Previously printed
  `~/.cache/burrito_runtime/_/pharos` (a directory Burrito never
  creates) and always reported `0 bytes`, regardless of how warm the
  real cache was. The doctor line is the operator-facing diagnostic
  for cache state, so the old output was the worst kind of cosmetic
  bug — it confidently lied.
- **`pharos --purge-cache`** actually deletes pharos's extracted
  release directories now. Previously no-op'd against the same
  phantom path while the real ~50 MB cache persisted untouched, with
  output that looked like success (`no Burrito cache at ...; exit 0`).
- **Cross-app isolation guarantee on purge:** `--purge-cache` now
  scopes its `rm -rf` to entries starting with `pharos_` under the
  shared `.burrito` root. Caches belonging to other Burrito-packaged
  tools (`next_ls_*`, etc.) are explicitly left alone. Stray
  non-directory files in the shared root also survive purge.
- **`npm/pharos-mcp/scripts/postinstall.js` `cache_root()`** now
  matches the FFI on every platform: adds a macOS branch (was falling
  through to the Linux path, so every macOS install was looking at
  the wrong dir for the cache-warmed check), and switches Windows
  from `%APPDATA%` (Roaming) to `%LOCALAPPDATA%` (Local) to match Zig
  0.13's `fs.getAppDataDir`, which is what Burrito's `wrapper.zig`
  actually calls.

### Added

- `pharos_runtime_ffi:list_pharos_extracts/0` — enumerates
  pharos-only entries under the shared Burrito root so callers can
  size/clean only this app's extracts. Honors the
  `PHAROS_INSTALL_DIR` env override (matches Burrito's
  `{UPPER_RELEASE_NAME}_INSTALL_DIR` convention from
  `deps/burrito/src/wrapper.zig`).
- Unit tests in `test/runtime_ffi_test.gleam` pinning the cache-root
  path shape (must end with `.burrito`, must not contain
  `burrito_runtime`), the `PHAROS_INSTALL_DIR` override semantics,
  the missing-root behavior (empty list, no crash), and the
  `list_pharos_extracts` filtering (accepts `pharos_*` directories,
  rejects sibling-app directories like `next_ls_*`, rejects stray
  files).
- CI grep-guard step forbidding the bug-class patterns
  `filename:basedir(user_cache, …)` and `burrito_runtime` anywhere in
  source, plus bare `process.env.APPDATA` in postinstall. Catches the
  whole fossil class on re-entry, not just the literal old strings.

### Internal

- `pharos_runtime_ffi:burrito_cache_root/0` rewritten to mirror
  Burrito's `deps/burrito/src/wrapper.zig` byte-for-byte across all
  three platforms. Platform branches use `os:type/0` directly rather
  than `filename:basedir/2`, because Erlang's `user_data` returns
  `%APPDATA%` on Windows while Zig 0.13 (and therefore Burrito) reads
  `%LOCALAPPDATA%`.
- Bumped `@version_base` (mix.exs), `gleam.toml`, the four
  `server_version` constants (src/pharos.gleam, src/pharos/cli.gleam,
  src/pharos/mcp/server.gleam, plus inline literals in
  src/pharos/smoke.gleam and src/pharos/tools/session.gleam) from
  `0.1.1` to `0.1.2`.

## [0.1.1] — 2026-06-03

Fossil-fix patch release. No behavior changes; only error-message
and tool-description wording. The v0.1.0 → v0.1.1 ship gates
defined in `doc/m14-test-plan.md` (Gate 1 dogfood-23lang + Gate 2
owner MCP-host dogfood) were waived for this release because the
patch is strictly wording.

### Fixed

- `get_diagnostics` and other tools routed through
  `describe_diagnostics_error` no longer say
  `rust-analyzer failed to spawn:` when a non-Rust LSP fails to
  start. The message is now language-neutral:
  `LSP spawn failed: <reason>`. Matches the wording already used by
  `describe_session_error` in `src/pharos/tools/session.gleam`.
- `get_diagnostics` no longer claims
  `v0.1 only supports .rs files; got: <uri>` when called on a URI
  whose extension has no registered language. Replaced with the
  neutral `unsupported file type: <uri>` used elsewhere.
- Tool JSON-schema descriptions for `goto_definition`,
  `get_diagnostics`, and one sibling tool no longer use
  `file:///home/user/project/src/main.rs` as the example file URI;
  replaced with the language-neutral `file:///path/to/file`.
- `timeout_ms` description on `get_diagnostics` no longer singles
  out `gopls and rust-analyzer` as the slow LSPs.
- Internal doc comments in `src/pharos/lsp/lifecycle.gleam`,
  `src/pharos/mcp/content_block.gleam`, and
  `src/pharos/lsp/framing.gleam` no longer frame their conventions
  as "v0.1 only" behaviors.

### Added

- CI grep-guard that fails the build if a non-test source file
  introduces hardcoded `rust-analyzer` / `v0.1 ` / `main.rs`
  outside an allowlist. Prevents the fossil class from returning.
- Unit tests under `test/mcp/server_error_messages_test.gleam`
  pinning the language-neutral wording so it cannot regress
  silently.

### Internal

- `describe_diagnostics_error` is now `pub` so the new test module
  can import it. Error rendering is part of the public MCP-client
  contract anyway.
- Bumped `@version_base` (mix.exs), `gleam.toml`, the four
  `server_version` constants (src/pharos.gleam, src/pharos/cli.gleam,
  src/pharos/mcp/server.gleam, plus matching inline literals in
  src/pharos/smoke.gleam and src/pharos/tools/session.gleam) from
  `0.1.0` to `0.1.1`.

## [0.1.0] — 2026-05-25

Initial public release. Headless LSP↔MCP bridge for AI agents.

### Added

- **MCP server** speaking 2024-11-05 protocol over stdio. Compatible
  with Claude Code, Cursor, and any MCP-aware host.
- **23 language adapters** wrapping real LSP servers — rust
  (rust-analyzer), go (gopls), typescript
  (typescript-language-server), python (pyright + ruff), java
  (jdtls), gleam (gleam-lsp), cpp (clangd), elixir (next-ls),
  ruby (ruby-lsp), zig (zls), scala (metals), clojure
  (clojure-lsp), haskell (hls), perl (perlnavigator), erlang
  (elp), lua (lua-language-server), bash (bash-language-server),
  terraform (terraform-ls), yaml (yaml-language-server), markdown
  (marksman), html / css / json (vscode-langservers-extracted).
  Capability matrix at `doc/lsp-capability-matrix.md`.
- **Symbol-layer tools** (ADR-026) — `find_symbol`,
  `find_referencing_symbols`, `get_symbols_overview`,
  `containing_symbol`, `edit_at_symbol`. Symbol-name-anchored
  navigation that doesn't require line/column coordinates.
- **Universal editor bridge** (ADR-028) — `apply_workspace_edit`
  and `rename_preview` produce LSP-shaped `WorkspaceEdit`
  documents that any editor or AI host can apply.
- **Custom URI schemes** (ADR-029) — `jdt://` (Java external types)
  flows through navigation tools transparently; `fetch_uri_contents`
  reads the raw text for any scheme the active LSP supports.
- **Compact response format** (ADR-023) — opt-in `format: "compact"`
  on list-shaped tools (find_references, workspace_symbols,
  get_diagnostics, goto_*, hierarchy_*) for ~5-7× token reduction.
- **Process lifecycle hardening** (ADR-030) — graceful exit on
  stdin EOF, crash-repro suite, cleanup CLI; `pharos warm <lang>...`
  and `pharos warm --all` pre-spawn LSPs for disk-cache warmup.
- **Per-tool timeout overrides** via `runtime_set_tool_timeout`
  (ADR-021).
- **Project memory tools** — `memory_save`, `memory_get`,
  `memory_list`, `memory_audit`, `memory_prune` for per-project
  curated notes.
- **npm distribution** — `npm i pharos-mcp` resolves the right
  platform binary via scoped `optionalDependencies`
  (`@pharos-mcp/linux-x64`, `@pharos-mcp/darwin-arm64`, etc.).
  Trusted-publisher OIDC; no NPM_TOKEN in CI.
- **Direct binary downloads** attached to each GitHub Release for
  the 5 supported targets: linux-x64, linux-arm64, darwin-x64,
  darwin-arm64, win-x64.

### Known limitations

- `fetch_uri_contents` is only meaningful for LSPs that emit
  non-`file://` URIs (Java/jdtls). Clojure and Scala adapters do
  not currently surface their virtual schemes — tracked for a
  future release.
- Elixir adapter passes 16/27 dogfood cells; ElixirLS does not
  implement several LSP features the matrix probes. Use with
  awareness.
- `warm --all` uses workspace root markers to decide which
  languages to spin up. The `.git` marker shared by TS/JS/HTML/
  CSS/JSON means those will all attempt to warm in any git
  project; pass explicit languages (`pharos warm rust go`) for
  precise control.

[Unreleased]: https://github.com/LoganBresnahan/pharos-mcp/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.2.2
[0.2.1]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.2.1
[0.2.0]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.2.0
[0.1.4]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.4
[0.1.3]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.3
[0.1.2]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.2
[0.1.1]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.1
[0.1.0]: https://github.com/LoganBresnahan/pharos-mcp/releases/tag/v0.1.0
