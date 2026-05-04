//// MCP protocol dispatch.
////
//// Pure-function dispatch for the milestone-1 echo server. Takes a
//// raw NDJSON line, decodes it, dispatches by method, returns the
//// JSON string to write back to stdout (or `Nil` for notifications,
//// which produce no response).
////
//// Tool registry is hardcoded inline — only `echo` exists. Real tool
//// dispatch with a registry abstraction lands in Milestone 4.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import pharos/log
import pharos/lsp/pool.{type Pool}
import pharos/mcp/content_block
import pharos/tools/tier1/diagnostics
import pharos/tools/tier1/document_symbols
import pharos/tools/tier1/find_references
import pharos/tools/tier1/goto_definition
import pharos/tools/tier1/hover
import pharos/tools/tier1/workspace_symbols

const protocol_version: String = "2024-11-05"

const server_name: String = "pharos"

const server_version: String = "0.0.1"

/// JSON-RPC request id — string or integer per spec.
pub type Id {
  IntId(Int)
  StringId(String)
}

/// Outcome of dispatching one inbound NDJSON line.
pub type DispatchResult {
  /// Send this JSON string back as a response on stdout.
  Reply(json: String)
  /// No reply — the inbound message was a notification.
  NoReply
  /// Inbound message was malformed; reply with a JSON-RPC error.
  ProtocolError(json: String)
}

/// Top-level entry: parse one inbound line and dispatch.
pub fn handle_line(pool: Pool, line: String) -> DispatchResult {
  case json.parse(line, message_decoder()) {
    Ok(message) -> dispatch(pool, message)
    Error(_) -> ProtocolError(error_response(None, -32_700, "Parse error"))
  }
}

// -- Inbound message classification --------------------------------------

type Message {
  RequestMessage(id: Id, method: String, params: Option(Dynamic))
  NotificationMessage(method: String, params: Option(Dynamic))
}

fn message_decoder() -> decode.Decoder(Message) {
  use method <- decode.field("method", decode.string)
  use maybe_id <- decode.optional_field("id", None, decode.optional(id_decoder()))
  use maybe_params <- decode.optional_field("params", None, decode.optional(decode.dynamic))
  case maybe_id {
    Some(id) -> decode.success(RequestMessage(id, method, maybe_params))
    None -> decode.success(NotificationMessage(method, maybe_params))
  }
}

fn id_decoder() -> decode.Decoder(Id) {
  decode.one_of(decode.int |> decode.map(IntId), [
    decode.string |> decode.map(StringId),
  ])
}

// -- Dispatch ------------------------------------------------------------

fn dispatch(pool: Pool, message: Message) -> DispatchResult {
  case message {
    RequestMessage(id, "initialize", _params) -> Reply(initialize_response(id))
    RequestMessage(id, "tools/list", _params) -> Reply(tools_list_response(id))
    RequestMessage(id, "tools/call", params) ->
      Reply(handle_tool_call(pool, id, params))
    RequestMessage(id, method, _) ->
      Reply(error_response(
        Some(id),
        -32_601,
        "Method not found: " <> method,
      ))

    NotificationMessage("initialized", _) -> NoReply
    NotificationMessage("notifications/cancelled", _) -> NoReply
    NotificationMessage(_, _) -> NoReply
  }
}

// -- initialize ----------------------------------------------------------

fn initialize_response(id: Id) -> String {
  success_response(id, fn() {
    json.object([
      #("protocolVersion", json.string(protocol_version)),
      #("capabilities", server_capabilities()),
      #(
        "serverInfo",
        json.object([
          #("name", json.string(server_name)),
          #("version", json.string(server_version)),
        ]),
      ),
    ])
  })
}

fn server_capabilities() -> Json {
  json.object([
    #("tools", json.object([#("listChanged", json.bool(False))])),
  ])
}

// -- tools/list ----------------------------------------------------------

fn tools_list_response(id: Id) -> String {
  success_response(id, fn() {
    json.object([
      #(
        "tools",
        json.array(
          [
            echo_tool_definition(),
            get_diagnostics_tool_definition(),
            hover_tool_definition(),
            goto_definition_tool_definition(),
            find_references_tool_definition(),
            document_symbols_tool_definition(),
            workspace_symbols_tool_definition(),
          ],
          of: fn(t) { t },
        ),
      ),
    ])
  })
}

fn position_arg_schema() -> Json {
  json.object([
    #(
      "properties",
      json.object([
        #(
          "uri",
          json.object([
            #("type", json.string("string")),
            #(
              "description",
              json.string(
                "file:// URI of the source file. Example: "
                  <> "file:///home/user/project/src/main.rs",
              ),
            ),
          ]),
        ),
        #(
          "line",
          json.object([
            #("type", json.string("integer")),
            #(
              "description",
              json.string(
                "Zero-based line number, per LSP spec. Editor "
                  <> "convention shows it as 1-based; subtract 1 for "
                  <> "this field.",
              ),
            ),
          ]),
        ),
        #(
          "character",
          json.object([
            #("type", json.string("integer")),
            #(
              "description",
              json.string(
                "Zero-based UTF-16 code-unit offset within the line, "
                  <> "per LSP spec.",
              ),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "required",
      json.array(["uri", "line", "character"], of: json.string),
    ),
    #("type", json.string("object")),
  ])
}

fn hover_tool_definition() -> Json {
  json.object([
    #("name", json.string("hover")),
    #(
      "description",
      json.string(
        "Get the type signature, documentation, and other "
          <> "language-server hover info for the symbol at a position "
          <> "in a source file. Wraps LSP `textDocument/hover`. "
          <> "Returns the verbatim LSP `Hover` result as JSON: "
          <> "`{contents: ..., range?: ...}`. `contents` may be "
          <> "MarkupContent, plain string, or a list of MarkedString — "
          <> "the LLM reads whichever shape the server sends.",
      ),
    ),
    #("inputSchema", position_arg_schema()),
  ])
}

fn goto_definition_tool_definition() -> Json {
  json.object([
    #("name", json.string("goto_definition")),
    #(
      "description",
      json.string(
        "Find where the symbol at a position is defined. Wraps "
          <> "LSP `textDocument/definition`. Returns the verbatim LSP "
          <> "result: a single Location, a list of Location, a list of "
          <> "LocationLink (3.14+), or null if no definition. Each "
          <> "Location has `uri` plus `range` (zero-based positions).",
      ),
    ),
    #("inputSchema", position_arg_schema()),
  ])
}

fn find_references_tool_definition() -> Json {
  json.object([
    #("name", json.string("find_references")),
    #(
      "description",
      json.string(
        "Find all usages of the symbol at a position across the "
          <> "workspace. Wraps LSP `textDocument/references`. Returns "
          <> "the verbatim list of LSP Locations (zero-based "
          <> "positions). Set `include_declaration` (default true) to "
          <> "include or exclude the symbol's definition site from the "
          <> "result.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "uri",
              json.object([#("type", json.string("string"))]),
            ),
            #(
              "line",
              json.object([#("type", json.string("integer"))]),
            ),
            #(
              "character",
              json.object([#("type", json.string("integer"))]),
            ),
            #(
              "include_declaration",
              json.object([
                #("type", json.string("boolean")),
                #(
                  "description",
                  json.string(
                    "Whether to include the definition site in the "
                      <> "results. Defaults to true.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.array(["uri", "line", "character"], of: json.string),
        ),
      ]),
    ),
  ])
}

fn document_symbols_tool_definition() -> Json {
  json.object([
    #("name", json.string("document_symbols")),
    #(
      "description",
      json.string(
        "Return the outline of a source file — functions, "
          <> "types, modules, etc. — with their positions. Wraps LSP "
          <> "`textDocument/documentSymbol`. Returns the verbatim LSP "
          <> "result: either a hierarchical `DocumentSymbol[]` (each "
          <> "with `children`) or a flat deprecated "
          <> "`SymbolInformation[]`, depending on what rust-analyzer "
          <> "emits.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "uri",
              json.object([#("type", json.string("string"))]),
            ),
          ]),
        ),
        #("required", json.array(["uri"], of: json.string)),
      ]),
    ),
  ])
}

fn workspace_symbols_tool_definition() -> Json {
  json.object([
    #("name", json.string("workspace_symbols")),
    #(
      "description",
      json.string(
        "Search across the workspace for symbols whose name "
          <> "matches a query. Wraps LSP `workspace/symbol`. Returns "
          <> "the verbatim list of `SymbolInformation` or "
          <> "`WorkspaceSymbol` (LSP 3.17+). Caller must pass any "
          <> "file:// URI inside the workspace as `workspace_uri_hint` "
          <> "so the bridge knows which LSP to query.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "workspace_uri_hint",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "file:// URI of any file inside the workspace, or "
                      <> "the workspace root itself.",
                  ),
                ),
              ]),
            ),
            #(
              "query",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Substring to match against symbol names. Empty "
                      <> "string returns all symbols (potentially many).",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.array(["workspace_uri_hint", "query"], of: json.string),
        ),
      ]),
    ),
  ])
}

fn get_diagnostics_tool_definition() -> Json {
  json.object([
    #("name", json.string("get_diagnostics")),
    #(
      "description",
      json.string(
        "Return LSP diagnostics (errors and warnings) for a source file. "
          <> "Picks the language by file extension and spawns the matching "
          <> "LSP (rust-analyzer for .rs, gopls for .go, "
          <> "typescript-language-server for .ts/.tsx/.js/.jsx, pyright for "
          <> ".py). Returns the verbatim textDocument/publishDiagnostics body "
          <> "the server emits. Cold start is ~5-15 seconds for the LSP to "
          <> "index the project. Some servers (notably "
          <> "typescript-language-server) emit diagnostics via pull-mode only "
          <> "and may return NoDiagnosticsObserved here; pull-mode support "
          <> "lands in a later milestone.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "uri",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "file:// URI of the source file to inspect. "
                      <> "Example: file:///home/user/project/src/main.rs",
                  ),
                ),
              ]),
            ),
            #(
              "timeout_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Optional. How long to wait for diagnostics after the "
                      <> "LSP initialize handshake. Defaults to 8000ms.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["uri"], of: json.string)),
      ]),
    ),
  ])
}

fn echo_tool_definition() -> Json {
  json.object([
    #("name", json.string("echo")),
    #(
      "description",
      json.string(
        "Echo the supplied message back as a text content block. "
          <> "Smoke-test tool used to verify MCP plumbing.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "message",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("The message to echo back verbatim."),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["message"], of: json.string)),
      ]),
    ),
  ])
}

// -- tools/call ----------------------------------------------------------

fn handle_tool_call(pool: Pool, id: Id, params: Option(Dynamic)) -> String {
  case decode_tool_call(params) {
    Ok(#("echo", arguments)) ->
      case decode_echo_arguments(arguments) {
        Ok(message) ->
          success_response(id, fn() { tool_text_result(message, False) })
        Error(reason) ->
          error_response(
            Some(id),
            -32_602,
            "Invalid params for echo: " <> reason,
          )
      }

    Ok(#("get_diagnostics", arguments)) ->
      handle_get_diagnostics(pool, id, arguments)

    Ok(#("hover", arguments)) -> handle_hover(pool, id, arguments)

    Ok(#("goto_definition", arguments)) ->
      handle_goto_definition(pool, id, arguments)

    Ok(#("find_references", arguments)) ->
      handle_find_references(pool, id, arguments)

    Ok(#("document_symbols", arguments)) ->
      handle_document_symbols(pool, id, arguments)

    Ok(#("workspace_symbols", arguments)) ->
      handle_workspace_symbols(pool, id, arguments)

    Ok(#(name, _)) ->
      error_response(Some(id), -32_602, "Unknown tool: " <> name)

    Error(reason) ->
      error_response(Some(id), -32_602, "Invalid tools/call params: " <> reason)
  }
}

fn handle_get_diagnostics(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_get_diagnostics_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid params for get_diagnostics: " <> reason,
      )

    Ok(#(uri, timeout_ms)) ->
      case diagnostics.handle(pool, uri, timeout_ms) {
        Ok(diagnostics.Diagnostics(uri: _, body_json: body)) ->
          success_response(id, fn() { tool_text_result(body, False) })

        Ok(diagnostics.NoDiagnosticsObserved(uri: u)) ->
          success_response(
            id,
            fn() {
              tool_text_result(
                "No textDocument/publishDiagnostics notification was received "
                  <> "for "
                  <> u
                  <> " within the timeout. The LSP may still be indexing, "
                  <> "or the file may have no diagnostics.",
                False,
              )
            },
          )

        Error(err) ->
          success_response(
            id,
            fn() { tool_text_result(describe_diagnostics_error(err), True) },
          )
      }
  }
}

fn decode_get_diagnostics_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use timeout_ms <- decode.optional_field(
      "timeout_ms",
      8000,
      decode.int,
    )
    decode.success(#(uri, timeout_ms))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `uri: string` (and optional `timeout_ms: int`)" })
}

// -- Tier-1 LSP-backed tool handlers ------------------------------------

fn handle_hover(pool: Pool, id: Id, arguments: Option(Dynamic)) -> String {
  case decode_position_arguments(arguments) {
    Error(reason) ->
      error_response(Some(id), -32_602, "Invalid hover params: " <> reason)
    Ok(#(uri, line, character)) ->
      case hover.handle(pool, uri, line, character) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(hover.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(hover.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_goto_definition(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_position_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid goto_definition params: " <> reason,
      )
    Ok(#(uri, line, character)) ->
      case goto_definition.handle(pool, uri, line, character) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(goto_definition.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(goto_definition.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_find_references(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_find_references_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid find_references params: " <> reason,
      )
    Ok(#(uri, line, character, include_decl)) ->
      case find_references.handle(pool, uri, line, character, include_decl) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(find_references.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(find_references.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_document_symbols(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_uri_only_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid document_symbols params: " <> reason,
      )
    Ok(uri) ->
      case document_symbols.handle(pool, uri) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(document_symbols.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(document_symbols.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_workspace_symbols(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_workspace_symbols_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid workspace_symbols params: " <> reason,
      )
    Ok(#(workspace_uri_hint, query)) ->
      case workspace_symbols.handle(pool, workspace_uri_hint, query) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(workspace_symbols.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(workspace_symbols.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

// -- Argument decoders --------------------------------------------------

fn decode_position_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use line <- decode.field("line", decode.int)
    use character <- decode.field("character", decode.int)
    decode.success(#(uri, line, character))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `line: int`, `character: int`"
  })
}

fn decode_find_references_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Bool), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use line <- decode.field("line", decode.int)
    use character <- decode.field("character", decode.int)
    use include_decl <- decode.optional_field(
      "include_declaration",
      True,
      decode.bool,
    )
    decode.success(#(uri, line, character, include_decl))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `line: int`, `character: int`, "
    <> "optional `include_declaration: bool`"
  })
}

fn decode_uri_only_arguments(
  args: Option(Dynamic),
) -> Result(String, String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    decode.success(uri)
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `uri: string`" })
}

fn decode_workspace_symbols_arguments(
  args: Option(Dynamic),
) -> Result(#(String, String), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use hint <- decode.field("workspace_uri_hint", decode.string)
    use query <- decode.field("query", decode.string)
    decode.success(#(hint, query))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `workspace_uri_hint: string`, `query: string`"
  })
}

fn describe_diagnostics_error(err: diagnostics.DiagnosticsError) -> String {
  case err {
    diagnostics.NotAFileUri(uri) -> "uri must start with file:// — got: " <> uri
    diagnostics.WorkspaceNotFound(uri) ->
      "no workspace root marker found ascending from " <> uri
    diagnostics.SpawnFailed(reason) ->
      "rust-analyzer failed to spawn: " <> reason
    diagnostics.HandshakeFailed(reason) ->
      "LSP initialize handshake failed: " <> reason
    diagnostics.TransportFailed(reason) ->
      "LSP transport error: " <> reason
    diagnostics.UnsupportedFileType(uri) ->
      "v0.1 only supports .rs files; got: " <> uri
  }
}

fn decode_tool_call(
  params: Option(Dynamic),
) -> Result(#(String, Option(Dynamic)), String) {
  use raw <- result.try(option.to_result(params, "missing params"))
  let decoder = {
    use name <- decode.field("name", decode.string)
    use args <- decode.optional_field(
      "arguments",
      None,
      decode.optional(decode.dynamic),
    )
    decode.success(#(name, args))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "params shape did not match tools/call schema" })
}

fn decode_echo_arguments(args: Option(Dynamic)) -> Result(String, String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use message <- decode.field("message", decode.string)
    decode.success(message)
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `message: string` in arguments" })
}

fn tool_text_result(message: String, is_error: Bool) -> Json {
  // Log every tool error to stderr so dogfood post-mortem can see
  // what went wrong without waiting for the LLM to surface the
  // content block. Stdout stays reserved for JSON-RPC frames.
  case is_error {
    True -> log.warn("tool error returned to client: " <> message)
    False -> Nil
  }

  let block = content_block.to_json(content_block.text(message))
  json.object([
    #("content", json.array([block], of: fn(b) { b })),
    #("isError", json.bool(is_error)),
  ])
}

// -- response building ---------------------------------------------------

fn success_response(id: Id, build_result: fn() -> Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_to_json(id)),
    #("result", build_result()),
  ])
  |> json.to_string
}

fn error_response(id: Option(Id), code: Int, message: String) -> String {
  let id_value = case id {
    Some(value) -> id_to_json(value)
    None -> json.null()
  }
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_value),
    #(
      "error",
      json.object([
        #("code", json.int(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json.to_string
}

fn id_to_json(id: Id) -> Json {
  case id {
    IntId(n) -> json.int(n)
    StringId(s) -> json.string(s)
  }
}

