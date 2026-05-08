//// Tests for `pharos/tools/session.build_client_capabilities/0`.
////
//// Until M8 Stage 2 pharos sent `{}` as ClientCapabilities at the
//// LSP initialize handshake. rust-analyzer (and likely others)
//// silently degraded for methods the client did not opt into —
//// signature_help, format_document, code_actions all timed out.
////
//// These tests pin the shape of the capabilities payload so a
//// regression that drops one of the must-have keys gets caught at
//// CI time instead of in dogfood.

import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import pharos/tools/session

pub fn capabilities_has_workspace_and_text_document_test() {
  let payload = serialize(session.build_client_capabilities())

  payload |> has_field("workspace") |> should.be_true
  payload |> has_field("textDocument") |> should.be_true
}

pub fn capabilities_workspace_advertises_apply_edit_test() {
  let payload = serialize(session.build_client_capabilities())

  payload
  |> nested_field(["workspace", "applyEdit"])
  |> should.equal(True)
}

pub fn capabilities_workspace_advertises_configuration_pull_test() {
  // Must be true for tsserver's workspace/configuration server-pull
  // to fire — the response handler is in
  // pharos/lsp/server_request_handlers but the server does not ask
  // unless we declare we support it.
  let payload = serialize(session.build_client_capabilities())

  payload
  |> nested_field(["workspace", "configuration"])
  |> should.equal(True)
}

pub fn capabilities_text_document_advertises_signature_help_test() {
  // Stage 2 #1 root cause: rust-analyzer ignores signatureHelp
  // requests when the client did not declare textDocument.signatureHelp.
  let payload = serialize(session.build_client_capabilities())

  payload
  |> has_nested(["textDocument", "signatureHelp"])
  |> should.be_true
}

pub fn capabilities_text_document_advertises_formatting_test() {
  let payload = serialize(session.build_client_capabilities())

  payload
  |> has_nested(["textDocument", "formatting"])
  |> should.be_true
}

pub fn capabilities_text_document_advertises_code_action_test() {
  let payload = serialize(session.build_client_capabilities())

  payload
  |> has_nested(["textDocument", "codeAction"])
  |> should.be_true
}

pub fn capabilities_text_document_advertises_rename_test() {
  let payload = serialize(session.build_client_capabilities())

  payload
  |> has_nested(["textDocument", "rename"])
  |> should.be_true
}

pub fn capabilities_text_document_advertises_call_hierarchy_test() {
  let payload = serialize(session.build_client_capabilities())

  payload
  |> has_nested(["textDocument", "callHierarchy"])
  |> should.be_true
}

// -- Helpers ------------------------------------------------------------

fn serialize(value: json.Json) -> Json {
  let text = json.to_string(value)
  let assert Ok(parsed) = json.parse(text, decode.dynamic)
  Json(parsed)
}

type Json {
  Json(value: decode.Dynamic)
}

fn has_field(json_value: Json, key: String) -> Bool {
  let Json(dyn) = json_value
  case decode.run(dyn, decode.field(key, decode.dynamic, decode.success)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn has_nested(json_value: Json, path: List(String)) -> Bool {
  let Json(dyn) = json_value
  case decode.run(dyn, decode.subfield(path, decode.dynamic, decode.success)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn nested_field(json_value: Json, path: List(String)) -> Bool {
  let Json(dyn) = json_value
  case decode.run(dyn, decode.subfield(path, decode.bool, decode.success)) {
    Ok(b) -> b
    Error(_) -> False
  }
}
