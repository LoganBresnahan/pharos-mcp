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
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pharos/log
import pharos/lsp/inflight
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc
import pharos/mcp/content_block
import pharos/tools/tier1/diagnostics
import pharos/tools/tier1/document_symbols
import pharos/tools/tier1/find_references
import pharos/tools/tier1/goto_definition
import pharos/tools/tier1/hover
import pharos/tools/tier1/workspace_symbols
import pharos/tools/tier2/call_hierarchy
import pharos/tools/tier2/code_actions
import pharos/tools/tier2/format_document
import pharos/tools/tier2/goto_implementation
import pharos/tools/tier2/goto_type_definition
import pharos/tools/tier2/lsp_request_raw
import pharos/tools/registry as tool_registry
import pharos/tools/tier4
import pharos/tools/tier2/rename_preview
import pharos/tools/tier2/signature_help

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
    RequestMessage(id, method, params) -> {
      log.set_correlation_id(id_to_text(id))
      log.debug_at("pharos/mcp/server", "dispatch " <> method)
      let result = case method {
        "initialize" -> Reply(initialize_response(id))
        "tools/list" -> Reply(tools_list_response(id))
        "tools/call" -> Reply(handle_tool_call(pool, id, params))
        other ->
          Reply(error_response(
            Some(id),
            -32_601,
            "Method not found: " <> other,
          ))
      }
      log.clear_correlation_id()
      result
    }

    NotificationMessage("initialized", _) -> NoReply
    NotificationMessage("notifications/cancelled", params) -> {
      log_cancel_notification(params)
      NoReply
    }
    NotificationMessage(_, _) -> NoReply
  }
}

fn id_to_text(id: Id) -> String {
  case id {
    IntId(n) -> int.to_string(n)
    StringId(s) -> s
  }
}

/// Handle MCP `notifications/cancelled` (ADR-016). Look up the
/// cancelled MCP id in the inflight table; on hit, send
/// `$/cancelRequest` via the matched proc actor for the matched
/// LSP id. On miss, the request has already completed (stdio's
/// blocking dispatcher) or never tracked; logged either way.
fn log_cancel_notification(params: Option(Dynamic)) -> Nil {
  let id_text = case params {
    None -> "<no params>"
    Some(raw) ->
      case decode.run(raw, cancel_id_decoder()) {
        Ok(text) -> text
        Error(_) -> "<unparseable>"
      }
  }
  case id_text {
    "<no params>" | "<unparseable>" ->
      log.warn_at(
        "pharos/mcp/server",
        "notifications/cancelled with malformed/missing requestId",
      )
    cid ->
      case inflight.lookup(cid) {
        Error(_) ->
          log.info_at(
            "pharos/mcp/server",
            "notifications/cancelled id=" <> cid
              <> " (no in-flight match; request already completed or untracked)",
          )
        Ok(#(proc_subject_dynamic, lsp_id)) -> {
          log.info_at(
            "pharos/mcp/server",
            "notifications/cancelled id=" <> cid
              <> " → forwarding $/cancelRequest for lsp_id=" <> int.to_string(lsp_id),
          )
          proc.cancel_by_dynamic_subject(proc_subject_dynamic, lsp_id)
          Nil
        }
      }
  }
}

fn cancel_id_decoder() -> decode.Decoder(String) {
  let int_request = {
    use n <- decode.field("requestId", decode.int)
    decode.success(int.to_string(n))
  }
  let string_request = {
    use s <- decode.field("requestId", decode.string)
    decode.success(s)
  }
  let int_id = {
    use n <- decode.field("id", decode.int)
    decode.success(int.to_string(n))
  }
  let string_id = {
    use s <- decode.field("id", decode.string)
    decode.success(s)
  }
  decode.one_of(int_request, [string_request, int_id, string_id])
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
      #("tools", json.array(allowed_tool_definitions(), of: fn(t) { t })),
    ])
  })
}

/// Build the filtered list of tool definitions: every `(name,
/// builder)` whose `name` is allowed by the cached tool filter
/// (`pharos/config.tools`) becomes its instantiated JSON; the rest
/// drop out before `tools/list` ever sees them.
fn allowed_tool_definitions() -> List(Json) {
  let tier1_2 = [
    #("echo", echo_tool_definition),
    #("get_diagnostics", get_diagnostics_tool_definition),
    #("hover", hover_tool_definition),
    #("goto_definition", goto_definition_tool_definition),
    #("find_references", find_references_tool_definition),
    #("document_symbols", document_symbols_tool_definition),
    #("workspace_symbols", workspace_symbols_tool_definition),
    #("goto_type_definition", goto_type_definition_tool_definition),
    #("goto_implementation", goto_implementation_tool_definition),
    #("signature_help", signature_help_tool_definition),
    #("call_hierarchy_prepare", call_hierarchy_prepare_tool_definition),
    #(
      "call_hierarchy_incoming_calls",
      call_hierarchy_incoming_calls_tool_definition,
    ),
    #(
      "call_hierarchy_outgoing_calls",
      call_hierarchy_outgoing_calls_tool_definition,
    ),
    #("rename_preview", rename_preview_tool_definition),
    #("format_document", format_document_tool_definition),
    #("code_actions", code_actions_tool_definition),
    #("lsp_request_raw", lsp_request_raw_tool_definition),
  ]
  list.append(tier1_2, tier4.named_definitions())
  |> list.filter_map(fn(pair) {
    let #(name, builder) = pair
    case tool_registry.is_allowed(name) {
      True -> Ok(builder())
      False -> Error(Nil)
    }
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
          <> "the LLM reads whichever shape the server sends. "
          <> "Cold-start note: a freshly-spawned rust-analyzer may "
          <> "return `null` for the first 5-15s while it indexes the "
          <> "workspace; retry once after a 1-2s pause if you "
          <> "expected a hit at a known symbol position.",
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
          <> "Location has `uri` plus `range` (zero-based positions). "
          <> "Cold-start note: a freshly-spawned rust-analyzer may "
          <> "return `null` for the first 5-15s while it indexes the "
          <> "workspace; retry once after a 1-2s pause if you "
          <> "expected a hit at a known symbol position.",
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
          <> "result. Default per-call timeout is 60s; raise via "
          <> "`timeout_ms` when scanning a workspace-wide type whose "
          <> "rust-analyzer reference walk exceeds the default.",
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
            #(
              "timeout_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Per-call timeout in milliseconds. Default 60000.",
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
          <> "up to `limit` `SymbolInformation` / `WorkspaceSymbol` "
          <> "entries; default 20, raise via `limit` if a query is "
          <> "expected to return more. Excess results trim with a "
          <> "trailing truncation annotation. gopls in particular "
          <> "fuzzy-matches across the Go stdlib and can flood the "
          <> "result for short queries — the cap protects the MCP "
          <> "host's per-tool token budget. "
          <> "`workspace_uri_hint` may be a file URI inside the "
          <> "workspace OR the workspace root directory itself "
          <> "(e.g. `file:///proj/`); when a directory is given pass "
          <> "`language` to pick the LSP since extension routing has "
          <> "no extension to read.",
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
                      <> "of the workspace root directory itself.",
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
            #(
              "limit",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Max symbols to return. Default 20.",
                  ),
                ),
              ]),
            ),
            #(
              "language",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Optional language id (e.g. `rust`, `go`, "
                      <> "`typescript`, `python`). Required when "
                      <> "`workspace_uri_hint` is a directory URI. "
                      <> "When omitted, language is inferred from "
                      <> "the URI's file extension.",
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
                      <> "LSP initialize handshake. Defaults to 20000ms — "
                      <> "gopls and rust-analyzer commonly take 10-15s on "
                      <> "cold workspaces before they emit the first "
                      <> "publishDiagnostics.",
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
  case peek_filtered_name(params) {
    Some(blocked) ->
      error_response(
        Some(id),
        -32_601,
        "Tool not enabled: "
          <> blocked
          <> " (filtered by pharos.tools config)",
      )
    None -> dispatch_tool_call(pool, id, params)
  }
}

/// Peek the requested tool name and return `Some(name)` if the
/// tool filter denies it. Returns `None` when the filter allows
/// the tool, when the params do not decode (the inner dispatch
/// will surface the decode error), or when the name is missing.
fn peek_filtered_name(params: Option(Dynamic)) -> Option(String) {
  case decode_tool_call(params) {
    Ok(#(name, _)) ->
      case tool_registry.is_allowed(name) {
        True -> None
        False -> Some(name)
      }
    Error(_) -> None
  }
}

fn dispatch_tool_call(
  pool: Pool,
  id: Id,
  params: Option(Dynamic),
) -> String {
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

    Ok(#("goto_type_definition", arguments)) ->
      handle_goto_type_definition(pool, id, arguments)

    Ok(#("goto_implementation", arguments)) ->
      handle_goto_implementation(pool, id, arguments)

    Ok(#("signature_help", arguments)) ->
      handle_signature_help(pool, id, arguments)

    Ok(#("call_hierarchy_prepare", arguments)) ->
      handle_call_hierarchy_prepare(pool, id, arguments)

    Ok(#("call_hierarchy_incoming_calls", arguments)) ->
      handle_call_hierarchy_calls(
        pool,
        id,
        arguments,
        call_hierarchy.incoming_calls,
        "call_hierarchy_incoming_calls",
      )

    Ok(#("call_hierarchy_outgoing_calls", arguments)) ->
      handle_call_hierarchy_calls(
        pool,
        id,
        arguments,
        call_hierarchy.outgoing_calls,
        "call_hierarchy_outgoing_calls",
      )

    Ok(#("rename_preview", arguments)) ->
      handle_rename_preview(pool, id, arguments)

    Ok(#("format_document", arguments)) ->
      handle_format_document(pool, id, arguments)

    Ok(#("code_actions", arguments)) ->
      handle_code_actions(pool, id, arguments)

    Ok(#("lsp_request_raw", arguments)) ->
      handle_lsp_request_raw(pool, id, arguments)

    Ok(#(name, arguments)) ->
      case tier4.dispatch(pool, name, arguments) {
        Some(Ok(payload)) ->
          success_response(id, fn() { tool_text_result(payload, False) })
        Some(Error(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        None -> error_response(Some(id), -32_602, "Unknown tool: " <> name)
      }

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
      20_000,
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
    Ok(#(uri, line, character, include_decl, timeout_ms)) ->
      case
        find_references.handle(
          pool,
          uri,
          line,
          character,
          include_decl,
          timeout_ms,
        )
      {
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
    Ok(#(workspace_uri_hint, query, limit, language)) ->
      case
        workspace_symbols.handle(
          pool,
          workspace_uri_hint,
          query,
          limit,
          language,
        )
      {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(workspace_symbols.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(workspace_symbols.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

// -- Tier 2 handlers ----------------------------------------------------

fn handle_goto_type_definition(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_position_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid goto_type_definition params: " <> reason,
      )
    Ok(#(uri, line, character)) ->
      case goto_type_definition.handle(pool, uri, line, character) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(goto_type_definition.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(goto_type_definition.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_goto_implementation(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_goto_implementation_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid goto_implementation params: " <> reason,
      )
    Ok(#(uri, line, character, limit)) ->
      case goto_implementation.handle(pool, uri, line, character, limit) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(goto_implementation.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(goto_implementation.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_signature_help(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_position_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid signature_help params: " <> reason,
      )
    Ok(#(uri, line, character)) ->
      case signature_help.handle(pool, uri, line, character) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(signature_help.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(signature_help.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_call_hierarchy_prepare(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_position_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid call_hierarchy_prepare params: " <> reason,
      )
    Ok(#(uri, line, character)) ->
      case call_hierarchy.prepare(pool, uri, line, character) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(call_hierarchy.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(call_hierarchy.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(call_hierarchy.InvalidItem(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_call_hierarchy_calls(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
  call: fn(Pool, Dynamic) -> Result(String, call_hierarchy.CallHierarchyError),
  tool_name: String,
) -> String {
  case decode_call_hierarchy_item_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid " <> tool_name <> " params: " <> reason,
      )
    Ok(item) ->
      case call(pool, item) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(call_hierarchy.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(call_hierarchy.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(call_hierarchy.InvalidItem(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_rename_preview(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_rename_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid rename_preview params: " <> reason,
      )
    Ok(#(uri, line, character, new_name)) ->
      case rename_preview.handle(pool, uri, line, character, new_name) {
        Ok(rendered) ->
          success_response(id, fn() { tool_text_result(rendered, False) })
        Error(rename_preview.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(rename_preview.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(rename_preview.RenderFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_format_document(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_format_document_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid format_document params: " <> reason,
      )
    Ok(#(uri, timeout_ms)) ->
      case format_document.handle(pool, uri, timeout_ms) {
        Ok(rendered) ->
          success_response(id, fn() { tool_text_result(rendered, False) })
        Error(format_document.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(format_document.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(format_document.RenderFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_code_actions(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_code_actions_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid code_actions params: " <> reason,
      )
    Ok(#(uri, sl, sc, el, ec)) ->
      case code_actions.handle(pool, uri, sl, sc, el, ec) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(code_actions.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(code_actions.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_lsp_request_raw(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_lsp_request_raw_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid lsp_request_raw params: " <> reason,
      )
    Ok(#(uri, method, params)) ->
      case lsp_request_raw.handle(pool, uri, method, params) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(lsp_request_raw.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(lsp_request_raw.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

// -- Tier 2 tool definitions --------------------------------------------

fn goto_type_definition_tool_definition() -> Json {
  json.object([
    #("name", json.string("goto_type_definition")),
    #(
      "description",
      json.string(
        "Find the *type* declaration for the symbol at a position. "
          <> "Wraps LSP `textDocument/typeDefinition`. For "
          <> "`let x: Foo = ...`, calling on `x` returns where `Foo` "
          <> "is declared, not where `x` is bound. Same response shape "
          <> "as goto_definition (Location | Location[] | "
          <> "LocationLink[] | null). Cold-start note: a freshly-"
          <> "spawned rust-analyzer may return `null` for the first "
          <> "5-15s while it indexes the workspace; retry once after "
          <> "a 1-2s pause if you expected a hit at a known symbol "
          <> "position.",
      ),
    ),
    #("inputSchema", position_arg_schema()),
  ])
}

fn goto_implementation_tool_definition() -> Json {
  json.object([
    #("name", json.string("goto_implementation")),
    #(
      "description",
      json.string(
        "Find concrete implementation site(s) for the trait/interface "
          <> "method or abstract symbol at a position. Wraps LSP "
          <> "`textDocument/implementation`. Returns up to `limit` "
          <> "Locations / LocationLinks; default 50, raise via the "
          <> "`limit` arg if you need more (results past the cap are "
          <> "trimmed with a trailing `(truncated N more ...)` "
          <> "annotation). Calling on a stdlib trait method like "
          <> "`Default::default` can otherwise return thousands of "
          <> "sites and exceed the MCP host's per-tool token budget.",
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
                  json.string("Zero-based line, per LSP spec."),
                ),
              ]),
            ),
            #(
              "character",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string("Zero-based UTF-16 offset, per LSP spec."),
                ),
              ]),
            ),
            #(
              "limit",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Maximum number of implementation sites to return. "
                    <> "Default 50.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.preprocessed_array([
            json.string("uri"),
            json.string("line"),
            json.string("character"),
          ]),
        ),
      ]),
    ),
  ])
}

fn signature_help_tool_definition() -> Json {
  json.object([
    #("name", json.string("signature_help")),
    #(
      "description",
      json.string(
        "Get the signature(s) and active parameter for a function "
          <> "call at the given position (typically inside the call's "
          <> "parentheses). Wraps LSP `textDocument/signatureHelp`. "
          <> "Returns `{signatures: [...], activeSignature?: int, "
          <> "activeParameter?: int}` or null.",
      ),
    ),
    #("inputSchema", position_arg_schema()),
  ])
}

fn call_hierarchy_prepare_tool_definition() -> Json {
  json.object([
    #("name", json.string("call_hierarchy_prepare")),
    #(
      "description",
      json.string(
        "Prepare a call hierarchy at the given position. Wraps LSP "
          <> "`textDocument/prepareCallHierarchy`. Returns a list of "
          <> "`CallHierarchyItem` identifying the callable. The "
          <> "follow-on `incomingCalls`/`outgoingCalls` requests "
          <> "round-trip a returned item; until pharos exposes a "
          <> "passthrough for those, use the `lsp_request_raw` escape "
          <> "hatch (Stage 1C).",
      ),
    ),
    #("inputSchema", position_arg_schema()),
  ])
}

fn call_hierarchy_incoming_calls_tool_definition() -> Json {
  call_hierarchy_calls_tool_definition(
    "call_hierarchy_incoming_calls",
    "Returns who calls into the supplied `CallHierarchyItem`. Wraps "
      <> "LSP `callHierarchy/incomingCalls`. Pass an item returned by "
      <> "`call_hierarchy_prepare` verbatim.",
  )
}

fn call_hierarchy_outgoing_calls_tool_definition() -> Json {
  call_hierarchy_calls_tool_definition(
    "call_hierarchy_outgoing_calls",
    "Returns who the supplied `CallHierarchyItem` calls. Wraps LSP "
      <> "`callHierarchy/outgoingCalls`. Pass an item returned by "
      <> "`call_hierarchy_prepare` verbatim.",
  )
}

fn call_hierarchy_calls_tool_definition(
  name: String,
  description: String,
) -> Json {
  json.object([
    #("name", json.string(name)),
    #("description", json.string(description)),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "item",
              json.object([
                #(
                  "description",
                  json.string(
                    "A `CallHierarchyItem` previously returned by "
                    <> "`call_hierarchy_prepare`. Round-trip the "
                    <> "object verbatim — pharos does not re-derive "
                    <> "it from positional arguments.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.preprocessed_array([json.string("item")])),
      ]),
    ),
  ])
}

fn rename_preview_tool_definition() -> Json {
  json.object([
    #("name", json.string("rename_preview")),
    #(
      "description",
      json.string(
        "Preview a rename refactor across the workspace. Wraps LSP "
          <> "`textDocument/rename`. Returns a human-readable summary "
          <> "of the proposed `WorkspaceEdit` listing every file and "
          <> "every changed range. Pharos NEVER writes the changes — "
          <> "review the summary, then apply with your own Edit tool "
          <> "(or, future, `apply_workspace_edit`).",
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
                    "file:// URI of the source file containing the "
                    <> "symbol to rename.",
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
                  json.string("Zero-based line, per LSP spec."),
                ),
              ]),
            ),
            #(
              "character",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string("Zero-based UTF-16 offset, per LSP spec."),
                ),
              ]),
            ),
            #(
              "new_name",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("New name to substitute at every site."),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.preprocessed_array([
            json.string("uri"),
            json.string("line"),
            json.string("character"),
            json.string("new_name"),
          ]),
        ),
      ]),
    ),
  ])
}

fn format_document_tool_definition() -> Json {
  json.object([
    #("name", json.string("format_document")),
    #(
      "description",
      json.string(
        "Run the LSP formatter against a single file. Wraps LSP "
          <> "`textDocument/formatting`. Returns a summary of the "
          <> "formatter's proposed edits. Pharos does not write the "
          <> "changes — review and apply with your own Edit tool. "
          <> "Formatting options use LSP defaults (tabSize=4, "
          <> "insertSpaces=true). Default per-call timeout is 30s; "
          <> "rust-analyzer shells out to rustfmt and may exceed the "
          <> "default on cold cache — raise via `timeout_ms`. Pyright "
          <> "(.py) does not implement formatting; it returns "
          <> "`-32601 Unhandled method`. Format Python externally "
          <> "with ruff/black/yapf.",
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
                    "file:// URI of the source file to format.",
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
                    "Per-call timeout in milliseconds. Default 30000.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.preprocessed_array([json.string("uri")])),
      ]),
    ),
  ])
}

fn lsp_request_raw_tool_definition() -> Json {
  json.object([
    #("name", json.string("lsp_request_raw")),
    #(
      "description",
      json.string(
        "Generic escape hatch for LSP methods pharos does not "
          <> "expose as a typed tool. Sends `(method, params)` to the "
          <> "LSP for the file at `uri` (routing by extension); "
          <> "returns the verbatim result as JSON. Use for "
          <> "`callHierarchy/incomingCalls`, `textDocument/inlayHint`, "
          <> "server-specific extensions, or any method that arrives "
          <> "before pharos wraps it. Errors from the LSP surface "
          <> "with the server's code and message.",
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
                    "file:// URI of any file in the workspace. Used "
                    <> "to pick the LSP by extension; the file does "
                    <> "not have to be relevant to the request.",
                  ),
                ),
              ]),
            ),
            #(
              "method",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "LSP method name, e.g. `textDocument/inlayHint`.",
                  ),
                ),
              ]),
            ),
            #(
              "params",
              json.object([
                #(
                  "description",
                  json.string(
                    "Method-specific params object, sent verbatim.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.preprocessed_array([
            json.string("uri"),
            json.string("method"),
            json.string("params"),
          ]),
        ),
      ]),
    ),
  ])
}

fn code_actions_tool_definition() -> Json {
  json.object([
    #("name", json.string("code_actions")),
    #(
      "description",
      json.string(
        "List the LSP code actions (quick fixes, refactors, source "
          <> "actions) available for a range. Wraps LSP "
          <> "`textDocument/codeAction`. Returns the verbatim list of "
          <> "`Command | CodeAction`. Each action's `title` describes "
          <> "what it would do; CodeAction entries may carry an `edit` "
          <> "(WorkspaceEdit) and/or a `command`. Pharos does not "
          <> "execute commands or apply edits automatically.",
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
                  json.string("file:// URI of the source file."),
                ),
              ]),
            ),
            #(
              "start_line",
              json.object([#("type", json.string("integer"))]),
            ),
            #(
              "start_character",
              json.object([#("type", json.string("integer"))]),
            ),
            #(
              "end_line",
              json.object([#("type", json.string("integer"))]),
            ),
            #(
              "end_character",
              json.object([#("type", json.string("integer"))]),
            ),
          ]),
        ),
        #(
          "required",
          json.preprocessed_array([
            json.string("uri"),
            json.string("start_line"),
            json.string("start_character"),
            json.string("end_line"),
            json.string("end_character"),
          ]),
        ),
      ]),
    ),
  ])
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
) -> Result(#(String, Int, Int, Bool, Int), String) {
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
    use timeout_ms <- decode.optional_field(
      "timeout_ms",
      find_references.default_timeout_ms,
      decode.int,
    )
    decode.success(#(uri, line, character, include_decl, timeout_ms))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `line: int`, `character: int`, "
    <> "optional `include_declaration: bool`, "
    <> "optional `timeout_ms: int`"
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

fn decode_rename_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, String), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use line <- decode.field("line", decode.int)
    use character <- decode.field("character", decode.int)
    use new_name <- decode.field("new_name", decode.string)
    decode.success(#(uri, line, character, new_name))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `line: int`, `character: int`, "
    <> "`new_name: string`"
  })
}

fn decode_code_actions_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use sl <- decode.field("start_line", decode.int)
    use sc <- decode.field("start_character", decode.int)
    use el <- decode.field("end_line", decode.int)
    use ec <- decode.field("end_character", decode.int)
    decode.success(#(uri, sl, sc, el, ec))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `start_line/start_character: int`, "
    <> "`end_line/end_character: int`"
  })
}

fn decode_goto_implementation_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use line <- decode.field("line", decode.int)
    use character <- decode.field("character", decode.int)
    use limit <- decode.optional_field(
      "limit",
      goto_implementation.default_limit,
      decode.int,
    )
    decode.success(#(uri, line, character, limit))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `line: int`, `character: int`, "
    <> "optional `limit: int`"
  })
}

fn decode_format_document_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use timeout_ms <- decode.optional_field(
      "timeout_ms",
      format_document.default_timeout_ms,
      decode.int,
    )
    decode.success(#(uri, timeout_ms))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, optional `timeout_ms: int`"
  })
}

fn decode_call_hierarchy_item_arguments(
  args: Option(Dynamic),
) -> Result(Dynamic, String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use item <- decode.field("item", decode.dynamic)
    decode.success(item)
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `item: <CallHierarchyItem>` "
    <> "(round-trip an object returned by call_hierarchy_prepare)"
  })
}

fn decode_lsp_request_raw_arguments(
  args: Option(Dynamic),
) -> Result(#(String, String, Dynamic), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use method <- decode.field("method", decode.string)
    use params <- decode.field("params", decode.dynamic)
    decode.success(#(uri, method, params))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `uri: string`, `method: string`, `params: any`"
  })
}

fn decode_workspace_symbols_arguments(
  args: Option(Dynamic),
) -> Result(#(String, String, Int, Option(String)), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use hint <- decode.field("workspace_uri_hint", decode.string)
    use query <- decode.field("query", decode.string)
    use limit <- decode.optional_field(
      "limit",
      workspace_symbols.default_limit,
      decode.int,
    )
    use language <- decode.optional_field(
      "language",
      None,
      decode.map(decode.string, Some),
    )
    decode.success(#(hint, query, limit, language))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `workspace_uri_hint: string`, `query: string`, "
    <> "optional `limit: int`, optional `language: string`"
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
    True -> log.warn_at("pharos/mcp/server", "tool error returned to client: " <> message)
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

