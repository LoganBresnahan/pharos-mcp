//// Tests for `pharos/tools/clip` — array result clipping helper
//// used by tools (e.g. goto_implementation) that can return very
//// large LSP responses.

import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import pharos/tools/clip

pub fn clip_smaller_than_limit_keeps_everything_test() {
  let assert Ok(value) = json.parse("[1, 2, 3]", decode.dynamic)
  let result = clip.clip_array(value, 50)

  result.json_text |> should.equal("[1,2,3]")
  result.truncated_by |> should.equal(0)
}

pub fn clip_equal_to_limit_keeps_everything_test() {
  let assert Ok(value) = json.parse("[1, 2, 3]", decode.dynamic)
  let result = clip.clip_array(value, 3)

  result.json_text |> should.equal("[1,2,3]")
  result.truncated_by |> should.equal(0)
}

pub fn clip_larger_than_limit_trims_test() {
  let assert Ok(value) = json.parse("[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]", decode.dynamic)
  let result = clip.clip_array(value, 3)

  result.json_text |> should.equal("[1,2,3]")
  result.truncated_by |> should.equal(7)
}

pub fn clip_objects_in_array_test() {
  let assert Ok(value) = json.parse(
    "[{\"name\":\"a\"}, {\"name\":\"b\"}, {\"name\":\"c\"}]",
    decode.dynamic,
  )
  let result = clip.clip_array(value, 2)

  result.json_text |> should.equal("[{\"name\":\"a\"},{\"name\":\"b\"}]")
  result.truncated_by |> should.equal(1)
}

pub fn clip_non_array_passes_through_test() {
  let assert Ok(value) = json.parse("null", decode.dynamic)
  let result = clip.clip_array(value, 10)

  result.json_text |> should.equal("null")
  result.truncated_by |> should.equal(0)
}

pub fn clip_single_object_passes_through_test() {
  let assert Ok(value) = json.parse("{\"foo\":1}", decode.dynamic)
  let result = clip.clip_array(value, 10)

  result.json_text |> should.equal("{\"foo\":1}")
  result.truncated_by |> should.equal(0)
}

pub fn clip_empty_array_test() {
  let assert Ok(value) = json.parse("[]", decode.dynamic)
  let result = clip.clip_array(value, 10)

  result.json_text |> should.equal("[]")
  result.truncated_by |> should.equal(0)
}
