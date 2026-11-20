//// LSP glob patterns (`GlobPattern`, LSP 3.17), for the watchers a server
//// registers through `workspace/didChangeWatchedFiles` (ADR-043).
////
//// - `*` matches any run of characters within one path segment;
//// - `?` matches one character within a segment;
//// - `**` matches any number of whole segments, none included;
//// - `{a,b}` matches either alternative (nesting allowed);
//// - `[abc]`, `[a-z]` match one character from the set, `[!abc]` one not
////   in it.
////
//// A pattern is matched against a whole path: `**/*.go` against an
//// absolute path, a `RelativePattern`'s pattern against the path relative
//// to its base.

import gleam/list
import gleam/order
import gleam/string

/// True when `path` (segments separated by `/`) matches `pattern`.
pub fn matches(pattern: String, path: String) -> Bool {
  let path_segments = segments(path)
  expand_braces(pattern)
  |> list.any(fn(alternative) {
    match_segments(segments(alternative), path_segments)
  })
}

fn segments(path: String) -> List(String) {
  string.split(path, "/") |> list.filter(fn(s) { s != "" })
}

// -- Braces ---------------------------------------------------------------

/// Every pattern a `{a,b}` group stands for, innermost groups expanded
/// through the outer ones. A pattern without a group is itself.
pub fn expand_braces(pattern: String) -> List(String) {
  case split_first_group(string.to_graphemes(pattern), []) {
    Error(Nil) -> [pattern]
    Ok(#(before, alternatives, after)) ->
      list.flat_map(alternatives, fn(alt) {
        expand_braces(before <> alt <> after)
      })
  }
}

/// The text before the first top-level `{...}`, its comma-separated
/// alternatives (commas at depth 1 only), and the text after.
fn split_first_group(
  chars: List(String),
  before: List(String),
) -> Result(#(String, List(String), String), Nil) {
  case chars {
    [] -> Error(Nil)
    ["{", ..rest] ->
      case take_group(rest, 1, [], []) {
        Ok(#(alternatives, after)) ->
          Ok(#(
            string.concat(list.reverse(before)),
            alternatives,
            string.concat(after),
          ))
        Error(Nil) -> Error(Nil)
      }
    [c, ..rest] -> split_first_group(rest, [c, ..before])
  }
}

/// Reads up to the `}` closing a group at `depth`. `current` is the
/// alternative being read (reversed), `done` the ones read (reversed).
fn take_group(
  chars: List(String),
  depth: Int,
  current: List(String),
  done: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case chars {
    [] -> Error(Nil)
    ["}", ..rest] if depth == 1 ->
      Ok(#(list.reverse([string.concat(list.reverse(current)), ..done]), rest))
    [",", ..rest] if depth == 1 ->
      take_group(rest, depth, [], [string.concat(list.reverse(current)), ..done])
    ["{" as c, ..rest] -> take_group(rest, depth + 1, [c, ..current], done)
    ["}" as c, ..rest] -> take_group(rest, depth - 1, [c, ..current], done)
    [c, ..rest] -> take_group(rest, depth, [c, ..current], done)
  }
}

// -- Segments -------------------------------------------------------------

fn match_segments(pattern: List(String), path: List(String)) -> Bool {
  case pattern, path {
    [], [] -> True
    ["**", ..rest], _ ->
      // `**` takes no segments, or one more and stays.
      match_segments(rest, path)
      || case path {
        [_, ..path_rest] -> match_segments(pattern, path_rest)
        [] -> False
      }
    [], _ -> False
    _, [] -> False
    [p, ..p_rest], [s, ..s_rest] ->
      match_segment(string.to_graphemes(p), string.to_graphemes(s))
      && match_segments(p_rest, s_rest)
  }
}

fn match_segment(pattern: List(String), text: List(String)) -> Bool {
  case pattern, text {
    [], [] -> True
    ["*", ..rest], _ ->
      match_segment(rest, text)
      || case text {
        [_, ..text_rest] -> match_segment(pattern, text_rest)
        [] -> False
      }
    ["?", ..rest], [_, ..text_rest] -> match_segment(rest, text_rest)
    ["[", ..rest], [c, ..text_rest] ->
      case read_class(rest, []) {
        Ok(#(class, after)) ->
          class_matches(class, c) && match_segment(after, text_rest)
        // An unclosed `[` is a literal.
        Error(Nil) -> c == "[" && match_segment(rest, text_rest)
      }
    [p, ..rest], [c, ..text_rest] -> p == c && match_segment(rest, text_rest)
    _, _ -> False
  }
}

/// The characters of a `[...]` class up to its `]`, and what follows.
fn read_class(
  chars: List(String),
  acc: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case chars {
    [] -> Error(Nil)
    // A `]` first in the class is a member, not the end.
    ["]", ..rest] if acc != [] -> Ok(#(list.reverse(acc), rest))
    [c, ..rest] -> read_class(rest, [c, ..acc])
  }
}

fn class_matches(class: List(String), c: String) -> Bool {
  case class {
    ["!", ..members] | ["^", ..members] -> !in_class(members, c)
    members -> in_class(members, c)
  }
}

fn in_class(members: List(String), c: String) -> Bool {
  case members {
    [] -> False
    [low, "-", high, ..rest] ->
      {
        string.compare(low, c) != order.Gt
        && string.compare(c, high) != order.Gt
      }
      || in_class(rest, c)
    [m, ..rest] -> m == c || in_class(rest, c)
  }
}
