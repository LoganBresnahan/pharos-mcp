import gleeunit/should
import pharos/tools/tool_helpers

/// #37: one message for every method a server doesn't advertise.
pub fn unsupported_names_server_method_and_capability_test() {
  tool_helpers.describe_unsupported(
    "gleam",
    "textDocument/implementation",
    "implementationProvider",
  )
  |> should.equal(
    "this language server (gleam) doesn't support textDocument/implementation: "
    <> "it doesn't advertise implementationProvider, so pharos didn't send the request",
  )
}

pub fn unsupported_without_a_server_id_test() {
  tool_helpers.describe_unsupported("", "textDocument/hover", "hoverProvider")
  |> should.equal(
    "this language server doesn't support textDocument/hover: "
    <> "it doesn't advertise hoverProvider, so pharos didn't send the request",
  )
}
