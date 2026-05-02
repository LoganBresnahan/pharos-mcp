//// Tests for `llm_lsp_mcp/workspace_root`.
////
//// Filesystem-backed: tests construct a temp directory layout and
//// run discovery against it. Layout is cleaned up afterward.

import gleam/string
import gleeunit/should
import llm_lsp_mcp/workspace_root

@external(erlang, "llm_lsp_mcp_fs_ffi", "shell")
fn shell(cmd: String) -> String

fn temp_dir() -> String {
  // Tests rm -rf first, so a stable suffix is fine.
  "/tmp/llm_lsp_mcp_workspace_root_test"
}

fn setup() -> String {
  let root = temp_dir()
  let _ = shell("rm -rf " <> root)
  let _ = shell("mkdir -p " <> root <> "/project/src")
  let _ = shell("printf '[package]\\n' > " <> root <> "/project/Cargo.toml")
  let _ = shell("printf 'fn main() {}\\n' > " <> root <> "/project/src/main.rs")
  root
}

fn teardown(root: String) -> Nil {
  let _ = shell("rm -rf " <> root)
  Nil
}

pub fn uri_to_path_strips_file_scheme_test() {
  workspace_root.uri_to_path("file:///home/oof/foo.rs")
  |> should.equal(Ok("/home/oof/foo.rs"))
}

pub fn uri_to_path_rejects_non_file_uri_test() {
  case workspace_root.uri_to_path("https://example.com/foo.rs") {
    Error(workspace_root.NotAFileUri(_)) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }
}

pub fn path_to_uri_prepends_scheme_test() {
  workspace_root.path_to_uri("/home/oof/foo.rs")
  |> should.equal("file:///home/oof/foo.rs")
}

pub fn discover_from_uri_finds_cargo_toml_ancestor_test() {
  let root = setup()
  let file_uri = "file://" <> root <> "/project/src/main.rs"

  let result = workspace_root.discover_from_uri(file_uri, ["Cargo.toml"])

  case result {
    Ok(found) -> {
      should.be_true(string.ends_with(found, "/project"))
    }
    Error(err) -> {
      should.fail()
      let _ = err
      Nil
    }
  }

  teardown(root)
}

pub fn discover_returns_no_marker_when_none_present_test() {
  let root = setup()
  let file_uri = "file://" <> root <> "/project/src/main.rs"

  // Looking for a marker that is not present anywhere on the path.
  let result =
    workspace_root.discover_from_uri(file_uri, ["NonExistentMarker.toml"])

  result |> should.equal(Error(workspace_root.NoMarkerFound))

  teardown(root)
}

pub fn discover_picks_innermost_match_test() {
  let root = setup()
  // Add an outer Cargo.toml too — discover should still find /project's
  // (the innermost ancestor with a match).
  let _ = shell("printf '[workspace]\\n' > " <> root <> "/Cargo.toml")
  let file_uri = "file://" <> root <> "/project/src/main.rs"

  let assert Ok(found) =
    workspace_root.discover_from_uri(file_uri, ["Cargo.toml"])
  should.be_true(string.ends_with(found, "/project"))

  teardown(root)
}
