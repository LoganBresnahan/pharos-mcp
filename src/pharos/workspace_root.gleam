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

import gleam/bit_array
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

@external(erlang, "pharos_fs_ffi", "is_directory")
fn is_directory(path: String) -> Bool

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

/// Like `discover_from_uri/2` but tolerant of directory URIs. If the
/// URI's path resolves to an existing directory we ascend from the
/// directory itself; otherwise we fall back to the file-style
/// `dirname`-then-ascend behaviour. Used by `workspace_symbols` so
/// callers can pass either a workspace root URI (`file:///proj/`) or
/// a file URI inside the workspace.
pub fn discover_from_uri_or_dir(
  uri: String,
  markers: List(String),
) -> Result(String, DiscoveryError) {
  case uri_to_path(uri) {
    Error(err) -> Error(err)
    Ok(path) ->
      case is_directory(path) {
        True -> ascend(path, markers)
        False -> ascend(dirname(path), markers)
      }
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
  // Markers can be regular files (`Cargo.toml`, `mix.exs`, etc.) OR
  // directories (`.git` — universal project root marker; in worktrees
  // it's a file but in normal repos it's a directory). Accept either
  // so the bash language entry's `.git` fallback works in regular
  // repos too.
  list.any(markers, fn(marker) {
    let path = join_path(dir, marker)
    is_regular_file(path) || is_directory(path)
  })
}

fn join_path(dir: String, basename: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> basename
    False -> dir <> "/" <> basename
  }
}

/// Cargo workspace promotion (ADR-015). Given a starting directory
/// (typically the result of `discover_from_uri` for a `.rs` file),
/// walk upwards looking for any Cargo.toml whose `[workspace]`
/// heading is present. Promotes to the outermost match. Returns the
/// original dir unchanged if no ancestor workspace is found.
///
/// The check is a line-scan for `[workspace]` or `[workspace.`,
/// which matches both `[workspace]` itself and any
/// `[workspace.metadata]` / `[workspace.dependencies]` subtable.
/// Both shapes only appear in the workspace root Cargo.toml; member
/// crates reference workspace deps via `dep.workspace = true` in
/// `[dependencies]`, not via `[workspace.*]` headings.
pub fn promote_to_cargo_workspace(start_dir: String) -> String {
  promote_walk(start_dir, start_dir)
}

fn promote_walk(current: String, best: String) -> String {
  let updated_best = case is_cargo_workspace_root(current) {
    True -> current
    False -> best
  }
  let parent = dirname(current)
  case parent == current {
    True -> updated_best
    False -> promote_walk(parent, updated_best)
  }
}

fn is_cargo_workspace_root(dir: String) -> Bool {
  let path = join_path(dir, "Cargo.toml")
  case is_regular_file(path) {
    False -> False
    True ->
      case read_file(path) {
        Error(_) -> False
        Ok(bytes) ->
          case bit_array.to_string(bytes) {
            Error(_) -> False
            Ok(text) ->
              string.contains(text, "[workspace]")
              || string.contains(text, "[workspace.")
          }
      }
  }
}
