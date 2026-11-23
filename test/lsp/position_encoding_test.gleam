//// #47: converting positions for servers that don't count UTF-16.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option
import gleeunit/should
import pharos/lsp/position_encoding.{FromServer, ToServer, Utf16, Utf32, Utf8}

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn write_text(path: String, text: String) -> Result(Nil, String)

fn term(text: String) {
  let assert Ok(t) = json.parse(text, decode.dynamic)
  t
}

fn char_at(t, path: List(String)) -> Int {
  let assert Ok(c) = decode.run(t, decode.at(path, decode.int))
  c
}

// `s = "é😀"; target`: target is at UTF-16 11, UTF-8 14, code points 10.
const line = "s = \"é😀\"; target = 1"

pub fn columns_convert_both_ways_test() {
  let path = "/tmp/pharos-position-encoding-test.txt"
  let assert Ok(Nil) = write_text(path, "first\n" <> line <> "\n")
  let uri = "file://" <> path
  let pos = fn(c) {
    term("{\"position\":{\"line\":1,\"character\":" <> int_text(c) <> "}}")
  }
  position_encoding.translate(pos(11), uri, ToServer, Utf8)
  |> char_at(["position", "character"])
  |> should.equal(14)
  position_encoding.translate(pos(11), uri, ToServer, Utf32)
  |> char_at(["position", "character"])
  |> should.equal(10)
  position_encoding.translate(pos(14), uri, FromServer, Utf8)
  |> char_at(["position", "character"])
  |> should.equal(11)
  position_encoding.translate(pos(10), uri, FromServer, Utf32)
  |> char_at(["position", "character"])
  |> should.equal(11)
  // UTF-16 is left alone.
  position_encoding.translate(pos(11), uri, ToServer, Utf16)
  |> char_at(["position", "character"])
  |> should.equal(11)
}

pub fn a_location_uses_its_own_document_test() {
  let path = "/tmp/pharos-position-encoding-test2.txt"
  let assert Ok(Nil) = write_text(path, "first\n" <> line <> "\n")
  let loc =
    term(
      "[{\"uri\":\"file://"
      <> path
      <> "\",\"range\":{\"start\":{\"line\":1,\"character\":14},\"end\":{\"line\":1,\"character\":20}}}]",
    )
  let back =
    position_encoding.translate(loc, "file:///elsewhere", FromServer, Utf8)
  let assert Ok([start]) =
    decode.run(
      back,
      decode.list(decode.at(["range", "start", "character"], decode.int)),
    )
  start |> should.equal(11)
}

pub fn positions_past_the_text_pass_through_test() {
  let path = "/tmp/pharos-position-encoding-test3.txt"
  let assert Ok(Nil) = write_text(path, "ab\n")
  let uri = "file://" <> path
  // Past the line's end, on a line the file doesn't have, in a missing file.
  position_encoding.translate(
    term("{\"position\":{\"line\":0,\"character\":40}}"),
    uri,
    ToServer,
    Utf8,
  )
  |> char_at(["position", "character"])
  |> should.equal(40)
  position_encoding.translate(
    term("{\"position\":{\"line\":9,\"character\":3}}"),
    uri,
    ToServer,
    Utf8,
  )
  |> char_at(["position", "character"])
  |> should.equal(3)
  position_encoding.translate(
    term("{\"position\":{\"line\":0,\"character\":3}}"),
    "file:///no/such/file",
    ToServer,
    Utf8,
  )
  |> char_at(["position", "character"])
  |> should.equal(3)
}

pub fn settings_pick_the_encodings_test() {
  position_encoding.of_settings(option_some("utf-8"), option_none())
  |> should.equal(#(Utf8, Utf8))
  position_encoding.of_settings(option_none(), option_some("utf-32"))
  |> should.equal(#(Utf16, Utf32))
  position_encoding.of_settings(option_some("utf-8"), option_some("utf-32"))
  |> should.equal(#(Utf8, Utf32))
}

fn int_text(i: Int) -> String {
  int.to_string(i)
}

fn option_some(s: String) -> option.Option(String) {
  option.Some(s)
}

fn option_none() -> option.Option(String) {
  option.None
}
