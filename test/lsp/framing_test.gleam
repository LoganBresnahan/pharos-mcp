//// Tests for `llm_lsp_mcp/lsp/framing` — the Content-Length parser.
////
//// The parser is the most error-prone module in the codebase. Bytes
//// arrive in arbitrary chunks from the LSP's stdout; the parser has
//// to handle partial headers, partial bodies, multiple coalesced
//// messages, and malformed input gracefully. Coverage layers:
////
////   1. Encode/parse roundtrip for one message — sanity.
////   2. Multi-message coalesced parsing.
////   3. Partial-read scenarios (header partial, body partial,
////      complete+partial mix).
////   4. Malformed-input error paths.
////   5. Property: encode then parse arbitrary strings, must yield
////      the original.
////   6. Property: feed an encoded stream byte-by-byte, must recover
////      the original messages in order.

import gleam/bit_array
import gleam/list
import gleam/string
import gleeunit/should
import llm_lsp_mcp/lsp/framing
import qcheck

// -- Roundtrip basics ----------------------------------------------------

pub fn encode_then_parse_yields_original_body_test() {
  let body = bit_array.from_string("{\"jsonrpc\":\"2.0\",\"method\":\"x\"}")
  let frame = framing.encode(body)

  let assert Ok(framing.Parsed(messages: [parsed], buffer: leftover)) =
    framing.parse(frame)

  should.equal(parsed, body)
  should.equal(bit_array.byte_size(leftover), 0)
}

pub fn encode_includes_correct_header_test() {
  let body = bit_array.from_string("hi")
  let frame = framing.encode(body)
  let assert Ok(text) = bit_array.to_string(frame)
  text |> should.equal("Content-Length: 2\r\n\r\nhi")
}

// -- Multi-message coalesced parsing -------------------------------------

pub fn parse_two_concatenated_frames_test() {
  let a = bit_array.from_string("{\"id\":1}")
  let b = bit_array.from_string("{\"id\":2}")
  let buffer = bit_array.concat([framing.encode(a), framing.encode(b)])

  let assert Ok(framing.Parsed(messages: messages, buffer: leftover)) =
    framing.parse(buffer)

  should.equal(messages, [a, b])
  should.equal(bit_array.byte_size(leftover), 0)
}

// -- Partial reads -------------------------------------------------------

pub fn partial_header_returns_no_messages_and_keeps_buffer_test() {
  let buffer = bit_array.from_string("Content-Length: 9\r\n")

  let assert Ok(framing.Parsed(messages: messages, buffer: leftover)) =
    framing.parse(buffer)

  should.equal(messages, [])
  should.equal(leftover, buffer)
}

pub fn partial_body_returns_no_messages_and_keeps_buffer_test() {
  let buffer = bit_array.from_string("Content-Length: 10\r\n\r\n{\"id\":1")

  let assert Ok(framing.Parsed(messages: messages, buffer: leftover)) =
    framing.parse(buffer)

  should.equal(messages, [])
  should.equal(leftover, buffer)
}

pub fn complete_followed_by_partial_yields_complete_keeps_partial_test() {
  let a = bit_array.from_string("{\"id\":1}")
  let partial =
    bit_array.from_string("Content-Length: 100\r\n\r\nincomplete-body")
  let buffer = bit_array.concat([framing.encode(a), partial])

  let assert Ok(framing.Parsed(messages: messages, buffer: leftover)) =
    framing.parse(buffer)

  should.equal(messages, [a])
  should.equal(leftover, partial)
}

// -- Optional headers between Content-Length and body --------------------

pub fn extra_headers_are_ignored_test() {
  let body = bit_array.from_string("{\"id\":42}")
  let body_size = bit_array.byte_size(body)
  let header =
    bit_array.from_string(
      "Content-Length: "
      <> int_to_string(body_size)
      <> "\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n",
    )
  let buffer = bit_array.concat([header, body])

  let assert Ok(framing.Parsed(messages: [parsed], ..)) = framing.parse(buffer)
  should.equal(parsed, body)
}

// -- Malformed input -----------------------------------------------------

pub fn missing_content_length_header_errors_test() {
  let buffer =
    bit_array.from_string("Content-Type: text/plain\r\n\r\nbody")

  case framing.parse(buffer) {
    Error(framing.MissingContentLength) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }
}

pub fn non_integer_content_length_errors_test() {
  let buffer = bit_array.from_string("Content-Length: not-a-number\r\n\r\nbody")

  case framing.parse(buffer) {
    Error(framing.InvalidContentLength(_)) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }
}

pub fn negative_content_length_errors_test() {
  let buffer = bit_array.from_string("Content-Length: -5\r\n\r\nbody")

  case framing.parse(buffer) {
    Error(framing.InvalidContentLength(_)) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }
}

// -- Property: encode/parse roundtrip ------------------------------------

pub fn property_encode_parse_roundtrip_test() {
  use payload <- qcheck.given(qcheck.string())

  let body = bit_array.from_string(payload)
  let frame = framing.encode(body)

  let assert Ok(framing.Parsed(messages: [parsed], buffer: leftover)) =
    framing.parse(frame)

  should.equal(parsed, body)
  should.equal(bit_array.byte_size(leftover), 0)
}

// -- Property: chunked feed recovers all messages -----------------------

pub fn property_chunked_parse_recovers_messages_test() {
  use payloads <- qcheck.given(qcheck.list_from(qcheck.string()))

  let bodies = list.map(payloads, bit_array.from_string)
  let stream = bit_array.concat(list.map(bodies, framing.encode))

  let recovered = feed_byte_by_byte(stream)
  should.equal(recovered, bodies)
}

// Feed a stream one byte at a time through the parser, accumulating the
// messages it produces. Simulates the worst-case chunking the LSP I/O
// layer would ever hand us.
fn feed_byte_by_byte(stream: BitArray) -> List(BitArray) {
  let total = bit_array.byte_size(stream)
  do_feed(stream, 0, total, bit_array.from_string(""), [])
}

fn do_feed(
  stream: BitArray,
  position: Int,
  total: Int,
  buffer: BitArray,
  acc: List(BitArray),
) -> List(BitArray) {
  case position >= total {
    True -> list.reverse(acc)
    False -> {
      let assert Ok(byte) = bit_array.slice(stream, position, 1)
      let buffer = bit_array.concat([buffer, byte])
      let assert Ok(framing.Parsed(messages: messages, buffer: buffer)) =
        framing.parse(buffer)
      do_feed(
        stream,
        position + 1,
        total,
        buffer,
        list.append(list.reverse(messages), acc),
      )
    }
  }
}

// Local helper because gleam/int.to_string is already imported in
// framing but we want to avoid pulling it in here for one usage.
fn int_to_string(n: Int) -> String {
  n
  |> int_to_chars
  |> string.from_utf_codepoints
}

@external(erlang, "erlang", "integer_to_list")
fn int_to_chars(n: Int) -> List(UtfCodepoint)
