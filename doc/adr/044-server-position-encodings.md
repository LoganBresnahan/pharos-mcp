# 044. Servers whose columns aren't UTF-16

**Status:** Accepted (2026-11-22; mod's call, a correctness fix with no latency trade)
**Date:** 2026-11-22
**Issue:** [#47](https://github.com/LoganBresnahan/pharos-mcp/issues/47)

## Context

LSP counts a position's `character` in UTF-16 code units unless client and server negotiate
another encoding, and pharos negotiates none. Three bundled servers count differently, so on a
line with non-ASCII text before a token their positions point at the wrong characters (ASCII
lines are unaffected). Measured 2026-11-22, raw LSP, `é😀` (and eight 😀 for the narrow cases)
before the token, each column compared in UTF-16, UTF-8 bytes and code points:

| server | advertises | positions it returns | positions it reads |
|---|---|---|---|
| ruby-lsp 0.26 | `positionEncoding: utf-16` | UTF-8 bytes (references; diagnostics, #47's sweep) | UTF-8 bytes: definition and hover answer only at the byte column |
| terraform-ls | nothing | code points (references, diagnostics) | UTF-16: definition resolves at the UTF-16 column, misses at the code-point one |
| next-ls | nothing | code points (references, documentSymbol, diagnostics) | code points: on a compiled project, definition answers only at the code-point column (verifier-two: 21/29/37 resolve; the UTF-16 24/32/40 and UTF-8 31/39/47 columns return null) |

These are server bugs: ruby-lsp advertises an encoding it doesn't use, terraform-ls and next-ls
use one without saying so.

## Decision

Two per-server settings say what a server really uses, overriding what it advertises:

- `position_encoding = "utf-8" | "utf-32"`: every position pharos sends the server and gets
  back. Bundled: ruby-lsp `"utf-8"` and next-ls `"utf-32"` (each measured both ways).
- `returned_position_encoding`: the positions it returns only (responses and publishes), for a
  server that reads UTF-16 but answers in another encoding. Bundled: terraform-ls `"utf-32"`
  (measured both ways: it reads UTF-16). When both are set, `position_encoding` governs sent
  positions and `returned_position_encoding` returned ones.

next-ls needs a compiled project before it answers definition or references (about 5.6 s after
spawn, by its "Finished indexing!" progress); the first probe ran before that and saw nothing.

The pool records each proc's encodings at spawn. `proc.request` converts the params' positions
to the server's encoding and the answer's back to UTF-16, and the proc converts a publish before
caching it: one translation layer (`pharos_position_ffi`). A position belongs to the nearest
enclosing `uri` (a Location's), `targetUri` (a LocationLink's target ranges; its origin range is
the request's document), `textDocument.uri`, the key of a WorkspaceEdit's `changes`, or else the
request's own document. A server that advertises an encoding with no override is trusted as
before; no other server is touched.

Bounds:

- Columns are converted against the line as it is on disk, the text pharos last synced (ADR-038
  re-syncs from disk before each question). A location in a file that changed on disk since the
  server read it can come out a column or two off on a non-ASCII line.
- A position past its line's end, or on a line the file doesn't have, passes through unchanged,
  as does any position in a file pharos can't read.
- didChange ranges stay UTF-16: ruby-lsp applies those right (verified for #38, including a
  UTF-16 tail), so only requests and answers are converted.
- An incoming call's `fromRanges` are converted against its caller's document (`from.uri`), not
  the request's.
- Semantic tokens pass through as the server sent them. They're relative integers, not positions,
  and of the three servers only ruby-lsp serves them to pharos, in UTF-16 already (next-ls has no
  semantic tokens; terraform-ls answers -32601 because pharos doesn't advertise the
  `textDocument.semanticTokens` client capability, and serves them when a client does, with its
  columns unmeasured: #52): `helper` after `"é😀😀😀"` comes at (19, 6), its UTF-16 column, where its
  other positions count bytes (26). Converting them as bytes put it at (14, 4).
- An invalid value (`"utf-7"`) is unset, so it behaves and prints as UTF-16, as its config
  warning says.

## Consequences

- On a non-ASCII line, ruby-lsp's and next-ls's definition, hover, references, symbols and
  diagnostics, and terraform-ls's references and diagnostics, point at the right characters.
- A cost per request on those three servers only: the params and the answer are re-encoded once,
  and the files their positions name are read for the lines concerned.
- Candidate upstream reports, the maintainer's call: drafts are kept with the session notes.
