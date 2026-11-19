# 041. A document's languageId follows its extension

**Status:** Accepted (2026-11-19)
**Date:** 2026-11-19
**Issue:** [#17](https://github.com/LoganBresnahan/pharos-mcp/issues/17)

## Context

A `LanguageConfig` has one `id` and a list of `file_extensions`, and pharos sent that `id` as
every document's `languageId` in `textDocument/didOpen`. One entry often covers dialects its
server parses differently. The TypeScript entry covers `.ts .tsx .js .jsx .mjs .cjs`, so every
one of them opened as `"typescript"`. typescript-language-server picks tsserver's script kind
from the languageId (`typescriptreact` → TSX, `javascript` → JS, `javascriptreact` → JSX), so
tsserver parsed a `.tsx` file without JSX.

It bites whenever tsserver takes the script kind from the client, which is whenever the file
isn't already loaded as part of a project: the first file pharos opens in a fresh tsserver, a
file the agent has just created, a file outside every tsconfig. On the pharos trial's T6 start
(outline at `9839ad8`), `Folder.tsx` asked first gave `TS1110 Type expected.` and
`TS1161 Unterminated regular expression literal.`, where tsc reports nothing, and kept them
while the document stayed open. Asked after a `.ts` file had loaded the project, the same file
was clean. The ADR-032 step 1 dogfood report suspected this from the code path and couldn't
confirm it then.

## Decision

**`LanguageConfig.document_language_ids`: pairs of (extension, languageId).** A document whose
path ends with a listed extension (compared case-insensitively on both sides) opens with that
languageId; any other gets the language's `id`, as before. The pool records the languageId per document at open, so
later syncs keep it.

- The bundled TypeScript entry maps `.tsx` → `typescriptreact`, `.js` `.mjs` `.cjs` →
  `javascript`, `.jsx` → `javascriptreact`.
- Users set it per language in `pharos.toml`:
  `document_language_ids = { ".tsx" = "typescriptreact" }`, replacing the bundled list like the
  other list keys. A user-defined language gets an empty list unless it sets one.
- `runtime_language_config` renders it.

**Only the TypeScript entry maps dialects today.** Others share one entry across extensions a
server may parse differently: `cpp` (`.c`), `css` (`.scss`, `.less`, `.sass`), `json`
(`.jsonc`), `terraform` (`.tfvars`, `.hcl`). Mapping those changes how clangd, the CSS and JSON
servers and terraform-ls treat a file, and each needs its own dogfood. They are follow-ups,
listed in the test that pins the current state (`only_typescript_maps_dialects_today_test`),
not oversights.

## Rejected

- **One language entry per dialect** (`typescriptreact` as its own language): each entry
  spawns its own server per workspace, so `.ts` and `.tsx` files of one project would land in
  two tsservers that don't see each other's open documents.
- **A hardcoded table in the sync path:** it would keep the mapping out of the config users
  can see and change, and hide a language assumption in the pool.

## Consequences

- tsserver parses `.tsx`, `.js` and `.jsx` documents as what they are, however they were
  first opened. On the trial's T6 start every one of the 2,211 TypeScript files, `Folder.tsx`
  asked first included, answers with no error, matching tsc.
- A new config key, rendered by `runtime_language_config` and documented in the README.
- The integration suite's `document_language_id` scenario checks the languageId each didOpen
  carries, through a user-defined language's `pharos.toml`.
