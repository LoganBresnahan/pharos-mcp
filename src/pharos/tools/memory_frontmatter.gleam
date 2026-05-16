//// Strict YAML-frontmatter parser/serializer for pharos memory files.
//// See ADR-027 §4. This is NOT a YAML parser — it accepts a fixed
//// 5-field subset and rejects anything fancier (quoted strings,
//// flow syntax, multi-line block scalars). Strictness is the
//// feature: `memory_save` is the canonical writer (typed args →
//// deterministic compliant output), so non-conforming files only
//// appear via out-of-band hand-edits.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string

pub type Frontmatter {
  Frontmatter(
    name: String,
    type_: String,
    description: String,
    created: String,
    last_accessed: String,
  )
}

pub type ParseError {
  MissingOpeningFence
  MissingClosingFence
  MissingRequiredField(field: String)
  UnknownField(field: String)
  InvalidLineFormat(line: String)
  ForbiddenShape(reason: String)
  InvalidType(value: String)
}

const known_types = ["user", "project", "feedback", "reference"]

const required_fields = [
  "name",
  "type",
  "description",
  "created",
  "last_accessed",
]

/// Parse `text` (full file content) into `(Frontmatter, body)`.
///
/// Format:
///   ---
///   key: value
///   key: value
///   ...
///   ---
///   <body>
///
/// Strict: rejects quoted strings, flow syntax, multi-line block
/// scalars, comments, unknown fields. The `description` field allows
/// any chars after the first `:` so descriptions can contain colons.
pub fn parse(text: String) -> Result(#(Frontmatter, String), ParseError) {
  let lines = string.split(text, "\n")
  case lines {
    [first, ..rest] ->
      case string.trim_end(first) == "---" {
        False -> Error(MissingOpeningFence)
        True -> parse_after_opener(rest)
      }
    _ -> Error(MissingOpeningFence)
  }
}

fn parse_after_opener(
  lines: List(String),
) -> Result(#(Frontmatter, String), ParseError) {
  use #(fm_lines, body_lines) <- result.try(take_until_closer(lines, []))
  use raw <- result.try(parse_fields(fm_lines, dict.new()))
  use fm <- result.try(materialize(raw))
  Ok(#(fm, string.join(body_lines, "\n")))
}

fn take_until_closer(
  lines: List(String),
  acc: List(String),
) -> Result(#(List(String), List(String)), ParseError) {
  case lines {
    [] -> Error(MissingClosingFence)
    [head, ..rest] ->
      case string.trim_end(head) == "---" {
        True -> Ok(#(list.reverse(acc), rest))
        False -> take_until_closer(rest, [head, ..acc])
      }
  }
}

fn parse_fields(
  lines: List(String),
  acc: Dict(String, String),
) -> Result(Dict(String, String), ParseError) {
  case lines {
    [] -> Ok(acc)
    [head, ..rest] -> {
      let trimmed = string.trim(head)
      case trimmed {
        "" -> parse_fields(rest, acc)
        _ ->
          case validate_line_shape(trimmed) {
            Error(reason) -> Error(ForbiddenShape(reason))
            Ok(_) ->
              case split_first_colon(trimmed) {
                Error(_) -> Error(InvalidLineFormat(head))
                Ok(#(key, value)) -> {
                  let key_trim = string.trim(key)
                  let value_trim = string.trim(value)
                  case list.contains(required_fields, key_trim) {
                    False -> Error(UnknownField(key_trim))
                    True ->
                      parse_fields(
                        rest,
                        dict.insert(acc, key_trim, value_trim),
                      )
                  }
                }
              }
          }
      }
    }
  }
}

fn validate_line_shape(line: String) -> Result(Nil, String) {
  // Comment line — pure shape rejection, value irrelevant.
  case string.starts_with(line, "#") {
    True -> Error("comments not allowed")
    False -> {
      // Multi-line block scalar markers — these mean the value
      // continues on subsequent lines, which our line-by-line parser
      // can't handle.
      let has_pipe =
        string.contains(line, ": |") || string.contains(line, ": >")
      case has_pipe {
        True -> Error("multi-line block scalars not allowed")
        False ->
          // Inspect the value half. Reject if the value is a
          // fully-quoted string (LLM trying to wrap output) or a
          // flow-collection (`[...]` / `{...}`).
          case string.split_once(line, ":") {
            Error(_) -> Ok(Nil)
            Ok(#(_, raw_value)) -> {
              let v = string.trim(raw_value)
              let fully_double_quoted =
                string.starts_with(v, "\"") && string.ends_with(v, "\"")
                && string.length(v) >= 2
              let fully_single_quoted =
                string.starts_with(v, "'") && string.ends_with(v, "'")
                && string.length(v) >= 2
              let is_flow =
                string.starts_with(v, "[") || string.starts_with(v, "{")
              case fully_double_quoted, fully_single_quoted, is_flow {
                True, _, _ -> Error("quoted strings not allowed")
                _, True, _ -> Error("quoted strings not allowed")
                _, _, True -> Error("flow syntax not allowed")
                _, _, _ -> Ok(Nil)
              }
            }
          }
      }
    }
  }
}

fn split_first_colon(s: String) -> Result(#(String, String), Nil) {
  case string.split_once(s, ":") {
    Ok(pair) -> Ok(pair)
    Error(_) -> Error(Nil)
  }
}

fn materialize(raw: Dict(String, String)) -> Result(Frontmatter, ParseError) {
  use name <- result.try(
    dict.get(raw, "name")
    |> result.replace_error(MissingRequiredField("name")),
  )
  use type_ <- result.try(
    dict.get(raw, "type")
    |> result.replace_error(MissingRequiredField("type")),
  )
  use description <- result.try(
    dict.get(raw, "description")
    |> result.replace_error(MissingRequiredField("description")),
  )
  use created <- result.try(
    dict.get(raw, "created")
    |> result.replace_error(MissingRequiredField("created")),
  )
  use last_accessed <- result.try(
    dict.get(raw, "last_accessed")
    |> result.replace_error(MissingRequiredField("last_accessed")),
  )
  case list.contains(known_types, type_) {
    False -> Error(InvalidType(type_))
    True ->
      Ok(Frontmatter(
        name: name,
        type_: type_,
        description: description,
        created: created,
        last_accessed: last_accessed,
      ))
  }
}

/// Serialize `Frontmatter` + body back to a complete file string.
/// Output is always strict-shape-compliant — `parse` will accept it.
pub fn serialize(fm: Frontmatter, body: String) -> String {
  "---\n"
  <> "name: " <> fm.name <> "\n"
  <> "type: " <> fm.type_ <> "\n"
  <> "description: " <> fm.description <> "\n"
  <> "created: " <> fm.created <> "\n"
  <> "last_accessed: " <> fm.last_accessed <> "\n"
  <> "---\n"
  <> body
}

pub fn describe_error(err: ParseError) -> String {
  case err {
    MissingOpeningFence -> "frontmatter must begin with `---` on line 1"
    MissingClosingFence -> "frontmatter must end with `---`"
    MissingRequiredField(f) -> "missing required field: " <> f
    UnknownField(f) ->
      "unknown frontmatter field: " <> f <> " (allowed: name, type, "
      <> "description, created, last_accessed)"
    InvalidLineFormat(l) -> "malformed line (expected `key: value`): " <> l
    ForbiddenShape(r) -> "frontmatter shape rejected: " <> r
    InvalidType(v) ->
      "type must be one of {user, project, feedback, reference}, got: " <> v
  }
}
