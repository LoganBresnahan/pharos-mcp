//// #47: positions for a server whose columns aren't UTF-16 code units.
////
//// LSP's default is UTF-16, and pharos negotiates nothing else. ruby-lsp
//// 0.26 advertises utf-16 but counts UTF-8 bytes, both ways; next-ls
//// counts code points both ways; terraform-ls reads UTF-16 but returns
//// code points. `position_encoding` and
//// `returned_position_encoding` say what a server really uses; the pool
//// records them per proc at spawn, and `proc.request` and the proc's
//// publish caching convert every position through `translate`, against
//// the line text on disk (the text pharos last synced follows the disk,
//// ADR-038). A file that changed on disk since the server read it can put
//// a converted column off; a position past its line, or on a line the file
//// doesn't have, passes through unchanged. didChange ranges stay UTF-16:
//// ruby-lsp applies those right (verified for #38).

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Encoding {
  Utf16
  Utf8
  Utf32
}

pub type Direction {
  ToServer
  FromServer
}

/// A config value as an encoding; anything else is UTF-16.
pub fn parse(value: Option(String)) -> Encoding {
  case canonical(value) {
    Some("utf-8") -> Utf8
    Some("utf-32") -> Utf32
    _ -> Utf16
  }
}

/// The (sent, returned) encodings for a server's two settings: the
/// returned one wins for returned positions when set.
pub fn of_settings(
  position: Option(String),
  returned: Option(String),
) -> #(Encoding, Encoding) {
  let sent = parse(position)
  let back = case returned {
    Some(_) -> parse(returned)
    None -> sent
  }
  #(sent, back)
}

@external(erlang, "pharos_position_ffi", "init")
pub fn init() -> Nil

@external(erlang, "pharos_position_ffi", "register")
pub fn register(pid: Pid, sent: Encoding, returned: Encoding) -> Nil

@external(erlang, "pharos_position_ffi", "forget")
pub fn forget(pid: Pid) -> Nil

@external(erlang, "pharos_position_ffi", "lookup")
pub fn lookup(pid: Pid) -> #(Encoding, Encoding)

@external(erlang, "pharos_position_ffi", "translate")
fn translate_ffi(
  term: Dynamic,
  default_uri: String,
  direction: Direction,
  encoding: Encoding,
) -> Dynamic

/// `term` with every position converted; `default_uri` is the document a
/// position without a uri of its own belongs to.
pub fn translate(
  term: Dynamic,
  default_uri: String,
  direction: Direction,
  encoding: Encoding,
) -> Dynamic {
  case encoding {
    Utf16 -> term
    _ -> translate_ffi(term, default_uri, direction, encoding)
  }
}

/// Request params, as JSON text, converted to the server's encoding; the
/// document they name, for converting the answer back.
pub fn params_to_server(
  params_text: String,
  encoding: Encoding,
) -> #(String, String) {
  case json.parse(params_text, decode.dynamic) {
    Error(_) -> #(params_text, "")
    Ok(term) -> {
      let uri = case
        decode.run(term, decode.at(["textDocument", "uri"], decode.string))
      {
        Ok(u) -> u
        Error(_) ->
          case decode.run(term, decode.at(["item", "uri"], decode.string)) {
            Ok(u) -> u
            Error(_) -> ""
          }
      }
      case encoding {
        Utf16 -> #(params_text, uri)
        _ -> #(encode(translate(term, uri, ToServer, encoding)), uri)
      }
    }
  }
}

/// A config value as given, if it names an encoding (any case), as
/// pharos spells it; None otherwise, so an invalid value behaves and
/// prints as unset (the config warning already says it's ignored).
pub fn canonical(value: Option(String)) -> Option(String) {
  case value {
    Some(v) ->
      case string.lowercase(v) {
        "utf-8" -> Some("utf-8")
        "utf-16" -> Some("utf-16")
        "utf-32" -> Some("utf-32")
        _ -> None
      }
    None -> None
  }
}

@external(erlang, "pharos_position_ffi", "encode")
fn encode(term: Dynamic) -> String
