//// Workspace-root discovery and `file://` URI helpers.
////
//// Given a file URI like `file:///home/oof/game/src/main.rs`, the
//// LSP needs the workspace root URI for the `initialize` request —
//// for Rust that means the directory containing the relevant
//// `Cargo.toml`. This module ascends the directory tree from the
//// file's parent looking for any of the configured root markers.
////
//// Pure-style API at the Gleam level. The Erlang FFI in
//// `pharos_fs_ffi` does the actual disk checks.

import gleam/list
import gleam/string

pub type DiscoveryError {
  /// Caller passed a URI that did not start with `file://`.
  NotAFileUri(uri: String)
  /// Walked all the way to the filesystem root without finding any
  /// of the configured markers.
  NoMarkerFound
}

@external(erlang, "pharos_fs_ffi", "is_regular_file")
fn is_regular_file(path: String) -> Bool

@external(erlang, "pharos_fs_ffi", "dirname")
fn dirname(path: String) -> String

@external(erlang, "pharos_fs_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, String)

/// Strip `file://` from a URI to get a local filesystem path. Does
/// not validate the path exists.
pub fn uri_to_path(uri: String) -> Result(String, DiscoveryError) {
  case string.starts_with(uri, "file://") {
    True -> Ok(string.drop_start(uri, 7))
    False -> Error(NotAFileUri(uri))
  }
}

/// Encode a filesystem path as a `file://` URI. Inverse of
/// `uri_to_path` for absolute paths. Does not URL-encode special
/// characters — sufficient for the paths LSPs actually deal with.
pub fn path_to_uri(path: String) -> String {
  "file://" <> path
}

/// Ascend the directory tree from a starting directory until a
/// directory containing any marker file is found.
///
/// `markers` is a list of basenames (e.g. `["Cargo.toml",
/// "rust-project.json"]`). The first match wins.
pub fn discover_from_dir(
  start_dir: String,
  markers: List(String),
) -> Result(String, DiscoveryError) {
  ascend(start_dir, markers)
}

/// Convenience: take a `file://` URI and ascend from the file's
/// parent directory.
pub fn discover_from_uri(
  uri: String,
  markers: List(String),
) -> Result(String, DiscoveryError) {
  case uri_to_path(uri) {
    Error(err) -> Error(err)
    Ok(path) -> ascend(dirname(path), markers)
  }
}

fn ascend(
  dir: String,
  markers: List(String),
) -> Result(String, DiscoveryError) {
  case has_any_marker(dir, markers) {
    True -> Ok(dir)
    False -> {
      let parent = dirname(dir)
      case parent == dir {
        // hit filesystem root
        True -> Error(NoMarkerFound)
        False -> ascend(parent, markers)
      }
    }
  }
}

fn has_any_marker(dir: String, markers: List(String)) -> Bool {
  list.any(markers, fn(marker) {
    is_regular_file(join_path(dir, marker))
  })
}

fn join_path(dir: String, basename: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> basename
    False -> dir <> "/" <> basename
  }
}
