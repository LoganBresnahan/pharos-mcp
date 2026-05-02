//// Tests for the milestone-1 stdio MCP server.
////
//// Scope: dispatch behavior of `llm_lsp_mcp/mcp/server.handle_line`,
//// since it is pure and easy to assert on. The actual stdin reader
//// is exercised by the smoke-test pipeline documented in the README.

import gleam/string
import gleeunit/should
import llm_lsp_mcp/mcp/server

fn contains(haystack: String, needle: String) -> Nil {
  string.contains(haystack, needle) |> should.be_true
}

// -- initialize ----------------------------------------------------------

pub fn initialize_returns_reply_with_matching_id_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
    <> "\"params\":{\"protocolVersion\":\"2024-11-05\","
    <> "\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"

  case server.handle_line(line) {
    server.Reply(json) -> {
      contains(json, "\"id\":1")
      contains(json, "\"protocolVersion\":\"2024-11-05\"")
      contains(json, "\"serverInfo\"")
    }
    _ -> should.fail()
  }
}

pub fn initialize_with_string_id_echoes_id_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\",\"params\":{}}"

  case server.handle_line(line) {
    server.Reply(json) -> contains(json, "\"id\":\"abc\"")
    _ -> should.fail()
  }
}

// -- notifications produce no reply --------------------------------------

pub fn initialized_notification_has_no_reply_test() {
  server.handle_line("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}")
  |> should.equal(server.NoReply)
}

pub fn cancelled_notification_has_no_reply_test() {
  server.handle_line(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\","
    <> "\"params\":{\"requestId\":1}}",
  )
  |> should.equal(server.NoReply)
}

// -- tools/list ----------------------------------------------------------

pub fn tools_list_includes_echo_tool_test() {
  case
    server.handle_line(
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
    )
  {
    server.Reply(json) -> {
      contains(json, "\"name\":\"echo\"")
      contains(json, "\"inputSchema\"")
    }
    _ -> should.fail()
  }
}

// -- tools/call ----------------------------------------------------------

pub fn tools_call_echo_returns_message_as_content_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"hi\"}}}"

  case server.handle_line(line) {
    server.Reply(json) -> {
      contains(json, "\"text\":\"hi\"")
      contains(json, "\"isError\":false")
    }
    _ -> should.fail()
  }
}

pub fn tools_call_unknown_tool_returns_invalid_params_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"nope\",\"arguments\":{}}}"

  case server.handle_line(line) {
    server.Reply(json) -> {
      contains(json, "\"code\":-32602")
      contains(json, "Unknown tool: nope")
    }
    _ -> should.fail()
  }
}

pub fn tools_call_echo_missing_message_argument_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"echo\",\"arguments\":{}}}"

  case server.handle_line(line) {
    server.Reply(json) -> contains(json, "\"code\":-32602")
    _ -> should.fail()
  }
}

// -- error responses -----------------------------------------------------

pub fn parse_error_returns_negative_32700_test() {
  case server.handle_line("not valid json") {
    server.ProtocolError(json) -> {
      contains(json, "\"code\":-32700")
      contains(json, "Parse error")
    }
    _ -> should.fail()
  }
}

pub fn unknown_method_returns_negative_32601_test() {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"some/missing\"}"

  case server.handle_line(line) {
    server.Reply(json) -> {
      contains(json, "\"code\":-32601")
      contains(json, "Method not found")
    }
    _ -> should.fail()
  }
}
