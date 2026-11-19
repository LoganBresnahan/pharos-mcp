//// #17: the LSP languageId a document is opened with. One language
//// entry can cover dialects its server parses differently; sent as the
//// language's id, a .tsx file reached tsserver as plain TypeScript.

import gleam/dict
import gleam/list
import gleeunit/should
import pharos/lsp/languages

fn typescript() -> languages.LanguageConfig {
  let assert Ok(config) = dict.get(languages.default_registry(), "typescript")
  config
}

pub fn typescript_dialects_get_their_own_language_ids_test() {
  let ts = typescript()
  [
    #("file:///w/app/Folder.tsx", "typescriptreact"),
    #("file:///w/app/Folder.TSX", "typescriptreact"),
    #("file:///w/shared/slugify.ts", "typescript"),
    #("file:///w/shared/types.d.ts", "typescript"),
    #("file:///w/build.js", "javascript"),
    #("file:///w/build.mjs", "javascript"),
    #("file:///w/build.cjs", "javascript"),
    #("file:///w/View.jsx", "javascriptreact"),
  ]
  |> list.each(fn(case_) {
    languages.document_language_id(ts, case_.0) |> should.equal(case_.1)
  })
}

pub fn every_listed_extension_belongs_to_its_language_test() {
  languages.default_registry()
  |> dict.values
  |> list.each(fn(config) {
    config.document_language_ids
    |> list.each(fn(pair) {
      list.contains(config.file_extensions, pair.0) |> should.be_true
    })
  })
}

/// The audit #17 asked for: today only the TypeScript entry maps
/// extensions to other languageIds. Others share one entry across
/// dialects too (cpp's .c, css's .scss/.less/.sass, json's .jsonc,
/// terraform's .tfvars), but mapping those changes how clangd, the CSS
/// and JSON servers and terraform-ls parse a file, and needs its own
/// dogfood: a deliberate follow-up, not an oversight. Extend this list
/// when one lands.
pub fn only_typescript_maps_dialects_today_test() {
  languages.default_registry()
  |> dict.values
  |> list.filter(fn(config) { config.document_language_ids != [] })
  |> list.map(fn(config) { config.id })
  |> should.equal(["typescript"])
}

pub fn extensions_match_case_insensitively_both_ways_test() {
  let config =
    languages.LanguageConfig(..typescript(), document_language_ids: [
      #(".TSX", "typescriptreact"),
    ])
  languages.document_language_id(config, "file:///w/a.tsx")
  |> should.equal("typescriptreact")
  languages.document_language_id(config, "file:///w/a.Tsx")
  |> should.equal("typescriptreact")
}

pub fn a_language_without_a_mapping_uses_its_id_test() {
  let assert Ok(go) = dict.get(languages.default_registry(), "go")
  languages.document_language_id(go, "file:///w/main.go") |> should.equal("go")
}
