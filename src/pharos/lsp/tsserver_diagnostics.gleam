//// Diagnostics asked of tsserver directly (ADR-039).
////
//// typescript-language-server publishes diagnostics without a
//// `version`, from tsserver's asynchronous re-check of every open
//// file, so a publish can describe the text before a change (ADR-038,
//// F4). Its `typescript.tsserverRequest` command forwards a raw
//// tsserver request instead. tsserver handles requests in order, so a
//// `*DiagnosticsSync` request sent after a change answers for the new
//// text. This module builds those requests and maps tsserver's answers
//// to LSP diagnostics the way typescript-language-server publishes
//// them. Pure: the caller sends the requests.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import pharos/lsp/languages.{type ServerConfig}
import pharos/workspace_root

/// The command typescript-language-server forwards to tsserver.
pub const command: String = "typescript.tsserverRequest"

/// The tsserver requests, in the order typescript-language-server
/// merges the kinds it publishes: syntax, semantic, suggestion.
pub const requests: List(String) = [
  "syntacticDiagnosticsSync", "semanticDiagnosticsSync",
  "suggestionDiagnosticsSync",
]

/// `workspace/executeCommand` params for one tsserver request about
/// `file_uri`. typescript-language-server maps the URI of an open
/// document to its path.
pub fn execute_params(request: String, file_uri: String) -> Json {
  json.object([
    #("command", json.string(command)),
    #(
      "arguments",
      json.preprocessed_array([
        json.string(request),
        json.object([#("file", json.string(file_uri))]),
      ]),
    ),
  ])
}

/// One tsserver diagnostic, as `formatDiag` returns it.
type TsDiagnostic {
  TsDiagnostic(
    start: Location,
    end: Location,
    text: String,
    code: Option(Int),
    category: String,
    source: Option(String),
    related: Option(List(Related)),
  )
}

type Location {
  Location(line: Int, offset: Int)
}

type Related {
  Related(span: Option(Span), message: String)
}

type Span {
  Span(start: Location, end: Location, file: String)
}

/// The LSP diagnostics in one tsserver response, minus `ignored`
/// codes. A response with `success: false` is an error, with tsserver's
/// message.
pub fn diagnostics_from_response(
  result: Dynamic,
  ignored: List(Int),
) -> Result(List(Json), String) {
  case decode.run(result, response_decoder()) {
    Error(errors) ->
      Error(case errors {
        [first, ..] -> "tsserver response: expected " <> first.expected
        [] -> "tsserver response did not decode"
      })
    Ok(Error(message)) -> Error(message)
    Ok(Ok(diagnostics)) ->
      Ok(
        diagnostics
        |> list.filter(fn(d) {
          case d.code {
            Some(code) -> !list.contains(ignored, code)
            None -> True
          }
        })
        |> list.map(to_lsp),
      )
  }
}

/// `diagnostics.ignoredCodes` from the server's workspace
/// configuration: typescript-language-server drops these from its
/// publishes, and tsserver's answers aren't filtered by it.
pub fn ignored_codes(server: ServerConfig) -> List(Int) {
  case server.workspace_configuration {
    None -> []
    Some(sections) ->
      case dict.get(sections, "diagnostics") {
        Error(Nil) -> []
        Ok(section) ->
          case
            json.parse(
              json.to_string(section),
              decode.optional_field(
                "ignoredCodes",
                [],
                decode.list(decode.int),
                decode.success,
              ),
            )
          {
            Ok(codes) -> codes
            Error(_) -> []
          }
      }
  }
}

fn response_decoder() -> decode.Decoder(Result(List(TsDiagnostic), String)) {
  use success <- decode.optional_field("success", True, decode.bool)
  case success {
    False -> {
      use message <- decode.optional_field(
        "message",
        "tsserver request failed",
        decode.string,
      )
      decode.success(Error(message))
    }
    True -> {
      use body <- decode.optional_field(
        "body",
        [],
        decode.list(diagnostic_decoder()),
      )
      decode.success(Ok(body))
    }
  }
}

fn location_decoder() -> decode.Decoder(Location) {
  use line <- decode.field("line", decode.int)
  use offset <- decode.field("offset", decode.int)
  decode.success(Location(line:, offset:))
}

fn diagnostic_decoder() -> decode.Decoder(TsDiagnostic) {
  use start <- decode.field("start", location_decoder())
  use end <- decode.field("end", location_decoder())
  use text <- decode.field("text", decode.string)
  use code <- decode.optional_field("code", None, decode.optional(decode.int))
  use category <- decode.optional_field("category", "error", decode.string)
  use source <- decode.optional_field(
    "source",
    None,
    decode.optional(decode.string),
  )
  use related <- decode.optional_field(
    "relatedInformation",
    None,
    decode.optional(decode.list(related_decoder())),
  )
  decode.success(TsDiagnostic(
    start:,
    end:,
    text:,
    code:,
    category:,
    source:,
    related:,
  ))
}

fn related_decoder() -> decode.Decoder(Related) {
  use span <- decode.optional_field(
    "span",
    None,
    decode.optional({
      use start <- decode.field("start", location_decoder())
      use end <- decode.field("end", location_decoder())
      use file <- decode.field("file", decode.string)
      decode.success(Span(start:, end:, file:))
    }),
  )
  use message <- decode.optional_field("message", "", decode.string)
  decode.success(Related(span:, message:))
}

/// typescript-language-server's `toDiagnostic`. Tags are left out:
/// pharos doesn't advertise `publishDiagnostics.tagSupport`, so its
/// publishes carry none either.
fn to_lsp(d: TsDiagnostic) -> Json {
  let fields = [
    #("range", range(d.start, d.end)),
    #("message", json.string(d.text)),
    #("severity", json.int(severity(d.category))),
  ]
  let fields = case d.code {
    Some(code) -> list.append(fields, [#("code", json.int(code))])
    None -> fields
  }
  let fields =
    list.append(fields, [
      #("source", json.string(option.unwrap(d.source, "typescript"))),
    ])
  let fields = case d.related {
    None -> fields
    Some(items) ->
      list.append(fields, [
        #(
          "relatedInformation",
          json.preprocessed_array(
            list.filter_map(items, fn(item) {
              case item.span {
                None -> Error(Nil)
                Some(span) ->
                  Ok(
                    json.object([
                      #(
                        "location",
                        json.object([
                          #(
                            "uri",
                            json.string(workspace_root.path_to_uri(span.file)),
                          ),
                          #("range", range(span.start, span.end)),
                        ]),
                      ),
                      #("message", json.string(item.message)),
                    ]),
                  )
              }
            }),
          ),
        ),
      ])
  }
  json.object(fields)
}

/// tsserver's line and offset are 1-based; LSP's are 0-based.
fn range(start: Location, end: Location) -> Json {
  json.object([#("start", position(start)), #("end", position(end))])
}

fn position(loc: Location) -> Json {
  json.object([
    #("line", json.int(loc.line - 1)),
    #("character", json.int(loc.offset - 1)),
  ])
}

/// error 1, warning 2, suggestion 4 (Hint); anything else is an error.
fn severity(category: String) -> Int {
  case category {
    "warning" -> 2
    "suggestion" -> 4
    _ -> 1
  }
}
