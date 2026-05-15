//// Unit tests for the symbol-layer module (ADR-026).
////
//// Covers the pure, LSP-free surface: name_path parsing,
//// disambiguation policy collapse, edit-mode parsing, and the
//// resolution-to-json projection. Tree-walk drill + LSP-bound
//// paths (find_symbol against a live workspace, edit_at_symbol
//// preview rendering on a real file) are exercised by the
//// dogfood harness once we wire the four MCP tools through it.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pharos/tools/symbols.{
  InsertAfter, InsertBefore, Multiple, NotFound, ReplaceBody, Single,
}

// -- parse_name_path -----------------------------------------------------

pub fn parse_name_path_single_segment_test() {
  case symbols.parse_name_path("User") {
    Ok(np) -> should.equal(symbols.name_path_parts(np), ["User"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_two_segments_test() {
  case symbols.parse_name_path("User/authenticate") {
    Ok(np) -> should.equal(symbols.name_path_parts(np), ["User", "authenticate"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_three_segments_test() {
  case symbols.parse_name_path("module/Class/method") {
    Ok(np) ->
      should.equal(symbols.name_path_parts(np), ["module", "Class", "method"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_strips_leading_slash_test() {
  case symbols.parse_name_path("/User/authenticate") {
    Ok(np) -> should.equal(symbols.name_path_parts(np), ["User", "authenticate"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_strips_trailing_slash_test() {
  case symbols.parse_name_path("User/authenticate/") {
    Ok(np) -> should.equal(symbols.name_path_parts(np), ["User", "authenticate"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_collapses_double_slash_test() {
  // "//User//foo" → ["User", "foo"]; empty segments dropped.
  case symbols.parse_name_path("//User//foo") {
    Ok(np) -> should.equal(symbols.name_path_parts(np), ["User", "foo"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_trims_whitespace_test() {
  case symbols.parse_name_path("  User / authenticate  ") {
    Ok(np) -> should.equal(symbols.name_path_parts(np), ["User", "authenticate"])
    Error(_) -> should.fail()
  }
}

pub fn parse_name_path_empty_rejected_test() {
  case symbols.parse_name_path("") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

pub fn parse_name_path_whitespace_only_rejected_test() {
  case symbols.parse_name_path("   ") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

pub fn parse_name_path_only_slashes_rejected_test() {
  case symbols.parse_name_path("///") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

pub fn name_path_to_string_round_trip_test() {
  let raw = "User/authenticate"
  case symbols.parse_name_path(raw) {
    Ok(np) -> should.equal(symbols.name_path_to_string(np), raw)
    Error(_) -> should.fail()
  }
}

// -- edit_mode_from_string ----------------------------------------------

pub fn edit_mode_replace_body_test() {
  case symbols.edit_mode_from_string("replace_body") {
    Ok(ReplaceBody) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn edit_mode_insert_before_test() {
  case symbols.edit_mode_from_string("insert_before") {
    Ok(InsertBefore) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn edit_mode_insert_after_test() {
  case symbols.edit_mode_from_string("insert_after") {
    Ok(InsertAfter) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn edit_mode_camelcase_accepted_test() {
  case symbols.edit_mode_from_string("ReplaceBody") {
    Ok(ReplaceBody) -> should.equal(1, 1)
    _ -> should.fail()
  }
}

pub fn edit_mode_unknown_rejected_test() {
  case symbols.edit_mode_from_string("nuke_file") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

// -- Resolution JSON projection -----------------------------------------

pub fn resolution_single_json_includes_status_test() {
  let m =
    symbols.SymbolMatch(
      name: "authenticate",
      kind: 6,
      uri: "file:///tmp/u.py",
      range: symbols.Range(
        start: symbols.Position(line: 10, character: 4),
        end: symbols.Position(line: 17, character: 5),
      ),
      selection_range: symbols.Range(
        start: symbols.Position(line: 10, character: 8),
        end: symbols.Position(line: 10, character: 20),
      ),
      full_path: ["User", "authenticate"],
      detail: Some("(self, password)"),
    )
  // Wrap into Single and convert.
  let json_text =
    symbols.resolution_to_json(Single(m)) |> json.to_string
  should.equal(string.contains(json_text, "\"status\":\"single\""), True)
  should.equal(string.contains(json_text, "\"name\":\"authenticate\""), True)
  // The handle the LLM will pass back for edit_at_symbol must be
  // present in the response.
  should.equal(string.contains(json_text, "\"handle\""), True)
  should.equal(string.contains(json_text, "\"selection_line\":10"), True)
}

pub fn resolution_multiple_json_includes_count_test() {
  let m1 = sym_match("authenticate", 6, 10, ["User", "authenticate"])
  let m2 = sym_match("authenticate", 12, 40, ["Helper", "authenticate"])
  let json_text =
    symbols.resolution_to_json(Multiple([m1, m2])) |> json.to_string
  should.equal(string.contains(json_text, "\"status\":\"multiple\""), True)
  should.equal(string.contains(json_text, "\"count\":2"), True)
}

pub fn resolution_not_found_json_includes_near_misses_test() {
  let json_text =
    symbols.resolution_to_json(NotFound(near_misses: ["authentik", "auth"]))
    |> json.to_string
  should.equal(string.contains(json_text, "\"status\":\"not_found\""), True)
  should.equal(string.contains(json_text, "\"authentik\""), True)
}

// -- SymbolHandle round-trip --------------------------------------------

pub fn symbol_handle_round_trip_through_json_test() {
  let original =
    symbols.SymbolHandle(
      uri: "file:///tmp/x.py",
      name: "authenticate",
      selection_line: 42,
      selection_character: 8,
      kind: 6,
    )
  let json_text =
    symbols.symbol_handle_to_json(original) |> json.to_string
  // Decode back via the public decoder. Mirrors what the MCP layer
  // does when an LLM passes a handle to edit_at_symbol.
  let dyn = json_to_dynamic(json_text)
  case decode.run(dyn, symbols.symbol_handle_decoder()) {
    Ok(parsed) -> should.equal(parsed, original)
    Error(_) -> should.fail()
  }
}

// -- Helpers -------------------------------------------------------------

fn sym_match(
  name: String,
  kind: Int,
  line: Int,
  full_path: List(String),
) -> symbols.SymbolMatch {
  symbols.SymbolMatch(
    name: name,
    kind: kind,
    uri: "file:///tmp/dummy",
    range: symbols.Range(
      start: symbols.Position(line: line, character: 0),
      end: symbols.Position(line: line + 5, character: 0),
    ),
    selection_range: symbols.Range(
      start: symbols.Position(line: line, character: 4),
      end: symbols.Position(line: line, character: 4 + string.length(name)),
    ),
    full_path: full_path,
    detail: None,
  )
}

// Parse a JSON string back to a Dynamic by routing through Erlang's
// `json:decode/1` (OTP 27+). Mirrors what the MCP transport hands us
// when an LLM submits a tool call: the argument blob arrives as an
// already-decoded map/list term, so we re-decode the rendered JSON
// here to exercise the public decoder against that exact shape.
@external(erlang, "json", "decode")
fn json_to_dynamic(s: String) -> a
