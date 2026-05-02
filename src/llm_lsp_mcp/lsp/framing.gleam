//// LSP wire framing: Content-Length headers.
////
//// LSP wraps each JSON-RPC message in HTTP-style framing:
////
//// ```
//// Content-Length: <byte_count>\r\n
//// \r\n
//// <body bytes>
//// ```
////
//// Other headers (Content-Type, etc.) may appear between
//// `Content-Length` and the empty line; v0.1 reads `Content-Length`
//// and ignores everything else gracefully.
////
//// The parser is byte-buffer based: caller maintains a `BitArray`
//// buffer, appends each new chunk read from the LSP's stdout, and
//// passes the full buffer to `parse/1`. The function returns every
//// complete message body it could extract plus the bytes left over,
//// which the caller carries forward to the next call. This shape
//// handles partial header reads, partial body reads, and multiple
//// coalesced messages in a single chunk uniformly.

import gleam/bit_array
import gleam/int
import gleam/result
import gleam/string

const header_terminator: String = "\r\n\r\n"

const header_terminator_size: Int = 4

const content_length_prefix: String = "Content-Length:"

pub type Parsed {
  Parsed(messages: List(BitArray), buffer: BitArray)
}

pub type ParseError {
  /// Header block was found but no `Content-Length:` header inside.
  MissingContentLength
  /// Header block contained `Content-Length:` but the value was not
  /// a non-negative integer.
  InvalidContentLength(String)
}

@external(erlang, "llm_lsp_mcp_framing_ffi", "find")
fn find_offset(haystack: BitArray, needle: BitArray) -> Result(Int, Nil)

/// Build a Content-Length-framed bit_array from a message body.
/// `body` is the JSON-RPC payload bytes (UTF-8 encoded JSON).
pub fn encode(body: BitArray) -> BitArray {
  let body_size = bit_array.byte_size(body)
  let header =
    bit_array.from_string(
      "Content-Length: " <> int.to_string(body_size) <> "\r\n\r\n",
    )
  bit_array.concat([header, body])
}

/// Pull every complete frame out of a buffer.
///
/// `buffer` is the accumulated unread bytes from the LSP's stdout.
/// Returns the message bodies extracted (in arrival order) and the
/// leftover bytes, which the caller appends the next read to.
///
/// On a malformed header (missing or non-integer `Content-Length`),
/// returns an error and discards no bytes — the caller can decide
/// whether to fail the LSP connection or attempt recovery.
pub fn parse(buffer: BitArray) -> Result(Parsed, ParseError) {
  do_parse(buffer, [])
}

fn do_parse(
  buffer: BitArray,
  acc: List(BitArray),
) -> Result(Parsed, ParseError) {
  let needle = bit_array.from_string(header_terminator)
  case find_offset(buffer, needle) {
    Error(Nil) ->
      // No complete header yet — keep buffering.
      Ok(Parsed(messages: list_reverse(acc), buffer: buffer))

    Ok(header_end) -> {
      let body_start = header_end + header_terminator_size
      let assert Ok(header_bytes) = bit_array.slice(buffer, 0, header_end)

      use content_length <- result.try(parse_content_length(header_bytes))

      let total_size = body_start + content_length
      let buffer_size = bit_array.byte_size(buffer)

      case buffer_size >= total_size {
        False ->
          // Header parsed but body not fully arrived yet.
          Ok(Parsed(messages: list_reverse(acc), buffer: buffer))

        True -> {
          let assert Ok(body) =
            bit_array.slice(buffer, body_start, content_length)
          let assert Ok(rest) =
            bit_array.slice(buffer, total_size, buffer_size - total_size)
          do_parse(rest, [body, ..acc])
        }
      }
    }
  }
}

fn parse_content_length(header_bytes: BitArray) -> Result(Int, ParseError) {
  case bit_array.to_string(header_bytes) {
    Error(Nil) ->
      Error(InvalidContentLength("header is not valid UTF-8"))

    Ok(header_string) -> {
      let lines = string.split(header_string, on: "\r\n")
      use line <- result.try(find_content_length_line(lines))

      let raw =
        line
        |> string.drop_start(string.length(content_length_prefix))
        |> string.trim

      use value <- result.try(
        int.parse(raw)
        |> result.map_error(fn(_) {
          InvalidContentLength("could not parse \"" <> line <> "\"")
        }),
      )

      case value < 0 {
        True ->
          Error(InvalidContentLength(
            "negative Content-Length: " <> int.to_string(value),
          ))
        False -> Ok(value)
      }
    }
  }
}

fn find_content_length_line(lines: List(String)) -> Result(String, ParseError) {
  case lines {
    [] -> Error(MissingContentLength)
    [line, ..rest] -> {
      let lowered = string.lowercase(line)
      case string.starts_with(lowered, "content-length:") {
        True -> Ok(line)
        False -> find_content_length_line(rest)
      }
    }
  }
}

fn list_reverse(list: List(a)) -> List(a) {
  do_reverse(list, [])
}

fn do_reverse(list: List(a), acc: List(a)) -> List(a) {
  case list {
    [] -> acc
    [head, ..tail] -> do_reverse(tail, [head, ..acc])
  }
}
