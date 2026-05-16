//// Unit tests for the strict frontmatter parser (ADR-027 §4).

import gleeunit/should
import pharos/tools/memory_frontmatter.{
  ForbiddenShape, Frontmatter, InvalidType, MissingClosingFence,
  MissingOpeningFence, MissingRequiredField, UnknownField,
}

const valid_file: String = "---
name: ingestion-pipeline
type: project
description: rewrite driven by legal/compliance
created: 2026-05-16T07:30:00Z
last_accessed: 2026-05-16T07:30:00Z
---
The body lives here.
Across multiple lines.
"

pub fn parse_valid_round_trip_test() {
  case memory_frontmatter.parse(valid_file) {
    Ok(#(fm, body)) -> {
      should.equal(fm.name, "ingestion-pipeline")
      should.equal(fm.type_, "project")
      should.equal(fm.description, "rewrite driven by legal/compliance")
      should.equal(fm.created, "2026-05-16T07:30:00Z")
      should.equal(fm.last_accessed, "2026-05-16T07:30:00Z")
      should.equal(body, "The body lives here.\nAcross multiple lines.\n")
    }
    Error(_) -> should.fail()
  }
}

pub fn serialize_then_parse_round_trip_test() {
  let fm =
    Frontmatter(
      name: "x",
      type_: "user",
      description: "desc",
      created: "2026-01-01T00:00:00Z",
      last_accessed: "2026-01-02T00:00:00Z",
    )
  let serialized = memory_frontmatter.serialize(fm, "body content\n")
  case memory_frontmatter.parse(serialized) {
    Ok(#(parsed, body)) -> {
      should.equal(parsed, fm)
      should.equal(body, "body content\n")
    }
    Error(_) -> should.fail()
  }
}

pub fn reject_missing_opening_fence_test() {
  let bad = "name: foo\ntype: user\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(MissingOpeningFence) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_missing_closing_fence_test() {
  let bad = "---\nname: foo\ntype: user\ndescription: x\n"
  case memory_frontmatter.parse(bad) {
    Error(MissingClosingFence) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_quoted_string_test() {
  let bad =
    "---\nname: \"foo\"\ntype: user\ndescription: x\ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(ForbiddenShape(_)) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_multiline_block_scalar_test() {
  let bad =
    "---\nname: foo\ntype: user\ndescription: |\n  multi\n  line\ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(ForbiddenShape(_)) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_comment_line_test() {
  let bad =
    "---\n# a comment\nname: foo\ntype: user\ndescription: x\ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(ForbiddenShape(_)) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_unknown_field_test() {
  // No flow syntax — value is plain, so the shape check passes and
  // the unknown-field check fires next.
  let bad =
    "---\nname: foo\ntype: user\ntags: a-b-c\ndescription: x\ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(UnknownField(_)) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_flow_syntax_test() {
  let bad =
    "---\nname: foo\ntype: user\ndescription: [a, b]\ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(ForbiddenShape(_)) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_invalid_type_test() {
  let bad =
    "---\nname: foo\ntype: invalid\ndescription: x\ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(InvalidType(_)) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn reject_missing_required_field_test() {
  let bad =
    "---\nname: foo\ntype: user\ndescription: x\ncreated: a\n---\n"
  case memory_frontmatter.parse(bad) {
    Error(MissingRequiredField("last_accessed")) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn allow_iso_timestamp_with_colons_in_value_test() {
  // Critical: ISO-8601 timestamps contain `:`. Parser must split on
  // FIRST `:` only, not naive split.
  let ok =
    "---\nname: x\ntype: user\ndescription: x\ncreated: 2026-05-16T07:30:00Z\nlast_accessed: 2026-05-16T07:30:00Z\n---\n"
  case memory_frontmatter.parse(ok) {
    Ok(#(fm, _)) -> should.equal(fm.created, "2026-05-16T07:30:00Z")
    Error(_) -> should.fail()
  }
}

pub fn allow_description_with_colons_test() {
  // Description should accept colons (it's prose).
  let ok =
    "---\nname: x\ntype: user\ndescription: was X: now Y\ncreated: 2026-05-16T07:30:00Z\nlast_accessed: 2026-05-16T07:30:00Z\n---\n"
  case memory_frontmatter.parse(ok) {
    Ok(#(fm, _)) -> should.equal(fm.description, "was X: now Y")
    Error(_) -> should.fail()
  }
}

pub fn trim_trailing_whitespace_test() {
  let ok =
    "---\nname:   x   \ntype:   user  \ndescription:   d  \ncreated: a\nlast_accessed: b\n---\n"
  case memory_frontmatter.parse(ok) {
    Ok(#(fm, _)) -> {
      should.equal(fm.name, "x")
      should.equal(fm.type_, "user")
    }
    Error(_) -> should.fail()
  }
}
