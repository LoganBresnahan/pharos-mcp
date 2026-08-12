//// Tests for root attribution (ADR-032 option F) — the note
//// `find_references` attaches as a second content block when the
//// session that answered is not the one the caller would assume.
////
//// The decision half is pure (`session.attribution_note/3`), so
//// these cover it directly without a live pool. The two triggers are
//// "the answering root is inside a dependency directory" and "more
//// than one workspace is live for this language"; everything else
//// must stay silent, because every emitted note is permanent context
//// cost in the agent's window per ADR-006.

import gleam/option
import gleam/string
import gleeunit/should
import pharos/tools/session

// -- is_dependency_path ---------------------------------------------------

pub fn dependency_path_detects_node_modules_test() {
  session.is_dependency_path("/home/u/proj/node_modules/@types/react")
  |> should.be_true
}

pub fn dependency_path_detects_cargo_registry_test() {
  session.is_dependency_path(
    "/home/u/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/serde-1.0.200",
  )
  |> should.be_true
}

pub fn dependency_path_detects_go_module_cache_test() {
  session.is_dependency_path("/home/u/go/pkg/mod/github.com/x/y@v1.2.3")
  |> should.be_true
}

pub fn dependency_path_detects_site_packages_test() {
  session.is_dependency_path(
    "/home/u/proj/.venv/lib/python3.12/site-packages/requests",
  )
  |> should.be_true
}

pub fn ordinary_project_root_is_not_a_dependency_path_test() {
  session.is_dependency_path("/home/u/proj") |> should.be_false
  session.is_dependency_path("/home/u/proj/packages/renderer")
  |> should.be_false
}

/// `vendor` and `deps` alone are ordinary directory names in
/// first-party trees. Matching them would fire a spurious note on
/// every call in such a repo, which is worse than missing one — so
/// only the qualified `vendor/bundle` form counts.
pub fn bare_vendor_and_deps_dirs_do_not_match_test() {
  session.is_dependency_path("/home/u/proj/vendor/mylib") |> should.be_false
  session.is_dependency_path("/home/u/proj/deps/mylib") |> should.be_false
  session.is_dependency_path("/home/u/proj/vendor/bundle/ruby/3.2.0/gems/rake")
  |> should.be_true
}

/// A root that *is* the dependency directory has no trailing
/// separator of its own; the predicate appends one so it matches the
/// same interior-segment test as a deeper path.
pub fn dependency_dir_itself_matches_test() {
  session.is_dependency_path("/home/u/proj/node_modules") |> should.be_true
}

pub fn node_modules_as_a_filename_prefix_does_not_match_test() {
  session.is_dependency_path("/home/u/proj/node_modules_backup")
  |> should.be_false
}

// -- attribution_note -----------------------------------------------------

pub fn ordinary_single_workspace_answer_is_silent_test() {
  session.attribution_note("typescript", "/home/u/proj", 1)
  |> should.equal(option.None)
}

/// The cold path: a tool answering before any session reached Ready
/// reports a zero count, and that is not on its own worth a note.
pub fn no_live_workspaces_is_silent_test() {
  session.attribution_note("typescript", "/home/u/proj", 0)
  |> should.equal(option.None)
}

pub fn dependency_root_produces_a_note_test() {
  let assert option.Some(note) =
    session.attribution_note(
      "typescript",
      "/home/u/proj/node_modules/@types/react",
      1,
    )

  // Names the root that answered, so the caller can see it changed
  // workspaces rather than having to infer it from a wrong answer.
  string.contains(note, "/home/u/proj/node_modules/@types/react")
  |> should.be_true
  string.contains(note, "dependency directory") |> should.be_true
}

/// The note must not claim the LSP searched a particular scope — LSP
/// exposes no such signal, and a guessed "project-wide" is worse than
/// saying nothing. It may only warn that the result set is not
/// evidence about the project.
pub fn dependency_note_does_not_assert_a_search_scope_test() {
  let assert option.Some(note) =
    session.attribution_note("typescript", "/home/u/proj/node_modules/react", 1)

  string.contains(note, "project-wide results") |> should.be_true
  string.contains(note, "does not mean the symbol is unused") |> should.be_true
}

pub fn multiple_live_workspaces_produce_a_note_test() {
  let assert option.Some(note) =
    session.attribution_note("rust", "/home/u/proj", 2)

  string.contains(note, "/home/u/proj") |> should.be_true
  string.contains(note, "2") |> should.be_true
  string.contains(note, "rust") |> should.be_true
}

/// A dependency root while several workspaces are live gets the
/// dependency note, not the multi-workspace one — it is the more
/// actionable of the two.
pub fn dependency_root_wins_over_multi_workspace_test() {
  let assert option.Some(note) =
    session.attribution_note("typescript", "/home/u/proj/node_modules/react", 3)

  string.contains(note, "dependency directory") |> should.be_true
  string.contains(note, "workspaces are live") |> should.be_false
}
