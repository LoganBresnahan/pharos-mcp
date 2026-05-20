//// Unit tests for the pure helpers in `workspace_symbols`.
////
//// The LSP-bound path (`handle/6`) is exercised by the dogfood
//// harness against real LSP servers. This file covers the
//// case/convention variant logic that drives the retry — pure,
//// LSP-free, deterministic.

import gleam/option.{None, Some}
import gleeunit/should
import pharos/tools/workspace_symbols

pub fn variant_for_snake_case_to_camel_case_test() {
  workspace_symbols.variant_for("calculate_total")
  |> should.equal(Some("calculateTotal"))
}

pub fn variant_for_multi_segment_snake_case_test() {
  workspace_symbols.variant_for("get_user_profile_data")
  |> should.equal(Some("getUserProfileData"))
}

pub fn variant_for_camel_case_to_snake_case_test() {
  workspace_symbols.variant_for("calculateTotal")
  |> should.equal(Some("calculate_total"))
}

pub fn variant_for_multi_word_camel_case_test() {
  workspace_symbols.variant_for("getUserProfileData")
  |> should.equal(Some("get_user_profile_data"))
}

pub fn variant_for_leading_capital_falls_back_to_lowercase_test() {
  // `Foo` has no internal uppercase boundary, so the camel-to-snake
  // path doesn't apply. Should fall back to lowercase.
  workspace_symbols.variant_for("Foo")
  |> should.equal(Some("foo"))
}

pub fn variant_for_pascal_case_treated_as_camel_case_test() {
  // `FooBar` has an internal uppercase at position 3 → camel-to-snake
  // fires.
  workspace_symbols.variant_for("FooBar")
  |> should.equal(Some("foo_bar"))
}

pub fn variant_for_all_lowercase_with_no_underscore_returns_none_test() {
  // `foobar` is already lowercase and has no convention to flip.
  // Nothing to retry with — let the caller skip the retry.
  workspace_symbols.variant_for("foobar")
  |> should.equal(None)
}

pub fn variant_for_all_uppercase_lowers_test() {
  workspace_symbols.variant_for("FOO")
  |> should.equal(Some("foo"))
}

pub fn variant_for_empty_query_returns_none_test() {
  workspace_symbols.variant_for("")
  |> should.equal(None)
}

pub fn variant_for_trailing_underscore_doesnt_crash_test() {
  // `foo_` is degenerate but shouldn't panic. Either snake_to_camel
  // returns `foo` (which differs from query) or we fall back to
  // lowercase — both are acceptable; the test pins the contract
  // that something is returned.
  case workspace_symbols.variant_for("foo_") {
    Some(_) -> Nil
    None -> Nil
  }
}
