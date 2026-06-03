//// Regression tests for `describe_diagnostics_error`.
////
//// Pre-v0.1.1 the formatter hardcoded "rust-analyzer" in SpawnFailed
//// and "v0.1 only supports .rs files" in UnsupportedFileType — both
//// fossils from when pharos was a Rust-only tool. These assertions
//// pin the language-neutral wording and explicitly forbid the fossil
//// substrings from returning.

import gleam/string
import gleeunit/should
import pharos/mcp/server
import pharos/tools/diagnostics

fn forbid(haystack: String, needle: String) -> Nil {
  string.contains(haystack, needle) |> should.be_false
}

fn require(haystack: String, needle: String) -> Nil {
  string.contains(haystack, needle) |> should.be_true
}

pub fn spawn_failed_renders_language_neutral_test() {
  let msg = server.describe_diagnostics_error(diagnostics.SpawnFailed("boom"))
  require(msg, "LSP spawn failed")
  require(msg, "boom")
  // Fossil substrings that MUST NOT appear.
  forbid(msg, "rust-analyzer")
}

pub fn unsupported_file_type_renders_language_neutral_test() {
  let msg =
    server.describe_diagnostics_error(diagnostics.UnsupportedFileType(
      "file:///tmp/notes.weird",
    ))
  require(msg, "unsupported file type")
  require(msg, "file:///tmp/notes.weird")
  // Fossil substrings that MUST NOT appear.
  forbid(msg, "v0.1")
  forbid(msg, ".rs files")
  forbid(msg, "only supports")
}
