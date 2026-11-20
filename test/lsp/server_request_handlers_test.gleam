//// #49: server→client requests pharos must answer rather than refuse.

import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import pharos/lsp/server_request_handlers.{LspIdInt, Reply}

pub fn refresh_requests_are_acknowledged_test() {
  let registry = server_request_handlers.defaults()
  list.each(
    [
      "workspace/diagnostic/refresh",
      "workspace/semanticTokens/refresh",
      "workspace/inlayHint/refresh",
      "workspace/codeLens/refresh",
      "workspace/inlineValue/refresh",
      "workspace/foldingRange/refresh",
    ],
    fn(method) {
      let assert Some(handler) =
        server_request_handlers.lookup(registry, method)
      handler(LspIdInt(1), dynamic.nil())
      |> should.equal(Reply(json.null()))
    },
  )
}
