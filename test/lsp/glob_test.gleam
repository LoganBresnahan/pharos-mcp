//// ADR-043: LSP glob patterns for registered file watchers.

import gleeunit/should
import pharos/lsp/glob

pub fn star_stays_in_one_segment_test() {
  glob.matches("*.go", "main.go") |> should.be_true
  glob.matches("*.go", "cmd/main.go") |> should.be_false
  glob.matches("/w/*.go", "/w/main.go") |> should.be_true
}

pub fn double_star_spans_segments_test() {
  glob.matches("**/*.go", "/home/u/p/cmd/main.go") |> should.be_true
  glob.matches("**/*.go", "main.go") |> should.be_true
  glob.matches("**/*.go", "/p/main.rs") |> should.be_false
  glob.matches("/p/**/go.mod", "/p/go.mod") |> should.be_true
  glob.matches("/p/**/go.mod", "/p/a/b/go.mod") |> should.be_true
  glob.matches("**", "/anything/at/all") |> should.be_true
}

pub fn braces_test() {
  glob.matches("**/*.{go,mod,sum,work}", "/p/go.sum") |> should.be_true
  glob.matches("**/*.{go,mod,sum,work}", "/p/go.toml") |> should.be_false
  glob.matches("**/{Cargo.toml,Cargo.lock}", "/p/sub/Cargo.lock")
  |> should.be_true
  glob.expand_braces("a{b,c{d,e}}f")
  |> should.equal(["abf", "acdf", "acef"])
}

pub fn question_mark_and_classes_test() {
  glob.matches("file.?s", "file.ts") |> should.be_true
  glob.matches("file.?s", "file.tsx") |> should.be_false
  glob.matches("v[0-9].txt", "v7.txt") |> should.be_true
  glob.matches("v[0-9].txt", "vx.txt") |> should.be_false
  glob.matches("v[!0-9].txt", "vx.txt") |> should.be_true
  glob.matches("[ab]c", "bc") |> should.be_true
}
