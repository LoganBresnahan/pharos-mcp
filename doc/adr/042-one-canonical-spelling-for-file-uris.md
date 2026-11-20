# 042. One canonical spelling for `file://` URIs

**Status:** Accepted (2026-11-19)
**Date:** 2026-11-19
**Issue:** [#16](https://github.com/LoganBresnahan/pharos-mcp/issues/16)

## Context

A `file://` URI can spell one file several ways. A space is `%20` or, from a client that doesn't
encode, a raw space; `@` and `+` are escaped by vscode-uri (typescript-language-server,
pyright) and left raw by Rust's `url` (rust-analyzer); hex digits can be either case. Through
0.3.4 pharos never decoded or encoded: `uri_to_path` only stripped `file://`, `path_to_uri`
only prepended it, and the diagnostics cache matched the publish's `uri` string against the
caller's. So a project at `/tmp/my proj/` found no workspace root when asked with `my%20proj`.
Asked raw, it reached the root but waited out the timeout on a Push server, which published
under its own escaping. Separately, the file, apply-edit and spawn FFIs passed paths through
`binary_to_list`, so a non-ASCII path named a different file.

## Decision

**Every `file://` URI pharos keys on is in one canonical spelling: decoded, then encoded as
vscode-uri does** (every byte but `A-Z a-z 0-9 - . _ ~ /` percent-encoded).
`workspace_root.canonical_uri` computes it; other schemes (`jdt://`) pass through unchanged.

- **The tools' URI arguments** (`uri`, `scope_uri`, `workspace_uri_hint`, call and type
  hierarchy items, `symbol_handle`) decode through `workspace_root.uri_decoder()`. So the
  server sees one document per file, opened under the canonical URI, and the pool tracks it
  under that.
- **The diagnostics cache** keys every row by the canonical URI, on put and on every lookup, in
  the FFI. Whatever escaping the server published with, the caller's question meets it.
- **URIs in server responses** pass through as the server sent them. pharos doesn't rewrite
  what it relays.
- **Paths reach the file system as their own bytes:** the FFIs pass binaries, and names coming
  back go through the native filename encoding.
- `pharos diagnostics` builds its URIs with the same encoding, so the daemon's decode can't
  misread a literal `%25` in a folder name.

**A `uri` argument is always decoded.** A raw URI holding a literal, valid escape (a folder
really named `a%20b`) is read as the escape, which is what the LSP spec and RFC 3986 say a
client sends. Text that isn't a valid escape (`100%/`) is kept as written, so a client that
doesn't encode still works for most paths.

## Rejected

- **Keying the cache by the publish's own string**, and asking servers in their spelling:
  servers disagree, and pharos would have to know each one's escaping rules.
- **Comparing decoded paths at each use** instead of canonicalizing once: every map and table
  keyed by URI (the pool's open documents, the cache, the sync stamps) would need its own
  normalization, and one missed site re-creates the bug.
- **Fixing only the request path:** a non-ASCII workspace still failed at the file system,
  through `binary_to_list`.

## Consequences

- Questions about a project at a path with spaces, `#`, `%` or non-ASCII characters work, in
  every spelling of the URI, on Push servers and in Tsserver mode. The integration suite's
  `uri_escapes_*` scenarios pin this.
- A client sending a raw URI with a literal `%XX` in a name gets the escaped reading. This is
  documented in the CHANGELOG for 0.3.5.
- The fossil guard rejects `binary_to_list` on a path passed to `file:read_file`,
  `filelib:is_regular` or `filelib:is_dir`. The same conversion on environment values and
  `HOME` is #20.
