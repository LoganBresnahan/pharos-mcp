//// The file watchers a server registers for
//// `workspace/didChangeWatchedFiles` (ADR-043), recorded per LSP proc.
////
//// pharos advertises `workspace.didChangeWatchedFiles.dynamicRegistration`
//// so servers that rely on their client to watch files (gopls, pyright,
//// next-ls, zls) register their globs. `client/registerCapability` and
//// `client/unregisterCapability` run inside the proc, so the table is
//// keyed by the proc's pid. The watched-files scan reads it to decide
//// whether a server wants events and which paths match.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import pharos/lsp/glob

/// One watcher: a glob, matched against the absolute path or, for a
/// `RelativePattern`, against the path relative to `base` (a directory
/// path, not a URI). `kind` is LSP's WatchKind bit set: Create 1,
/// Change 2, Delete 4.
pub type Watcher {
  Watcher(pattern: String, base: Option(String), kind: Int)
}

/// The ETS table behind the register handler. Called at boot.
@external(erlang, "pharos_watch_ffi", "watchers_init")
pub fn init() -> Nil

@external(erlang, "pharos_watch_ffi", "watchers_put")
fn put(registration_id: String, watchers: List(Watcher)) -> Nil

@external(erlang, "pharos_watch_ffi", "watchers_delete")
fn delete(registration_id: String) -> Nil

/// Every watcher `pid`'s server has registered.
@external(erlang, "pharos_watch_ffi", "watchers_for")
pub fn for_proc(pid: Pid) -> List(Watcher)

/// Forgets a proc's registrations.
@external(erlang, "pharos_watch_ffi", "watchers_forget")
pub fn forget(pid: Pid) -> Nil

/// `client/registerCapability`'s params: records the
/// `workspace/didChangeWatchedFiles` registrations among them, for the
/// calling proc. Other registrations are acknowledged and ignored, as
/// before.
pub fn record_registrations(params: Dynamic) -> Nil {
  let registration = {
    use id <- decode.field("id", decode.string)
    use method <- decode.field("method", decode.string)
    use watchers <- decode.optional_field(
      "registerOptions",
      [],
      decode.optional_field(
        "watchers",
        [],
        decode.list(watcher_decoder()),
        decode.success,
      ),
    )
    decode.success(#(id, method, watchers))
  }
  case
    decode.run(params, decode.at(["registrations"], decode.list(registration)))
  {
    Ok(registrations) ->
      list.each(registrations, fn(r) {
        case r {
          #(id, "workspace/didChangeWatchedFiles", watchers) ->
            put(id, watchers)
          _ -> Nil
        }
      })
    Error(_) -> Nil
  }
}

/// `client/unregisterCapability`'s params (the spec's misspelt
/// `unregisterations` key).
pub fn record_unregistrations(params: Dynamic) -> Nil {
  let unregistration = {
    use id <- decode.field("id", decode.string)
    use method <- decode.field("method", decode.string)
    decode.success(#(id, method))
  }
  case
    decode.run(
      params,
      decode.at(["unregisterations"], decode.list(unregistration)),
    )
  {
    Ok(items) ->
      list.each(items, fn(item) {
        case item {
          #(id, "workspace/didChangeWatchedFiles") -> delete(id)
          _ -> Nil
        }
      })
    Error(_) -> Nil
  }
}

fn watcher_decoder() -> decode.Decoder(Watcher) {
  let relative = {
    use base <- decode.field(
      "baseUri",
      decode.one_of(decode.string, [
        decode.at(["uri"], decode.string),
      ]),
    )
    use pattern <- decode.field("pattern", decode.string)
    decode.success(#(pattern, Some(uri_to_path(base))))
  }
  let glob_pattern =
    decode.one_of(decode.map(decode.string, fn(p) { #(p, None) }), [relative])
  use #(pattern, base) <- decode.field("globPattern", glob_pattern)
  use kind <- decode.optional_field("kind", 7, decode.int)
  decode.success(Watcher(pattern: pattern, base: base, kind: kind))
}

/// The WatchKind bit for a change: Create 1, Change 2, Delete 4.
pub fn kind_bit(change: Int) -> Int {
  case change {
    1 -> 1
    2 -> 2
    _ -> 4
  }
}

/// True when some watcher wants `path` (absolute) for a change whose
/// FileChangeType is `change` (Created 1, Changed 2, Deleted 3).
pub fn wanted(watchers: List(Watcher), path: String, change: Int) -> Bool {
  let bit = kind_bit(change)
  list.any(watchers, fn(w) {
    int_and(w.kind, bit) != 0
    && case w.base {
      None -> glob.matches(w.pattern, path)
      Some(base) ->
        case string.starts_with(path, base <> "/") {
          True ->
            glob.matches(
              w.pattern,
              string.drop_start(path, string.length(base) + 1),
            )
          False -> False
        }
    }
  })
}

@external(erlang, "erlang", "band")
fn int_and(a: Int, b: Int) -> Int

/// A `file://` URI's path, percent-decoded; anything else as given.
fn uri_to_path(uri: String) -> String {
  case string.starts_with(uri, "file://") {
    True -> {
      let path = string.drop_start(uri, 7)
      let path = case string.starts_with(path, "localhost/") {
        True -> string.drop_start(path, 9)
        False -> path
      }
      let path = case string.ends_with(path, "/") {
        True -> string.drop_end(path, 1)
        False -> path
      }
      percent_decode(path)
    }
    False -> uri
  }
}

@external(erlang, "uri_string", "percent_decode")
fn percent_decode(text: String) -> String
