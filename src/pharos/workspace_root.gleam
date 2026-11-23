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
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/string
import gleam/uri as gleam_uri

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

/// The local filesystem path of a `file://` URI: `file://` stripped and
/// percent-escapes decoded (`%20` is a space). Text that isn't a valid
/// escape (a raw `%` from a client that didn't encode) is kept as it is.
/// Does not validate the path exists.
///
/// The authority must be empty (`file:///path`) or `localhost`
/// (`file://localhost/path`, RFC 8089). Any other host names a file on
/// another machine, and is refused as not a local file URI.
pub fn uri_to_path(uri: String) -> Result(String, DiscoveryError) {
  // #42: `file:/abs` (no authority at all) is RFC 8089's form too, and
  // jdtls sends it: the same file as `file:///abs`.
  let uri = case
    string.starts_with(uri, "file:/") && !string.starts_with(uri, "file://")
  {
    True -> "file://" <> string.drop_start(uri, 5)
    False -> uri
  }
  case string.starts_with(uri, "file://") {
    True -> {
      let rest = string.drop_start(uri, 7)
      case local_path(rest) {
        Ok(raw) ->
          Ok(case gleam_uri.percent_decode(raw) {
            Ok(decoded) -> decoded
            Error(Nil) -> raw
          })
        Error(Nil) -> Error(NotAFileUri(uri))
      }
    }
    False -> Error(NotAFileUri(uri))
  }
}

/// The path part of a file URI after `file://`: itself when it starts
/// with `/` (an empty authority), the rest after a `localhost` authority
/// (in any case), else Error.
fn local_path(rest: String) -> Result(String, Nil) {
  case rest {
    // `file:////tmp/a` is an empty authority and the path `//tmp/a`,
    // which names /tmp/a. Keep one leading slash, so it routes to the
    // same workspace and server as `file:///tmp/a`.
    "//" <> more -> local_path("/" <> more)
    "/" <> _ -> Ok(rest)
    _ ->
      case string.split_once(rest, "/") {
        Ok(#(host, path)) ->
          case string.lowercase(host) == "localhost" {
            True -> Ok("/" <> path)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Why `uri` isn't a local file URI, and what to send instead. For an
/// error message: agents write `file://src/a.ts` meaning a relative path,
/// and RFC 8089 reads `src` as a host.
pub fn describe_not_local(uri: String) -> String {
  case string.starts_with(uri, "file://") {
    False ->
      case string.split_once(uri, "://"), string.starts_with(uri, "file:") {
        // A virtual URI (jdt://): the tool works on files on disk.
        Ok(#(scheme, _)), False if scheme != "" ->
          uri
          <> " is not a file on disk ("
          <> scheme
          <> "://): this tool works on local files only; use file:///absolute/path"
        _, True -> uri <> " has a relative path: use file:///absolute/path"
        _, False ->
          case string.starts_with(uri, "/") {
            True -> uri <> " is a path, not a URI: use file://" <> uri
            False ->
              uri <> " is a relative path, not a URI: use file:///absolute/path"
          }
      }
    True ->
      case string.split_once(string.drop_start(uri, 7), "/") {
        Ok(#(host, _)) if host != "" ->
          uri
          <> " names the host `"
          <> host
          <> "`, not a local file: use file:///absolute/path (or file://localhost/absolute/path)"
        _ -> uri <> " has no path: use file:///absolute/path"
      }
  }
}

/// Encode an absolute filesystem path as a `file://` URI, the inverse of
/// `uri_to_path`. Every byte but the unreserved characters
/// (`A-Z a-z 0-9 - . _ ~`) and `/` is percent-encoded, as vscode-uri
/// (typescript-language-server's) does for them: a space is `%20`, `#`
/// `%23`, `%` `%25`, and a non-ASCII character its UTF-8 bytes (#16).
pub fn path_to_uri(path: String) -> String {
  "file://" <> encode_path(<<path:utf8>>, "")
}

/// One spelling for a `file://` URI however its client or server
/// escaped it: decoded, then encoded as `path_to_uri` does. Anything
/// else (a `jdt://` URI) is returned as it is. Keys that must match
/// across spellings use it: the tools' `uri` arguments and the
/// diagnostics cache, whose publishes come from servers that escape
/// differently (#16).
pub fn canonical_uri(uri: String) -> String {
  case uri_to_path(uri) {
    Ok(path) -> path_to_uri(path)
    Error(_) -> uri
  }
}

/// A decoder for a tool's `uri` argument, canonical as `canonical_uri`.
pub fn uri_decoder() -> decode.Decoder(String) {
  decode.string |> decode.map(canonical_uri)
}

fn encode_path(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<>> -> acc
    <<b:int, rest:bits>> -> {
      let piece = case is_kept(b) {
        True -> {
          let assert Ok(c) = bit_array.to_string(<<b:int>>)
          c
        }
        False -> "%" <> string.pad_start(int.to_base16(b), 2, "0")
      }
      encode_path(rest, acc <> piece)
    }
    _ -> acc
  }
}

fn is_kept(b: Int) -> Bool {
  { b >= 0x41 && b <= 0x5A }
  || { b >= 0x61 && b <= 0x7A }
  || { b >= 0x30 && b <= 0x39 }
  || b == 0x2D
  || b == 0x2E
  || b == 0x5F
  || b == 0x7E
  || b == 0x2F
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
