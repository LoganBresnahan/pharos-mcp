//// ADR-039: tsserver's diagnostics, mapped to LSP the way
//// typescript-language-server publishes them.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import pharos/lsp/languages
import pharos/lsp/tsserver_diagnostics

fn response(text: String) -> decode.Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn mapped(text: String, ignored: List(Int)) -> String {
  let assert Ok(found) =
    tsserver_diagnostics.diagnostics_from_response(response(text), ignored)
  json.to_string(json.preprocessed_array(found))
}

pub fn positions_go_from_one_based_to_zero_based_test() {
  mapped(
    "{\"type\":\"response\",\"success\":true,\"body\":[{\"start\":{\"line\":2,\"offset\":10},\"end\":{\"line\":2,\"offset\":22},\"text\":\"Type 'string' is not assignable to type 'number'.\",\"code\":2322,\"category\":\"error\"}]}",
    [],
  )
  |> should.equal(
    "[{\"range\":{\"start\":{\"line\":1,\"character\":9},\"end\":{\"line\":1,\"character\":21}},\"message\":\"Type 'string' is not assignable to type 'number'.\",\"severity\":1,\"code\":2322,\"source\":\"typescript\"}]",
  )
}

pub fn categories_map_to_severities_test() {
  mapped(
    "{\"success\":true,\"body\":["
      <> "{\"start\":{\"line\":1,\"offset\":1},\"end\":{\"line\":1,\"offset\":2},\"text\":\"w\",\"code\":1,\"category\":\"warning\"},"
      <> "{\"start\":{\"line\":1,\"offset\":1},\"end\":{\"line\":1,\"offset\":2},\"text\":\"s\",\"code\":2,\"category\":\"suggestion\"},"
      <> "{\"start\":{\"line\":1,\"offset\":1},\"end\":{\"line\":1,\"offset\":2},\"text\":\"m\",\"code\":3,\"category\":\"message\"}]}",
    [],
  )
  |> should.equal(
    "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"w\",\"severity\":2,\"code\":1,\"source\":\"typescript\"},"
    <> "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"s\",\"severity\":4,\"code\":2,\"source\":\"typescript\"},"
    <> "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"m\",\"severity\":1,\"code\":3,\"source\":\"typescript\"}]",
  )
}

/// A plugin's own source is kept; related information becomes an LSP
/// location, and an item without a span is dropped, as
/// typescript-language-server drops it.
pub fn source_and_related_information_test() {
  mapped(
    "{\"success\":true,\"body\":[{\"start\":{\"line\":1,\"offset\":1},\"end\":{\"line\":1,\"offset\":4},\"text\":\"t\",\"code\":99001,\"category\":\"error\",\"source\":\"probe-plugin\",\"relatedInformation\":[{\"span\":{\"start\":{\"line\":3,\"offset\":5},\"end\":{\"line\":3,\"offset\":9},\"file\":\"/w/b.ts\"},\"message\":\"declared here\"},{\"message\":\"no span\"}]}]}",
    [],
  )
  |> should.equal(
    "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"message\":\"t\",\"severity\":1,\"code\":99001,\"source\":\"probe-plugin\",\"relatedInformation\":[{\"location\":{\"uri\":\"file:///w/b.ts\",\"range\":{\"start\":{\"line\":2,\"character\":4},\"end\":{\"line\":2,\"character\":8}}},\"message\":\"declared here\"}]}]",
  )
}

pub fn ignored_codes_are_dropped_test() {
  mapped(
    "{\"success\":true,\"body\":[{\"start\":{\"line\":1,\"offset\":1},\"end\":{\"line\":1,\"offset\":2},\"text\":\"a\",\"code\":6133,\"category\":\"suggestion\"},{\"start\":{\"line\":1,\"offset\":1},\"end\":{\"line\":1,\"offset\":2},\"text\":\"b\",\"code\":2322,\"category\":\"error\"}]}",
    [6133],
  )
  |> should.equal(
    "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"message\":\"b\",\"severity\":1,\"code\":2322,\"source\":\"typescript\"}]",
  )
}

pub fn an_empty_body_is_no_diagnostics_test() {
  mapped("{\"type\":\"response\",\"success\":true,\"body\":[]}", [])
  |> should.equal("[]")
}

pub fn a_failed_request_is_an_error_test() {
  tsserver_diagnostics.diagnostics_from_response(
    response(
      "{\"type\":\"response\",\"success\":false,\"message\":\"Could not find file\"}",
    ),
    [],
  )
  |> should.equal(Error("Could not find file"))
}

pub fn ignored_codes_come_from_the_workspace_configuration_test() {
  let assert Ok(ts) = dict.get(languages.default_registry(), "typescript")
  let assert [server, ..] = ts.servers
  tsserver_diagnostics.ignored_codes(server) |> should.equal([])
  let configured =
    languages.ServerConfig(
      ..server,
      workspace_configuration: Some(
        dict.from_list([
          #(
            "diagnostics",
            json.object([
              #("ignoredCodes", json.preprocessed_array([json.int(6133)])),
            ]),
          ),
        ]),
      ),
    )
  tsserver_diagnostics.ignored_codes(configured) |> should.equal([6133])
  tsserver_diagnostics.ignored_codes(
    languages.ServerConfig(..server, workspace_configuration: None),
  )
  |> should.equal([])
}

pub fn the_bundled_typescript_server_asks_tsserver_test() {
  let assert Ok(ts) = dict.get(languages.default_registry(), "typescript")
  let assert [server, ..] = ts.servers
  server.diagnostics_mode |> should.equal(languages.Tsserver)
}

pub fn execute_params_name_the_command_and_file_test() {
  tsserver_diagnostics.execute_params(
    "semanticDiagnosticsSync",
    "file:///w/a.ts",
  )
  |> json.to_string
  |> should.equal(
    "{\"command\":\"typescript.tsserverRequest\",\"arguments\":[\"semanticDiagnosticsSync\",{\"file\":\"file:///w/a.ts\"}]}",
  )
}

pub fn project_params_ask_for_project_info_test() {
  tsserver_diagnostics.project_params("file:///w/a.ts")
  |> json.to_string
  |> should.equal(
    "{\"command\":\"typescript.tsserverRequest\",\"arguments\":[\"projectInfo\",{\"file\":\"file:///w/a.ts\",\"needFileNameList\":false}]}",
  )
}

pub fn project_from_response_names_the_tsconfig_test() {
  tsserver_diagnostics.project_from_response(response(
    "{\"type\":\"response\",\"success\":true,\"body\":{\"configFileName\":\"/w/tsconfig.json\",\"languageServiceDisabled\":false}}",
  ))
  |> should.equal(Ok("/w/tsconfig.json"))
  tsserver_diagnostics.project_from_response(response(
    "{\"success\":true,\"body\":{\"configFileName\":\"/dev/null/inferredProject1*\"}}",
  ))
  |> should.equal(Ok("/dev/null/inferredProject1*"))
}

pub fn project_from_response_without_a_project_is_an_error_test() {
  tsserver_diagnostics.project_from_response(response(
    "{\"success\":false,\"message\":\"No Project.\"}",
  ))
  |> should.be_error
  tsserver_diagnostics.project_from_response(response("{\"success\":true}"))
  |> should.be_error
}
