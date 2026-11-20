//// Tests for `pharos/workspace_root`.
////
//// Filesystem-backed: tests construct a temp directory layout and
//// run discovery against it. Layout is cleaned up afterward.

import gleam/list
import gleam/string
import gleeunit/should
import pharos/workspace_root

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_fs_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn atomic_write_text(path: String, text: String) -> Result(Nil, String)

fn temp_dir() -> String {
  // Tests rm -rf first, so a stable suffix is fine.
  "/tmp/pharos_workspace_root_test"
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

// -- #16: escaped characters in file:// URIs --------------------------------

pub fn uri_to_path_decodes_escapes_test() {
  workspace_root.uri_to_path("file:///tmp/my%20proj/a%23b/100%25/caf%C3%A9.ts")
  |> should.equal(Ok("/tmp/my proj/a#b/100%/café.ts"))
}

pub fn uri_to_path_keeps_a_raw_unescaped_path_test() {
  // A client that didn't encode: a space and a lone `%` stay as they are.
  workspace_root.uri_to_path("file:///tmp/my proj/100%/a.ts")
  |> should.equal(Ok("/tmp/my proj/100%/a.ts"))
}

pub fn path_to_uri_encodes_what_vscode_uri_does_test() {
  workspace_root.path_to_uri("/tmp/my proj/a#b/100%/café.ts")
  |> should.equal("file:///tmp/my%20proj/a%23b/100%25/caf%C3%A9.ts")
  workspace_root.path_to_uri("/home/u/src/a-b_c.d~e/f.rs")
  |> should.equal("file:///home/u/src/a-b_c.d~e/f.rs")
}

pub fn path_to_uri_round_trips_test() {
  let path = "/tmp/a b/#x/%y/ü/@+[].ts"
  workspace_root.path_to_uri(path)
  |> workspace_root.uri_to_path
  |> should.equal(Ok(path))
}

pub fn canonical_uri_joins_every_spelling_test() {
  let canonical = "file:///tmp/my%20proj/x%40y%2Bz.ts"
  // raw, as vscode-uri escapes, as Rust's `url` escapes (`@` `+` raw),
  // lowercase hex
  [
    "file:///tmp/my proj/x@y+z.ts",
    "file:///tmp/my%20proj/x%40y%2Bz.ts",
    "file:///tmp/my%20proj/x@y+z.ts",
    "file:///tmp/my%20proj/x%40y%2bz.ts",
  ]
  |> list.map(workspace_root.canonical_uri)
  |> should.equal([canonical, canonical, canonical, canonical])
  workspace_root.canonical_uri("jdt://contents/a.jar/b/C.class?x=%20")
  |> should.equal("jdt://contents/a.jar/b/C.class?x=%20")
}

pub fn discover_from_uri_with_escaped_characters_test() {
  let root = "/tmp/pharos_workspace_root_test_16/with space #1 100% é"
  // Through the fs FFI, not `shell`: the path must reach the file
  // system as its own bytes (`binary_to_list` read each UTF-8 byte of
  // `é` as a character).
  let assert Ok(Nil) = mkdir_p(root <> "/project/src")
  let assert Ok(Nil) = atomic_write_text(root <> "/project/Cargo.toml", "")
  let uri = workspace_root.path_to_uri(root <> "/project/src/main.rs")
  should.be_true(string.contains(uri, "%20"))
  workspace_root.discover_from_uri(uri, ["Cargo.toml"])
  |> should.equal(Ok(root <> "/project"))
  let _ = shell("rm -rf /tmp/pharos_workspace_root_test_16")
  Nil
}

// -- file://localhost (RFC 8089) --------------------------------------------

pub fn uri_to_path_accepts_a_localhost_authority_test() {
  workspace_root.uri_to_path("file://localhost/tmp/a%20b/c.ts")
  |> should.equal(Ok("/tmp/a b/c.ts"))
  workspace_root.uri_to_path("file://LocalHost/tmp/c.ts")
  |> should.equal(Ok("/tmp/c.ts"))
  workspace_root.canonical_uri("file://localhost/tmp/a%20b/c.ts")
  |> should.equal("file:///tmp/a%20b/c.ts")
}

pub fn uri_to_path_refuses_another_host_test() {
  workspace_root.uri_to_path("file://server/share/c.ts")
  |> should.equal(Error(workspace_root.NotAFileUri("file://server/share/c.ts")))
  // A relative path reads as a host, per the RFC.
  workspace_root.uri_to_path("file://src/a.ts")
  |> should.equal(Error(workspace_root.NotAFileUri("file://src/a.ts")))
  workspace_root.uri_to_path("file://")
  |> should.equal(Error(workspace_root.NotAFileUri("file://")))
}
