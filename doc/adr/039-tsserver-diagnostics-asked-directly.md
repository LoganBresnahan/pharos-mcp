# 039. TypeScript diagnostics: ask tsserver directly

**Status:** Accepted (2026-11-18); amended by [ADR-040](040-diagnostics-cli-and-captainhook-payload.md) (`pharos.project`)
**Date:** 2026-11-18
**Issue:** [#13](https://github.com/LoganBresnahan/pharos-mcp/issues/13)
**Amends:** [ADR-038](038-document-resync-from-disk.md) (its known limit F4)

## Context

ADR-038 made answers follow the disk, and recorded one known limit, F4.
typescript-language-server publishes diagnostics without a `version`. They come from tsserver's
asynchronous `geterr` pass over every open file. When a change lands while a pass is running,
for example right after another file was opened, the pass's set for the old text arrives after
the `didChange`. pharos orders publishes by arrival, so it cached that set as fresh. The review
measured it on 2026-11-18:

- the stale set arrived 25 ms after the change and the correct one 356 ms after;
- 8 of 8 trials with a re-check in flight came back with the old errors, unmarked.

A publish's `version` wouldn't settle it anyway: rust-analyzer and pyright stamp the version
current when they publish, not the one they analysed (ADR-038, Context).

typescript-language-server 5.1.3 advertises no `diagnosticProvider`, so LSP pull isn't
available. It does have `workspace/executeCommand` `typescript.tsserverRequest`, which forwards a
raw tsserver request and maps an open document's URI to its path. tsserver's
`syntacticDiagnosticsSync`, `semanticDiagnosticsSync` and `suggestionDiagnosticsSync` answer for
the file's current text. tsserver handles requests in order, and typescript-language-server
sends tsserver the `change` before it reads the next LSP message. So a request sent after the
change sees the new text.

The probe on 2026-11-18 used typescript-language-server 5.1.3 and TypeScript 6.0.3, through
typescript-language-server's own queue, with pharos's settings and the review's race:

- 59 of 59 trials answered for the new text, while the race hit in 46 of them.
- It took 3 to 20 ms for small files, even with 30 busy 3000-line files open, and about 0.8 s
  for a 5000-line file, about when the correct publish arrives.
- A tsserver plugin's diagnostics were included. Both paths call the same plugin-wrapped
  language service.

## Decision

A per-server diagnostics mode, `Tsserver` (`diagnostics_mode = "tsserver"` in pharos.toml),
alongside Push and Pull. The bundled typescript-language-server uses it.

- `get_diagnostics` sends the three `*DiagnosticsSync` requests, in that order, through
  `typescript.tsserverRequest`, after the session's sync is written (ADR-038). Each goes
  through `session.request_with_content_modified_retry`, and each gets what is left of the
  call's deadline.
- tsserver's answers are mapped to LSP the way typescript-language-server publishes them.
  Line and offset go from 1-based to 0-based. Category maps to severity: error 1, warning 2,
  suggestion 4 (Hint), anything else 1. `code` is kept, and `source` defaults to `typescript`.
  `relatedInformation` items with a span become locations, and those without one are dropped.
  Tags are left out, because pharos doesn't advertise `publishDiagnostics.tagSupport`, so the
  publishes carry none either. Kinds are concatenated syntax, semantic, suggestion, the order
  typescript-language-server merges them in.
- `diagnostics.ignoredCodes` from the server's workspace configuration is applied by pharos.
  typescript-language-server filters only its publishes by it, not tsserver's answers.
- If the requests fail (an error, or tsserver's `success: false`) or outlast the call's
  deadline, the answer comes from the push cache, and the fallback is logged. It is **always
  marked `pharos.carried_over`**, whatever the cache's own freshness says. A publish carries no
  version, so it may be F4's stale set. The review showed it: a 5000-line file asked with
  `timeout_ms` 400 timed out and got the old text's errors from the cache, 7 of 8 times,
  unmarked before this rule. A deleted file asked about also takes the fallback: pharos closed
  it (ADR-038), so typescript-language-server no longer maps its URI, and its close-time empty
  set comes back marked.
- Falling back without the mark, and not falling back on a timeout, were both considered. The
  mark keeps the old answer visible to someone asking interactively, honestly labelled. A hook
  following the trial contract treats a marked answer as unsure and stays silent.

The pure part (request params, response mapping, ignored codes) is
`src/pharos/lsp/tsserver_diagnostics.gleam`. The calls are in `tools/diagnostics.gleam`.

## Consequences

- TypeScript diagnostics answer for the text the server has now, even with a re-check in
  flight. The dogfood's race check (`bin/dogfood-adr-038.py`, ts section) found 0 of 8 stale,
  where 0.3.0 served 8 of 8 stale in the review's run. An unmarked TypeScript answer came from
  tsserver after the change, so it is current, which #6 needs. A fallback answer is marked.
  ADR-038's warning that #6 must not rely on unmarked TypeScript answers applies to pharos
  0.3.0.
- TypeScript answers are faster after a change: about 0.01 s in the dogfood, where the push
  path waited about 0.4 s for the debounced publish. On a big file the cost is one synchronous
  check, about what the correct publish took anyway.
- A TypeScript answer is marked `pharos.carried_over` only when it came from the fallback. The
  push cache still fills from publishes, and is read only then. A call whose budget is shorter
  than a semantic check of the file (a big file, a short `timeout_ms`) gets a marked fallback
  answer, or none, rather than a direct one.
- The mode depends on typescript-language-server keeping `typescript.tsserverRequest`, and on
  the shape of tsserver's diagnostics. If either changes, the requests fail and pharos falls
  back to the push cache, with ADR-038's F4 back as a limit. The fallback is logged.
- A path with characters a URI must escape gets a `relatedInformation` URI that is
  `file://` plus the raw path. typescript-language-server would percent-encode it. (Fixed
  by #16: `path_to_uri` now percent-encodes as vscode-uri does.)
- The mode is set per server, not per language: a pharos.toml can turn it on for another
  server that forwards `typescript.tsserverRequest` (vtsls, say), or turn it off.

## Alternatives considered

- **A quiet period for publishes without a `version`.** Wait until no newer publish for the file
  has come for some time Q. It adds Q to every TypeScript answer after a change, and it still
  fails when tsserver's re-check outlasts Q, which grows with the project.
- **Mark unversioned publishes that arrive inside the settle window.** It's honest but fixes
  nothing: #6 would re-ask and pay the latency anyway.
- **LSP pull (`textDocument/diagnostic`).** typescript-language-server 5.1.3 doesn't offer it.
  It would be the standard route if it did.
- **Leave it to #6's settle logic.** pharos would still call a stale answer fresh.
