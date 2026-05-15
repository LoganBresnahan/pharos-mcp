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
import gleam/erlang/process
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pharos/config
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/inflight
import pharos/lsp/languages
import pharos/lsp/pool.{type Pool}
import pharos/lsp/proc
import pharos/lsp/registry
import pharos/tools/session_overrides
import pharos/mcp/content_block
import pharos/mcp/request_workers
import pharos/tools/diagnostics
import pharos/tools/document_symbols
import pharos/tools/find_references
import pharos/tools/goto_definition
import pharos/tools/hover
import pharos/tools/workspace_symbols
import pharos/tools/apply_workspace_edit
import pharos/tools/call_hierarchy
import pharos/tools/code_actions
import pharos/tools/format_document
import pharos/tools/goto_implementation
import pharos/tools/inlay_hints
import pharos/tools/goto_type_definition
import pharos/tools/lsp_request_raw
import pharos/tools/registry as tool_registry
import pharos/tools/debug
import pharos/tools/rename_preview
import pharos/tools/semantic_tokens
import pharos/tools/signature_help
import pharos/tools/symbols
import pharos/tools/type_hierarchy

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
      log.fields_at(
        "pharos/mcp/server",
        log_entry.Debug,
        "dispatch",
        [#("method", method)],
      )
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

/// Handle MCP `notifications/cancelled` (ADR-016 + M10 async
/// dispatch). Cancellation is two-pronged:
///
///   1. **LSP side.** Look up the in-flight LSP request id in the
///      `pharos_inflight` table and emit `$/cancelRequest` to the
///      handling proc. Lets the LSP short-circuit work pharos no
///      longer needs.
///   2. **MCP-worker side (M10).** Look up the dispatcher process
///      pid in `pharos_request_workers` and send it an exit signal
///      so the dispatcher's blocking receive on the LSP response
///      short-circuits even when the LSP itself ignores
///      `$/cancelRequest`. Spec-legal — MCP says the server SHOULD
///      stop processing and SHOULD NOT respond to the cancelled
///      request; killing the worker drops the pending response on
///      the floor.
///
/// Both lookups are independent. A miss on either is normal: stdio
/// before the async refactor never populated the worker table; HTTP
/// transport runs each request on its mist connection process and
/// doesn't go through `pharos_request_workers`. The cancel handler
/// logs each branch's outcome so dogfood can confirm both paths
/// fire.
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
    cid -> {
      // (1) LSP-side cancel.
      case inflight.lookup(cid) {
        Error(_) ->
          log.fields_at(
            "pharos/mcp/server",
            log_entry.Info,
            "notifications/cancelled (no in-flight LSP request; already completed or untracked)",
            [#("id", cid)],
          )
        Ok(#(proc_subject_dynamic, lsp_id)) -> {
          log.fields_at(
            "pharos/mcp/server",
            log_entry.Info,
            "notifications/cancelled → forwarding $/cancelRequest",
            [#("id", cid), #("lsp_id", int.to_string(lsp_id))],
          )
          proc.cancel_by_dynamic_subject(proc_subject_dynamic, lsp_id)
        }
      }

      // (2) MCP-worker-side cancel — kill the stdio dispatcher
      // process so the blocking receive returns immediately.
      case request_workers.lookup(cid) {
        Error(_) -> Nil
        Ok(worker_pid) -> {
          log.fields_at(
            "pharos/mcp/server",
            log_entry.Info,
            "notifications/cancelled → killing dispatcher worker",
            [#("id", cid)],
          )
          process.send_exit(worker_pid)
          // Worker died mid-execution — its `request_workers.delete`
          // cleanup never ran. Do it here so the table doesn't leak.
          request_workers.delete(cid)
        }
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
  let curated = [
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
    #("apply_workspace_edit", apply_workspace_edit_tool_definition),
    #("inlay_hints", inlay_hints_tool_definition),
    #("semantic_tokens", semantic_tokens_tool_definition),
    #("type_hierarchy_prepare", type_hierarchy_prepare_tool_definition),
    #(
      "type_hierarchy_supertypes",
      type_hierarchy_supertypes_tool_definition,
    ),
    #(
      "type_hierarchy_subtypes",
      type_hierarchy_subtypes_tool_definition,
    ),
    #("lsp_request_raw", lsp_request_raw_tool_definition),
    // -- ADR-026 symbol layer --
    #("find_symbol", find_symbol_tool_definition),
    #("get_symbols_overview", get_symbols_overview_tool_definition),
    #(
      "find_referencing_symbols",
      find_referencing_symbols_tool_definition,
    ),
    #("edit_at_symbol", edit_at_symbol_tool_definition),
  ]
  list.append(curated, debug.named_definitions())
  |> list.filter_map(fn(pair) {
    let #(name, builder) = pair
    case tool_registry.is_allowed(name) {
      True -> Ok(builder())
      False -> Error(Nil)
    }
  })
}

/// Schema entry for the optional `timeout_ms` argument shared by
/// every LSP-bound tool. The actual default is resolved through the
/// `[tool_config.<name>]` / `[tool_config.<name>.<lang>]` stack at
/// dispatch time, so the schema description stays generic.
fn timeout_ms_property() -> #(String, Json) {
  #(
    "timeout_ms",
    json.object([
      #("type", json.string("integer")),
      #(
        "description",
        json.string(
          "Optional. How long pharos waits (in ms) for the LSP to "
            <> "respond before failing the call. Falls back to the "
            <> "per-tool default; that default can itself be overridden "
            <> "in `pharos.toml` via "
            <> "`[tool_config.<name>] default_timeout_ms` or per-language "
            <> "via `[tool_config.<name>.<lang>] default_timeout_ms`. "
            <> "Pass a larger value when the LSP is still cold-indexing "
            <> "or the workspace is unusually large.",
        ),
      ),
    ]),
  )
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
        timeout_ms_property(),
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
            timeout_ms_property(),
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
            timeout_ms_property(),
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

    Ok(#("apply_workspace_edit", arguments)) ->
      handle_apply_workspace_edit(id, arguments)

    Ok(#("inlay_hints", arguments)) ->
      handle_inlay_hints(pool, id, arguments)

    Ok(#("semantic_tokens", arguments)) ->
      handle_semantic_tokens(pool, id, arguments)

    Ok(#("type_hierarchy_prepare", arguments)) ->
      handle_type_hierarchy_prepare(pool, id, arguments)

    Ok(#("type_hierarchy_supertypes", arguments)) ->
      handle_type_hierarchy_calls(
        pool,
        id,
        arguments,
        type_hierarchy.supertypes,
        "type_hierarchy_supertypes",
      )

    Ok(#("type_hierarchy_subtypes", arguments)) ->
      handle_type_hierarchy_calls(
        pool,
        id,
        arguments,
        type_hierarchy.subtypes,
        "type_hierarchy_subtypes",
      )

    Ok(#("lsp_request_raw", arguments)) ->
      handle_lsp_request_raw(pool, id, arguments)

    // -- ADR-026 symbol layer --
    Ok(#("find_symbol", arguments)) ->
      handle_find_symbol(pool, id, arguments)
    Ok(#("get_symbols_overview", arguments)) ->
      handle_get_symbols_overview(pool, id, arguments)
    Ok(#("find_referencing_symbols", arguments)) ->
      handle_find_referencing_symbols(pool, id, arguments)
    Ok(#("edit_at_symbol", arguments)) ->
      handle_edit_at_symbol(pool, id, arguments)

    Ok(#(name, arguments)) ->
      case debug.dispatch(pool, name, arguments) {
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
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, timeout_arg)) ->
      Ok(#(
        uri,
        finalize_timeout("get_diagnostics", 20_000, uri, timeout_arg),
      ))
    Error(_) ->
      Error(
        "expected `uri: string` (and optional `timeout_ms: int`)",
      )
  }
}

/// Resolve effective `default_timeout_ms` for a tool, optionally
/// narrowed to a language. Order (later wins):
///   1. compiled-in const (each tool's `default_timeout_ms`)
///   2. `[tool_config.<name>] default_timeout_ms = N`
///   3. `[tool_config.<name>.<lang>] default_timeout_ms = N`
///   4. session override via `runtime_set_tool_timeout`
///   5. user-passed `timeout_ms` arg (handled by the decoder before
///      calling this resolver)
///
/// Decoders that have a URI in scope pass `Some(lang_id)` after
/// classifying the URI via `lang_from_uri`. Decoders without a URI
/// (chained item-shape tools, debug tools) pass `None` and skip the
/// per-lang layer.
fn resolve_tool_timeout(
  name: String,
  lang: Option(String),
  compiled: Int,
) -> Int {
  case session_overrides.get(name, lang) {
    Some(n) -> n
    None ->
      case config.tool_default_timeout_ms(name, lang) {
        Some(n) -> n
        None -> compiled
      }
  }
}

/// Classify a URI to its registered language id by file extension.
/// Returns `None` when the URI doesn't start with `file://` or no
/// bundled language claims the extension. Used by every decoder
/// that wants per-tool × per-lang resolution.
fn lang_from_uri(uri: String) -> Option(String) {
  case languages.for_uri(registry.cached(), uri) {
    Ok(config) -> Some(config.id)
    Error(_) -> None
  }
}

/// Finalize the per-call `timeout_ms` for a URI-bearing tool. If the
/// LLM passed an explicit `timeout_ms`, that wins. Otherwise resolve
/// through the per-tool × per-lang stack using the URI's classified
/// language.
fn finalize_timeout(
  tool_name: String,
  default: Int,
  uri: String,
  user_arg: Option(Int),
) -> Int {
  case user_arg {
    Some(n) -> n
    None -> resolve_tool_timeout(tool_name, lang_from_uri(uri), default)
  }
}

/// Same as `finalize_timeout` but without a URI in scope (chained
/// item-shape tools, debug tools). Skips the per-lang layer.
fn finalize_timeout_no_lang(
  tool_name: String,
  default: Int,
  user_arg: Option(Int),
) -> Int {
  case user_arg {
    Some(n) -> n
    None -> resolve_tool_timeout(tool_name, None, default)
  }
}

// -- Tier-1 LSP-backed tool handlers ------------------------------------

fn handle_hover(pool: Pool, id: Id, arguments: Option(Dynamic)) -> String {
  case
    decode_position_with_timeout(arguments, "hover", hover.default_timeout_ms)
  {
    Error(reason) ->
      error_response(Some(id), -32_602, "Invalid hover params: " <> reason)
    Ok(#(uri, line, character, timeout_ms)) ->
      case hover.handle(pool, uri, line, character, timeout_ms) {
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
  case
    decode_position_with_timeout(
      arguments,
      "goto_definition",
      goto_definition.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid goto_definition params: " <> reason,
      )
    Ok(#(uri, line, character, timeout_ms)) ->
      case goto_definition.handle(pool, uri, line, character, timeout_ms) {
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
  case
    decode_uri_only_with_timeout(
      arguments,
      "document_symbols",
      document_symbols.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid document_symbols params: " <> reason,
      )
    Ok(#(uri, timeout_ms)) ->
      case document_symbols.handle(pool, uri, timeout_ms) {
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
    Ok(#(workspace_uri_hint, query, limit, language, timeout_ms)) ->
      case
        workspace_symbols.handle(
          pool,
          workspace_uri_hint,
          query,
          limit,
          language,
          timeout_ms,
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
  case
    decode_position_with_timeout(
      arguments,
      "goto_type_definition",
      goto_type_definition.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid goto_type_definition params: " <> reason,
      )
    Ok(#(uri, line, character, timeout_ms)) ->
      case
        goto_type_definition.handle(pool, uri, line, character, timeout_ms)
      {
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
    Ok(#(uri, line, character, limit, timeout_ms)) ->
      case
        goto_implementation.handle(
          pool,
          uri,
          line,
          character,
          limit,
          timeout_ms,
        )
      {
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
  case
    decode_position_with_timeout(
      arguments,
      "signature_help",
      signature_help.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid signature_help params: " <> reason,
      )
    Ok(#(uri, line, character, timeout_ms)) ->
      case signature_help.handle(pool, uri, line, character, timeout_ms) {
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
  case
    decode_position_with_timeout(
      arguments,
      "call_hierarchy_prepare",
      call_hierarchy.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid call_hierarchy_prepare params: " <> reason,
      )
    Ok(#(uri, line, character, timeout_ms)) ->
      case call_hierarchy.prepare(pool, uri, line, character, timeout_ms) {
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
  call: fn(Pool, Dynamic, Int) ->
    Result(String, call_hierarchy.CallHierarchyError),
  tool_name: String,
) -> String {
  case
    decode_item_with_timeout(
      arguments,
      tool_name,
      call_hierarchy.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid " <> tool_name <> " params: " <> reason,
      )
    Ok(#(item, timeout_ms)) ->
      case call(pool, item, timeout_ms) {
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
    Ok(#(uri, line, character, new_name, timeout_ms)) ->
      case
        rename_preview.handle(pool, uri, line, character, new_name, timeout_ms)
      {
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
    Ok(#(uri, sl, sc, el, ec, timeout_ms)) ->
      case code_actions.handle(pool, uri, sl, sc, el, ec, timeout_ms) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(code_actions.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(code_actions.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_type_hierarchy_prepare(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case
    decode_position_with_timeout(
      arguments,
      "type_hierarchy_prepare",
      type_hierarchy.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid type_hierarchy_prepare params: " <> reason,
      )
    Ok(#(uri, line, character, timeout_ms)) ->
      case type_hierarchy.prepare(pool, uri, line, character, timeout_ms) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(type_hierarchy.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(type_hierarchy.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(type_hierarchy.InvalidItem(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_type_hierarchy_calls(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
  call: fn(Pool, Dynamic, Int) ->
    Result(String, type_hierarchy.TypeHierarchyError),
  tool_name: String,
) -> String {
  case
    decode_item_with_timeout(
      arguments,
      tool_name,
      type_hierarchy.default_timeout_ms,
    )
  {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid " <> tool_name <> " params: " <> reason,
      )
    Ok(#(item, timeout_ms)) ->
      case call(pool, item, timeout_ms) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(type_hierarchy.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(type_hierarchy.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(type_hierarchy.InvalidItem(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_semantic_tokens(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_semantic_tokens_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid semantic_tokens params: " <> reason,
      )
    Ok(#(uri, sl, sc, el, ec, timeout_ms)) ->
      case semantic_tokens.handle(pool, uri, sl, sc, el, ec, timeout_ms) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(semantic_tokens.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(semantic_tokens.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_inlay_hints(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_inlay_hints_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid inlay_hints params: " <> reason,
      )
    Ok(#(uri, sl, sc, el, ec, timeout_ms)) ->
      case inlay_hints.handle(pool, uri, sl, sc, el, ec, timeout_ms) {
        Ok(json_text) ->
          success_response(id, fn() { tool_text_result(json_text, False) })
        Error(inlay_hints.SessionFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
        Error(inlay_hints.RequestFailed(reason)) ->
          success_response(id, fn() { tool_text_result(reason, True) })
      }
  }
}

fn handle_apply_workspace_edit(
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_apply_workspace_edit_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid apply_workspace_edit params: " <> reason,
      )
    Ok(#(edit, dry_run)) ->
      case apply_workspace_edit.handle(edit, dry_run) {
        Ok(rendered) ->
          success_response(id, fn() { tool_text_result(rendered, False) })
        Error(apply_workspace_edit.DecodeFailed(reason)) ->
          success_response(
            id,
            fn() { tool_text_result("decode failed: " <> reason, True) },
          )
        Error(apply_workspace_edit.InvalidUris(reason)) ->
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
    Ok(#(uri, method, params, timeout_ms)) ->
      case lsp_request_raw.handle(pool, uri, method, params, timeout_ms) {
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
            timeout_ms_property(),
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
                // `type: "object"` is load-bearing here — without it
                // some MCP hosts (Claude Code) JSON-stringify the
                // argument before sending, which breaks the
                // server-side round-trip back to LSP.
                #("type", json.string("object")),
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
            timeout_ms_property(),
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
            timeout_ms_property(),
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

fn type_hierarchy_prepare_tool_definition() -> Json {
  json.object([
    #("name", json.string("type_hierarchy_prepare")),
    #(
      "description",
      json.string(
        "Resolve `TypeHierarchyItem`s for a symbol at a position. "
          <> "Wraps LSP `textDocument/prepareTypeHierarchy`. Returns "
          <> "the verbatim LSP result (`TypeHierarchyItem[]`). Each "
          <> "item carries `name`, `kind`, `uri`, `range`, "
          <> "`selectionRange` plus optional `detail`/`tags`/`data`. "
          <> "Pass an item to `type_hierarchy_supertypes` / "
          <> "`type_hierarchy_subtypes` to walk the type relationship "
          <> "graph. Server support is sparse at the time of writing: "
          <> "rust-analyzer, pyright, gopls, and "
          <> "typescript-language-server all return "
          <> "`-32601 Method not found` for `prepareTypeHierarchy`. "
          <> "Tool plumbing ships ahead of LSP support; check your "
          <> "server's release notes before relying on it.",
      ),
    ),
    #("inputSchema", position_arg_schema()),
  ])
}

fn type_hierarchy_supertypes_tool_definition() -> Json {
  type_hierarchy_calls_tool_definition(
    "type_hierarchy_supertypes",
    "Get supertypes for a `TypeHierarchyItem`. Wraps LSP "
      <> "`typeHierarchy/supertypes`. Pass the item returned by "
      <> "`type_hierarchy_prepare` verbatim.",
  )
}

fn type_hierarchy_subtypes_tool_definition() -> Json {
  type_hierarchy_calls_tool_definition(
    "type_hierarchy_subtypes",
    "Get subtypes for a `TypeHierarchyItem`. Wraps LSP "
      <> "`typeHierarchy/subtypes`. Pass the item returned by "
      <> "`type_hierarchy_prepare` verbatim.",
  )
}

fn type_hierarchy_calls_tool_definition(
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
                #("type", json.string("object")),
                #(
                  "description",
                  json.string(
                    "A `TypeHierarchyItem` returned by "
                    <> "`type_hierarchy_prepare`.",
                  ),
                ),
              ]),
            ),
            timeout_ms_property(),
          ]),
        ),
        #("required", json.preprocessed_array([json.string("item")])),
      ]),
    ),
  ])
}

fn semantic_tokens_tool_definition() -> Json {
  json.object([
    #("name", json.string("semantic_tokens")),
    #(
      "description",
      json.string(
        "Get LSP semantic tokens for a file (whole document or a "
          <> "range). Wraps `textDocument/semanticTokens/full` when "
          <> "no range is supplied (or all four range ints are 0); "
          <> "`textDocument/semanticTokens/range` otherwise. Returns "
          <> "the verbatim LSP `SemanticTokens` JSON: "
          <> "`{resultId?: string, data: number[]}`. The `data` array "
          <> "is the LSP-spec integer encoding — 5 ints per token: "
          <> "`[deltaLine, deltaStartChar, length, tokenType, "
          <> "tokenModifiers]`. `tokenType` is an index into the "
          <> "server's legend (in the server's `initialize` "
          <> "capabilities under `semanticTokensProvider.legend`); "
          <> "pharos does not yet stash the legend, so callers wanting "
          <> "type-name strings should fetch it themselves via "
          <> "`lsp_request_raw` against `initialize` or rely on the "
          <> "well-known LSP defaults (`namespace`, `type`, `class`, "
          <> "`enum`, `interface`, `struct`, `typeParameter`, "
          <> "`parameter`, `variable`, `property`, `enumMember`, "
          <> "`event`, `function`, `method`, `macro`, `keyword`, "
          <> "`modifier`, `comment`, `string`, `number`, `regexp`, "
          <> "`operator`, `decorator`).",
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
                    "file:// URI of the source file to tokenize.",
                  ),
                ),
              ]),
            ),
            #(
              "start_line",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Zero-based start line. Omit (with the other range "
                    <> "fields) to request /full instead of /range.",
                  ),
                ),
              ]),
            ),
            #(
              "start_character",
              json.object([
                #("type", json.string("integer")),
                #("description", json.string("Zero-based UTF-16 start offset.")),
              ]),
            ),
            #(
              "end_line",
              json.object([
                #("type", json.string("integer")),
                #("description", json.string("Zero-based end line.")),
              ]),
            ),
            #(
              "end_character",
              json.object([
                #("type", json.string("integer")),
                #("description", json.string("Zero-based UTF-16 end offset.")),
              ]),
            ),
            #(
              "timeout_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Per-call timeout in milliseconds. Default 15000.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.preprocessed_array([json.string("uri")]),
        ),
      ]),
    ),
  ])
}

fn inlay_hints_tool_definition() -> Json {
  json.object([
    #("name", json.string("inlay_hints")),
    #(
      "description",
      json.string(
        "Get inline annotations the editor would render in a range "
          <> "of source — typically inferred type hints after a `let` "
          <> "binding or parameter names at call sites. Wraps LSP "
          <> "`textDocument/inlayHint`. Returns the verbatim "
          <> "`InlayHint[]` JSON: each hint has `position`, `label` "
          <> "(string or `InlayHintLabelPart[]`), optional `kind` "
          <> "(1=Type, 2=Parameter), `tooltip`, and `textEdits`. "
          <> "rust-analyzer / pyright / typescript-language-server "
          <> "implement this; gopls requires a server-side feature "
          <> "flag. Returns `null` or `[]` when no hints in the "
          <> "range. Cold-start note: a freshly-spawned LSP may "
          <> "return empty for the first 5-15s while it indexes; "
          <> "retry once after a 1-2s pause if the file has known "
          <> "hints.",
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
                    "file:// URI of the source file to inspect.",
                  ),
                ),
              ]),
            ),
            #(
              "start_line",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string("Zero-based start line of the range."),
                ),
              ]),
            ),
            #(
              "start_character",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Zero-based UTF-16 start offset on `start_line`.",
                  ),
                ),
              ]),
            ),
            #(
              "end_line",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string("Zero-based end line of the range."),
                ),
              ]),
            ),
            #(
              "end_character",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Zero-based UTF-16 end offset on `end_line`.",
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
                    "Per-call timeout in milliseconds. Default 10000.",
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

fn apply_workspace_edit_tool_definition() -> Json {
  json.object([
    #("name", json.string("apply_workspace_edit")),
    #(
      "description",
      json.string(
        "Apply an LSP `WorkspaceEdit` to disk. Companion to "
          <> "`rename_preview` / `format_document` / `code_actions` "
          <> "(which return rendered summaries) — pair this with "
          <> "`lsp_request_raw` to fetch the raw `WorkspaceEdit` JSON, "
          <> "then call here to write. Defaults to `dry_run=true`: "
          <> "validates positions and overlap, reports per-file "
          <> "byte-count delta, but does not write. Re-call with "
          <> "`dry_run=false` to apply. Per-file atomic writes "
          <> "(write `.tmp`, rename) so a partial run never leaves a "
          <> "half-written file. Overlapping edits in the same file "
          <> "abort the run. `documentChanges` with "
          <> "`resourceOperations` (CreateFile / RenameFile / "
          <> "DeleteFile) are not supported in this version. Position "
          <> "semantics: LSP characters are UTF-16 code units; pharos "
          <> "approximates via Unicode code points (exact for the "
          <> "BMP; off-by-one per surrogate-pair char in the unlucky "
          <> "line).",
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
              "edit",
              json.object([
                #("type", json.string("object")),
                #(
                  "description",
                  json.string(
                    "LSP `WorkspaceEdit`. Must contain `changes` "
                    <> "(map of URI → TextEdit[]) or `documentChanges` "
                    <> "(TextDocumentEdit[]). Plain text edits only.",
                  ),
                ),
              ]),
            ),
            #(
              "dry_run",
              json.object([
                #("type", json.string("boolean")),
                #(
                  "description",
                  json.string(
                    "If true (default), validate but do not write. "
                    <> "Set to false to actually apply.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.preprocessed_array([json.string("edit")])),
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
                // `type: "object"` so MCP hosts forward the value
                // as a structured object instead of JSON-stringifying
                // it (Claude Code's behaviour without this hint).
                #("type", json.string("object")),
                #(
                  "description",
                  json.string(
                    "Method-specific params object, sent verbatim.",
                  ),
                ),
              ]),
            ),
            timeout_ms_property(),
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
            timeout_ms_property(),
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

/// Position-shape decoder with `timeout_ms` fall-through. Used by
/// hover, goto_*, signature_help, call_hierarchy_prepare, and
/// type_hierarchy_prepare. Resolves the default through the per-
/// tool × per-lang config stack (ADR 021) using the file URI to
/// classify the language; per-call `timeout_ms` always wins.
fn decode_position_with_timeout(
  args: Option(Dynamic),
  tool_name: String,
  default: Int,
) -> Result(#(String, Int, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use line <- decode.field("line", decode.int)
    use character <- decode.field("character", decode.int)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, line, character, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, line, char, timeout_arg)) ->
      Ok(#(uri, line, char, finalize_timeout(
        tool_name,
        default,
        uri,
        timeout_arg,
      )))
    Error(_) ->
      Error(
        "expected `uri: string`, `line: int`, `character: int`, "
        <> "optional `timeout_ms: int`",
      )
  }
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
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, line, character, include_decl, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, line, char, incl, timeout_arg)) ->
      Ok(#(
        uri,
        line,
        char,
        incl,
        finalize_timeout(
          "find_references",
          find_references.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, `line: int`, `character: int`, "
        <> "optional `include_declaration: bool`, "
        <> "optional `timeout_ms: int`",
      )
  }
}

/// `uri`-only decoder with `timeout_ms` fall-through. Used by
/// document_symbols.
fn decode_uri_only_with_timeout(
  args: Option(Dynamic),
  tool_name: String,
  default: Int,
) -> Result(#(String, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, timeout_arg)) ->
      Ok(#(uri, finalize_timeout(tool_name, default, uri, timeout_arg)))
    Error(_) ->
      Error("expected `uri: string`, optional `timeout_ms: int`")
  }
}

fn decode_rename_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, String, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use line <- decode.field("line", decode.int)
    use character <- decode.field("character", decode.int)
    use new_name <- decode.field("new_name", decode.string)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, line, character, new_name, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, line, char, new_name, timeout_arg)) ->
      Ok(#(
        uri,
        line,
        char,
        new_name,
        finalize_timeout(
          "rename_preview",
          rename_preview.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, `line: int`, `character: int`, "
        <> "`new_name: string`, optional `timeout_ms: int`",
      )
  }
}

fn decode_code_actions_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Int, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use sl <- decode.field("start_line", decode.int)
    use sc <- decode.field("start_character", decode.int)
    use el <- decode.field("end_line", decode.int)
    use ec <- decode.field("end_character", decode.int)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, sl, sc, el, ec, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, sl, sc, el, ec, timeout_arg)) ->
      Ok(#(
        uri,
        sl,
        sc,
        el,
        ec,
        finalize_timeout(
          "code_actions",
          code_actions.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, `start_line/start_character: int`, "
        <> "`end_line/end_character: int`, optional `timeout_ms: int`",
      )
  }
}

fn decode_goto_implementation_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Int, Int), String) {
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
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, line, character, limit, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, line, char, limit, timeout_arg)) ->
      Ok(#(
        uri,
        line,
        char,
        limit,
        finalize_timeout(
          "goto_implementation",
          goto_implementation.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, `line: int`, `character: int`, "
        <> "optional `limit: int`, optional `timeout_ms: int`",
      )
  }
}

fn decode_format_document_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, timeout_arg)) ->
      Ok(#(
        uri,
        finalize_timeout(
          "format_document",
          format_document.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error("expected `uri: string`, optional `timeout_ms: int`")
  }
}

/// Decoder for the chained call/type hierarchy follow-up tools.
/// Shared by both families because the LSP `item` shape is
/// structurally identical. Carries the per-tool `timeout_ms` fall-
/// through so each dispatcher can use its own
/// `[tool_config.<name>]` default.
fn decode_item_with_timeout(
  args: Option(Dynamic),
  tool_name: String,
  default: Int,
) -> Result(#(Dynamic, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use item <- decode.field("item", decode.dynamic)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(unstringify_if_needed(item), timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(item, timeout_arg)) ->
      Ok(#(item, finalize_timeout_no_lang(tool_name, default, timeout_arg)))
    Error(_) ->
      Error(
        "expected `item: <CallHierarchyItem | TypeHierarchyItem>` "
        <> "(round-trip an object returned by *_prepare), "
        <> "optional `timeout_ms: int`",
      )
  }
}

fn decode_semantic_tokens_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Int, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use sl <- decode.optional_field("start_line", 0, decode.int)
    use sc <- decode.optional_field("start_character", 0, decode.int)
    use el <- decode.optional_field("end_line", 0, decode.int)
    use ec <- decode.optional_field("end_character", 0, decode.int)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, sl, sc, el, ec, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, sl, sc, el, ec, timeout_arg)) ->
      Ok(#(
        uri,
        sl,
        sc,
        el,
        ec,
        finalize_timeout(
          "semantic_tokens",
          semantic_tokens.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, optional `start_line/start_character/"
        <> "end_line/end_character: int` (omit all four for /full), "
        <> "optional `timeout_ms: int`",
      )
  }
}

fn decode_inlay_hints_arguments(
  args: Option(Dynamic),
) -> Result(#(String, Int, Int, Int, Int, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use sl <- decode.field("start_line", decode.int)
    use sc <- decode.field("start_character", decode.int)
    use el <- decode.field("end_line", decode.int)
    use ec <- decode.field("end_character", decode.int)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, sl, sc, el, ec, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, sl, sc, el, ec, timeout_arg)) ->
      Ok(#(
        uri,
        sl,
        sc,
        el,
        ec,
        finalize_timeout(
          "inlay_hints",
          inlay_hints.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, `start_line/start_character: int`, "
        <> "`end_line/end_character: int`, optional `timeout_ms: int`",
      )
  }
}

fn decode_apply_workspace_edit_arguments(
  args: Option(Dynamic),
) -> Result(#(Dynamic, Bool), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use edit <- decode.field("edit", decode.dynamic)
    use dry_run <- decode.optional_field("dry_run", True, decode.bool)
    decode.success(#(unstringify_if_needed(edit), dry_run))
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    "expected `edit: <WorkspaceEdit>`, optional `dry_run: bool` (default true)"
  })
}

fn decode_lsp_request_raw_arguments(
  args: Option(Dynamic),
) -> Result(#(String, String, Dynamic, Int), String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use uri <- decode.field("uri", decode.string)
    use method <- decode.field("method", decode.string)
    use params <- decode.field("params", decode.dynamic)
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(uri, method, unstringify_if_needed(params), timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(uri, method, params, timeout_arg)) ->
      Ok(#(
        uri,
        method,
        params,
        finalize_timeout(
          "lsp_request_raw",
          lsp_request_raw.default_timeout_ms,
          uri,
          timeout_arg,
        ),
      ))
    Error(_) ->
      Error(
        "expected `uri: string`, `method: string`, `params: any`, "
        <> "optional `timeout_ms: int`",
      )
  }
}

/// Some MCP hosts (Claude Code at the time of writing) JSON-stringify
/// object-typed tool arguments before sending them, especially when
/// the inputSchema property does not declare `type: "object"`. The
/// receiving end then sees a string Dynamic where the tool expects a
/// structured value, and any field decoder against it errors with
/// "missing field". This helper sniffs that case: if the Dynamic
/// happens to be a string AND the string parses as JSON, the parsed
/// value replaces the original; otherwise the original Dynamic
/// passes through unchanged. Belt-and-suspenders fix alongside
/// `type: "object"` schema hints in tool definitions.
fn unstringify_if_needed(value: Dynamic) -> Dynamic {
  case decode.run(value, decode.string) {
    Error(_) -> value
    Ok(text) ->
      case json.parse(text, decode.dynamic) {
        Ok(parsed) -> parsed
        Error(_) -> value
      }
  }
}

fn decode_workspace_symbols_arguments(
  args: Option(Dynamic),
) -> Result(#(String, String, Int, Option(String), Int), String) {
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
    use timeout_arg <- decode.optional_field(
      "timeout_ms",
      None,
      decode.map(decode.int, Some),
    )
    decode.success(#(hint, query, limit, language, timeout_arg))
  }
  case decode.run(raw, decoder) {
    Ok(#(hint, query, limit, language, timeout_arg)) -> {
      // workspace_symbols's `language` arg, if explicit, wins over
      // URI-derived classification — directory hints have no
      // extension to read.
      let lang = case language {
        Some(_) -> language
        None -> lang_from_uri(hint)
      }
      let timeout = case timeout_arg {
        Some(n) -> n
        None ->
          resolve_tool_timeout(
            "workspace_symbols",
            lang,
            workspace_symbols.default_timeout_ms,
          )
      }
      Ok(#(hint, query, limit, language, timeout))
    }
    Error(_) ->
      Error(
        "expected `workspace_uri_hint: string`, `query: string`, "
        <> "optional `limit: int`, optional `language: string`, "
        <> "optional `timeout_ms: int`",
      )
  }
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
    True ->
      log.fields_at(
        "pharos/mcp/server",
        log_entry.Warn,
        "tool error returned to client",
        [#("message", message)],
      )
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

// -- ADR-026 symbol-layer tool definitions + handlers ------------------

fn find_symbol_tool_definition() -> Json {
  json.object([
    #("name", json.string("find_symbol")),
    #(
      "description",
      json.string(
        "Locate symbols by name_path (slash-delimited, e.g. "
          <> "\"User/authenticate\"). Always returns the full set of "
          <> "matches with disambiguation metadata; the LLM picks one "
          <> "and re-calls edit_at_symbol with the chosen handle. "
          <> "Returns Resolution = Single(match) | Multiple(matches) | "
          <> "NotFound(near_misses). `policy` overrides the default "
          <> "AllMatches with one of: first_match, closest_scope, "
          <> "strict_single.",
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
              "name_path",
              json.object([#("type", json.string("string"))]),
            ),
            #(
              "scope_uri",
              json.object([#("type", json.string("string"))]),
            ),
            #(
              "policy",
              json.object([
                #("type", json.string("string")),
                #(
                  "enum",
                  json.array(
                    [
                      "all_matches", "first_match", "closest_scope",
                      "strict_single",
                    ],
                    of: json.string,
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.array(["name_path", "scope_uri"], of: json.string),
        ),
      ]),
    ),
  ])
}

fn get_symbols_overview_tool_definition() -> Json {
  json.object([
    #("name", json.string("get_symbols_overview")),
    #(
      "description",
      json.string(
        "LLM-friendly outline of a single source file. Reshapes LSP "
          <> "documentSymbol output to drop block-scope variable noise "
          <> "and surface only `(name, kind, line, detail, children)`. "
          <> "Cheaper than document_symbols for navigation; use this "
          <> "first, then drill with find_symbol when you know what "
          <> "you want to operate on.",
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

fn find_referencing_symbols_tool_definition() -> Json {
  json.object([
    #("name", json.string("find_referencing_symbols")),
    #(
      "description",
      json.string(
        "Find symbols that reference the given handle. Wraps LSP "
          <> "textDocument/references then projects each call-site "
          <> "location back through documentSymbol to return the "
          <> "OWNER symbol (the function/class containing the "
          <> "reference) rather than a bare location. The handle "
          <> "comes from a prior find_symbol call.",
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
              "symbol_handle",
              json.object([#("type", json.string("object"))]),
            ),
          ]),
        ),
        #("required", json.array(["symbol_handle"], of: json.string)),
      ]),
    ),
  ])
}

fn edit_at_symbol_tool_definition() -> Json {
  json.object([
    #("name", json.string("edit_at_symbol")),
    #(
      "description",
      json.string(
        "Compose a WorkspaceEdit preview that targets the symbol "
          <> "identified by `symbol_handle` (returned from a prior "
          <> "find_symbol). Never writes — returns the proposed range "
          <> "+ new_text + rendered diff. Apply via "
          <> "apply_workspace_edit if you want to commit. `mode` "
          <> "selects the edit boundary: replace_body (rewrite the "
          <> "body keeping the signature), insert_before (prepend "
          <> "content above the whole symbol), insert_after (append "
          <> "content below the whole symbol).",
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
              "symbol_handle",
              json.object([#("type", json.string("object"))]),
            ),
            #(
              "mode",
              json.object([
                #("type", json.string("string")),
                #(
                  "enum",
                  json.array(
                    ["replace_body", "insert_before", "insert_after"],
                    of: json.string,
                  ),
                ),
              ]),
            ),
            #(
              "content",
              json.object([#("type", json.string("string"))]),
            ),
          ]),
        ),
        #(
          "required",
          json.array(
            ["symbol_handle", "mode", "content"],
            of: json.string,
          ),
        ),
      ]),
    ),
  ])
}

fn handle_find_symbol(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_find_symbol_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid find_symbol params: " <> reason,
      )
    Ok(#(name_path_str, scope_uri, policy)) ->
      case symbols.parse_name_path(name_path_str) {
        Error(err) ->
          success_response(id, fn() {
            tool_text_result(symbols.describe_symbols_error(err), True)
          })
        Ok(name_path) ->
          case symbols.find_symbol(pool, scope_uri, name_path, policy) {
            Ok(resolution) ->
              success_response(id, fn() {
                tool_text_result(
                  json.to_string(symbols.resolution_to_json(resolution)),
                  False,
                )
              })
            Error(err) ->
              success_response(id, fn() {
                tool_text_result(symbols.describe_symbols_error(err), True)
              })
          }
      }
  }
}

fn handle_get_symbols_overview(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_get_symbols_overview_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid get_symbols_overview params: " <> reason,
      )
    Ok(uri) ->
      case symbols.get_symbols_overview(pool, uri) {
        Ok(tree) ->
          success_response(id, fn() {
            tool_text_result(
              json.to_string(symbols.symbol_tree_to_json(tree)),
              False,
            )
          })
        Error(err) ->
          success_response(id, fn() {
            tool_text_result(symbols.describe_symbols_error(err), True)
          })
      }
  }
}

fn handle_find_referencing_symbols(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_handle_only_arguments(arguments, "find_referencing_symbols") {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid find_referencing_symbols params: " <> reason,
      )
    Ok(handle) ->
      case symbols.find_referencing_symbols(pool, handle) {
        Ok(matches) ->
          success_response(id, fn() {
            tool_text_result(
              json.to_string(
                json.object([
                  #("count", json.int(list.length(matches))),
                  #(
                    "owners",
                    json.preprocessed_array(
                      list.map(matches, symbols.symbol_match_to_json),
                    ),
                  ),
                ]),
              ),
              False,
            )
          })
        Error(err) ->
          success_response(id, fn() {
            tool_text_result(symbols.describe_symbols_error(err), True)
          })
      }
  }
}

fn handle_edit_at_symbol(
  pool: Pool,
  id: Id,
  arguments: Option(Dynamic),
) -> String {
  case decode_edit_at_symbol_arguments(arguments) {
    Error(reason) ->
      error_response(
        Some(id),
        -32_602,
        "Invalid edit_at_symbol params: " <> reason,
      )
    Ok(#(handle, mode, content)) ->
      case symbols.edit_at_symbol(pool, handle, mode, content) {
        Ok(preview) ->
          success_response(id, fn() {
            tool_text_result(
              json.to_string(symbols.edit_preview_to_json(preview)),
              False,
            )
          })
        Error(err) ->
          success_response(id, fn() {
            tool_text_result(symbols.describe_symbols_error(err), True)
          })
      }
  }
}

fn decode_find_symbol_arguments(
  arguments: Option(Dynamic),
) -> Result(#(String, String, symbols.Disambiguation), String) {
  case arguments {
    None -> Error("missing arguments")
    Some(args) -> {
      let decoder = {
        use name_path <- decode.field("name_path", decode.string)
        use scope_uri <- decode.field("scope_uri", decode.string)
        use policy_str <- decode.optional_field(
          "policy",
          "all_matches",
          decode.string,
        )
        decode.success(#(name_path, scope_uri, policy_str))
      }
      case decode.run(args, decoder) {
        Error(_) -> Error("name_path + scope_uri required")
        Ok(#(np, uri, policy_str)) -> {
          let policy = case policy_str {
            "first_match" -> symbols.FirstMatch
            "closest_scope" -> symbols.ClosestScope
            "strict_single" -> symbols.StrictSingle
            _ -> symbols.AllMatches
          }
          Ok(#(np, uri, policy))
        }
      }
    }
  }
}

fn decode_get_symbols_overview_arguments(
  arguments: Option(Dynamic),
) -> Result(String, String) {
  case arguments {
    None -> Error("missing arguments")
    Some(args) -> {
      let decoder = {
        use uri <- decode.field("uri", decode.string)
        decode.success(uri)
      }
      case decode.run(args, decoder) {
        Error(_) -> Error("uri required")
        Ok(uri) -> Ok(uri)
      }
    }
  }
}

fn decode_handle_only_arguments(
  arguments: Option(Dynamic),
  tool_name: String,
) -> Result(symbols.SymbolHandle, String) {
  case arguments {
    None -> Error("missing arguments for " <> tool_name)
    Some(args) -> {
      let decoder = {
        use handle <- decode.field(
          "symbol_handle",
          symbols.symbol_handle_decoder(),
        )
        decode.success(handle)
      }
      case decode.run(args, decoder) {
        Error(_) -> Error("symbol_handle field missing or malformed")
        Ok(h) -> Ok(h)
      }
    }
  }
}

fn decode_edit_at_symbol_arguments(
  arguments: Option(Dynamic),
) -> Result(#(symbols.SymbolHandle, symbols.EditMode, String), String) {
  case arguments {
    None -> Error("missing arguments")
    Some(args) -> {
      let decoder = {
        use handle <- decode.field(
          "symbol_handle",
          symbols.symbol_handle_decoder(),
        )
        use mode_str <- decode.field("mode", decode.string)
        use content <- decode.field("content", decode.string)
        decode.success(#(handle, mode_str, content))
      }
      case decode.run(args, decoder) {
        Error(_) ->
          Error("symbol_handle + mode + content required")
        Ok(#(handle, mode_str, content)) ->
          case symbols.edit_mode_from_string(mode_str) {
            Ok(mode) -> Ok(#(handle, mode, content))
            Error(err) -> Error(symbols.describe_symbols_error(err))
          }
      }
    }
  }
}
