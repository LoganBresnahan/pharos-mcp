//// Tier 4 — runtime introspection MCP tools (M9.5 Part C).
////
//// All twelve handlers live here so `mcp/server.gleam` only has to
//// register them as a batch. Each handler takes the same shape:
////
////   `handle_xxx(pool, arguments) -> ToolResult`
////
//// where `ToolResult` is one of:
////
////   * `Ok(json_payload)` — the tier4 tool produced a result the
////     caller should wrap in a `tool_text_result(_, isError=False)`
////     content block;
////   * `Err(message)` — the tier4 tool failed; caller wraps in a
////     `tool_text_result(message, isError=True)` block.
////
//// The MCP server stays the orchestrator: it parses tools/call
//// params, decides this is tier4, calls `dispatch/3`, and wraps the
//// returned text in the standard JSON-RPC envelope.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pharos/config
import pharos/log
import pharos/log/entry
import pharos/lsp/pool.{type Pool}
import pharos/runtime

const default_processes_limit: Int = 100

const default_log_tail_n: Int = 200

const trace_lsp_max_duration_ms: Int = 30_000

const trace_calls_max_duration_ms: Int = 30_000

const trace_calls_max_events: Int = 5000

pub type ToolResult =
  Result(String, String)

/// Tier-4 tool definitions. Returned to MCP clients via `tools/list`.
/// Each entry is a `(name, builder)` so the caller can filter by
/// the configured tool surface before instantiating the JSON.
pub fn named_definitions() -> List(#(String, fn() -> Json)) {
  [
    #("runtime_processes", runtime_processes_definition),
    #("runtime_pid_info", runtime_pid_info_definition),
    #("runtime_supervision_tree", runtime_supervision_tree_definition),
    #("runtime_ets_tables", runtime_ets_tables_definition),
    #("runtime_memory", runtime_memory_definition),
    #("runtime_applications", runtime_applications_definition),
    #("runtime_scheduler_util", runtime_scheduler_util_definition),
    #("runtime_log_tail", runtime_log_tail_definition),
    #("runtime_log_clear", runtime_log_clear_definition),
    #("runtime_log_level", runtime_log_level_definition),
    #("runtime_trace_lsp", runtime_trace_lsp_definition),
    #("runtime_kill_lsp", runtime_kill_lsp_definition),
    #("runtime_trace_calls", runtime_trace_calls_definition),
  ]
}

/// Dispatch a tools/call to a tier-4 handler. Returns `None` when
/// `name` is not a tier-4 tool so the caller can fall through to
/// the existing tier-1/tier-2 dispatch.
pub fn dispatch(
  pool: Pool,
  name: String,
  arguments: Option(Dynamic),
) -> Option(ToolResult) {
  case name {
    "runtime_processes" -> Some(handle_processes(arguments))
    "runtime_pid_info" -> Some(handle_pid_info(arguments))
    "runtime_supervision_tree" -> Some(handle_supervision_tree())
    "runtime_ets_tables" -> Some(handle_ets_tables())
    "runtime_memory" -> Some(handle_memory())
    "runtime_applications" -> Some(handle_applications())
    "runtime_scheduler_util" -> Some(handle_scheduler_util(arguments))
    "runtime_log_tail" -> Some(handle_log_tail(arguments))
    "runtime_log_clear" -> Some(handle_log_clear())
    "runtime_log_level" -> Some(handle_log_level(arguments))
    "runtime_trace_lsp" -> Some(handle_trace_lsp(arguments))
    "runtime_kill_lsp" -> Some(handle_kill_lsp(pool, arguments))
    "runtime_trace_calls" -> Some(handle_trace_calls(arguments))
    _ -> None
  }
}

// -- runtime_processes ---------------------------------------------------

fn runtime_processes_definition() -> Json {
  json.object([
    #("name", json.string("runtime_processes")),
    #(
      "description",
      json.string(
        "List the first N live BEAM processes with registered name, "
          <> "current function, mailbox depth, memory, and status. "
          <> "Use to spot stuck mailboxes or memory hot spots when "
          <> "pharos itself is misbehaving.",
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
              "limit",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Cap on returned rows (default 100). Higher values "
                      <> "may flood the LLM context.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_processes(args: Option(Dynamic)) -> ToolResult {
  let limit =
    decode_int_field(args, "limit", default_processes_limit)
    |> result.unwrap(default_processes_limit)
  let rows = runtime.list_processes(limit)
  let entries =
    list.map(rows, fn(row) {
      json.object([
        #("pid", json.string(row.pid)),
        #("registered_name", json.string(row.registered_name)),
        #("current_function", json.string(row.current_function)),
        #("message_queue_len", json.int(row.message_queue_len)),
        #("memory", json.int(row.memory)),
        #("status", json.string(row.status)),
      ])
    })
  Ok(json.to_string(json.array(entries, of: fn(j) { j })))
}

// -- runtime_pid_info ----------------------------------------------------

fn runtime_pid_info_definition() -> Json {
  json.object([
    #("name", json.string("runtime_pid_info")),
    #(
      "description",
      json.string(
        "Full erlang:process_info/1 dump for one pid (text form, "
          <> "e.g. `<0.143.0>`). Pids change across restart; resolve "
          <> "via runtime_processes first if unsure.",
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
              "pid",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("Pid in `<X.Y.Z>` form.")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["pid"], of: json.string)),
      ]),
    ),
  ])
}

fn handle_pid_info(args: Option(Dynamic)) -> ToolResult {
  case decode_string_field(args, "pid") {
    Error(reason) -> Error(reason)
    Ok(pid_text) ->
      case runtime.process_info_for(pid_text) {
        Error(_) -> Error("no process matching pid " <> pid_text)
        Ok(info) -> {
          let entries =
            list.map(info, fn(pair) {
              let #(k, v) = pair
              #(k, json.string(v))
            })
          Ok(json.to_string(json.object(entries)))
        }
      }
  }
}

// -- runtime_supervision_tree --------------------------------------------

fn runtime_supervision_tree_definition() -> Json {
  json.object([
    #("name", json.string("runtime_supervision_tree")),
    #(
      "description",
      json.string(
        "Snapshot of every supervised process under every running "
          <> "OTP application. Each node carries pid, registered "
          <> "name, current function, and supervisor/worker kind.",
      ),
    ),
    #(
      "inputSchema",
      json.object([#("type", json.string("object"))]),
    ),
  ])
}

fn handle_supervision_tree() -> ToolResult {
  let nodes = runtime.supervision_tree()
  let entries =
    list.map(nodes, fn(node) {
      json.object([
        #("pid", json.string(node.pid)),
        #("registered_name", json.string(node.registered_name)),
        #("current_function", json.string(node.current_function)),
        #("kind", json.string(node.kind)),
      ])
    })
  Ok(json.to_string(json.array(entries, of: fn(j) { j })))
}

// -- runtime_ets_tables --------------------------------------------------

fn runtime_ets_tables_definition() -> Json {
  json.object([
    #("name", json.string("runtime_ets_tables")),
    #(
      "description",
      json.string(
        "All inspectable ETS tables with name, size, memory, owner "
          <> "pid, type, and protection. Look here when memory or "
          <> "table-not-found errors surface.",
      ),
    ),
    #("inputSchema", json.object([#("type", json.string("object"))])),
  ])
}

fn handle_ets_tables() -> ToolResult {
  let rows = runtime.list_ets_tables()
  let entries =
    list.map(rows, fn(t) {
      json.object([
        #("name", json.string(t.name)),
        #("size", json.int(t.size)),
        #("memory_words", json.int(t.memory_words)),
        #("owner", json.string(t.owner)),
        #("type", json.string(t.table_type)),
        #("protection", json.string(t.protection)),
      ])
    })
  Ok(json.to_string(json.array(entries, of: fn(j) { j })))
}

// -- runtime_memory ------------------------------------------------------

fn runtime_memory_definition() -> Json {
  json.object([
    #("name", json.string("runtime_memory")),
    #(
      "description",
      json.string(
        "erlang:memory() breakdown — total, processes, atom, binary, "
          <> "ets, code, system. All values in bytes.",
      ),
    ),
    #("inputSchema", json.object([#("type", json.string("object"))])),
  ])
}

fn handle_memory() -> ToolResult {
  let rows = runtime.memory_breakdown()
  let entries =
    list.map(rows, fn(pair) {
      let #(k, v) = pair
      #(k, json.int(v))
    })
  Ok(json.to_string(json.object(entries)))
}

// -- runtime_applications ------------------------------------------------

fn runtime_applications_definition() -> Json {
  json.object([
    #("name", json.string("runtime_applications")),
    #(
      "description",
      json.string(
        "Running OTP applications with descriptions and versions.",
      ),
    ),
    #("inputSchema", json.object([#("type", json.string("object"))])),
  ])
}

fn handle_applications() -> ToolResult {
  let rows = runtime.list_applications()
  let entries =
    list.map(rows, fn(app) {
      json.object([
        #("name", json.string(app.name)),
        #("description", json.string(app.description)),
        #("version", json.string(app.version)),
      ])
    })
  Ok(json.to_string(json.array(entries, of: fn(j) { j })))
}

// -- runtime_scheduler_util ----------------------------------------------

fn runtime_scheduler_util_definition() -> Json {
  json.object([
    #("name", json.string("runtime_scheduler_util")),
    #(
      "description",
      json.string(
        "scheduler:utilization sample over `interval_ms` (default "
          <> "1000). Blocks for the duration. Returns one row per "
          <> "scheduler plus aggregates. Sampling resolution is one "
          <> "second — values are floor-divided by 1000 with a "
          <> "minimum of 1s, so `interval_ms=500` samples for 1s.",
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
              "interval_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string("Sampling window in milliseconds (default 1000)."),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_scheduler_util(args: Option(Dynamic)) -> ToolResult {
  let interval =
    decode_int_field(args, "interval_ms", 1000)
    |> result.unwrap(1000)
  let samples = runtime.scheduler_utilization(interval)
  let entries =
    list.map(samples, fn(sample) {
      json.object([
        #("type", json.string(sample.sample_type)),
        #("id", json.string(sample.id)),
        #("utilization", json.float(sample.utilization)),
      ])
    })
  Ok(json.to_string(json.array(entries, of: fn(j) { j })))
}

// -- runtime_log_tail ----------------------------------------------------

fn runtime_log_tail_definition() -> Json {
  json.object([
    #("name", json.string("runtime_log_tail")),
    #(
      "description",
      json.string(
        "Read the last N entries from the in-memory log ring. "
          <> "Optional substring filter narrows results (e.g. "
          <> "`cid=42` to inspect one MCP request's flow).",
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
              "n",
              json.object([
                #("type", json.string("integer")),
                #("description", json.string("Number of entries (default 200).")),
              ]),
            ),
            #(
              "filter",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("Substring filter; empty disables filtering."),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_log_tail(args: Option(Dynamic)) -> ToolResult {
  let n =
    decode_int_field(args, "n", default_log_tail_n)
    |> result.unwrap(default_log_tail_n)
  let filter_text =
    decode_string_field_default(args, "filter", "")
    |> result.unwrap("")
  let rows = log.ring_tail(n, filter_text)
  let entries =
    list.map(rows, fn(row) {
      let #(level, line) = row
      json.object([
        #("level", json.string(entry.level_to_string(level))),
        #("line", json.string(line)),
      ])
    })
  Ok(json.to_string(json.array(entries, of: fn(j) { j })))
}

// -- runtime_log_clear ---------------------------------------------------

fn runtime_log_clear_definition() -> Json {
  json.object([
    #("name", json.string("runtime_log_clear")),
    #(
      "description",
      json.string(
        "Reset the in-memory log ring. Use before reproducing a "
          <> "bug so a follow-up runtime_log_tail returns only the "
          <> "relevant lines.",
      ),
    ),
    #("inputSchema", json.object([#("type", json.string("object"))])),
  ])
}

fn handle_log_clear() -> ToolResult {
  log.ring_clear()
  Ok("{\"cleared\":true}")
}

// -- runtime_log_level ---------------------------------------------------

fn runtime_log_level_definition() -> Json {
  json.object([
    #("name", json.string("runtime_log_level")),
    #(
      "description",
      json.string(
        "Override the log level for one target prefix at runtime. "
          <> "`level` is `debug|info|warn|error|off`. Example: "
          <> "`{ target: \"pharos/lsp/proc\", level: \"debug\" }` "
          <> "to crank one module's verbosity for the rest of "
          <> "the session.",
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
              "target",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Target prefix to override (e.g. `pharos/lsp/proc`).",
                  ),
                ),
              ]),
            ),
            #(
              "level",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("`debug` | `info` | `warn` | `error` | `off`"),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["target", "level"], of: json.string)),
      ]),
    ),
  ])
}

fn handle_log_level(args: Option(Dynamic)) -> ToolResult {
  use target <- result.try(decode_string_field(args, "target"))
  use level_text <- result.try(decode_string_field(args, "level"))
  let parsed = parse_level_or_off(level_text)
  case parsed {
    Error(_) ->
      Error(
        "level must be one of debug|info|warn|error|off (got `"
          <> level_text
          <> "`)",
      )
    Ok(opt) ->
      case log.set_target_level(target, opt) {
        Error(_) -> Error("log writer is not running; cannot set level")
        Ok(Nil) ->
          Ok(
            "{\"target\":\""
              <> target
              <> "\",\"level\":\""
              <> level_text
              <> "\"}",
          )
      }
  }
}

fn parse_level_or_off(raw: String) -> Result(option.Option(entry.Level), Nil) {
  case string.lowercase(string.trim(raw)) {
    "off" -> Ok(None)
    other ->
      case entry.parse_level(other) {
        Ok(level) -> Ok(Some(level))
        Error(_) -> Error(Nil)
      }
  }
}

// -- runtime_trace_lsp ---------------------------------------------------

fn runtime_trace_lsp_definition() -> Json {
  json.object([
    #("name", json.string("runtime_trace_lsp")),
    #(
      "description",
      json.string(
        "Capture LSP wire bytes for a fixed window then return the "
          <> "collected trace lines. Toggles the `pharos/lsp/trace` "
          <> "filter on, sleeps `duration_ms`, snapshots the ring, "
          <> "and restores the filter. Cap: "
          <> int.to_string(trace_lsp_max_duration_ms)
          <> "ms.",
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
              "duration_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "How long to keep the tracer on (default 5000, max "
                      <> int.to_string(trace_lsp_max_duration_ms)
                      <> ").",
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_trace_lsp(args: Option(Dynamic)) -> ToolResult {
  let raw_duration =
    decode_int_field(args, "duration_ms", 5000)
    |> result.unwrap(5000)
  let duration = case raw_duration > trace_lsp_max_duration_ms {
    True -> trace_lsp_max_duration_ms
    False -> raw_duration
  }

  // Activate the tracer override; we deliberately do not capture
  // the prior state — Part C MVP keeps this simple and re-applies
  // `info` at the end. If a user previously set the trace target
  // via PHAROS_LOG, they re-apply via runtime_log_level after.
  case log.set_target_level("pharos/lsp/trace", Some(entry.Debug)) {
    Error(_) -> Error("log writer is not running; cannot enable tracer")
    Ok(Nil) -> {
      let before = log.ring_size()
      sleep(duration)
      let _ = log.set_target_level("pharos/lsp/trace", None)
      let after = log.ring_size()
      let captured = log.ring_tail(after - before + 50, "lsp wire")
      let entries =
        list.map(captured, fn(row) {
          let #(_level, line) = row
          json.string(line)
        })
      Ok(
        json.to_string(
          json.object([
            #("duration_ms", json.int(duration)),
            #("captured", json.array(entries, of: fn(j) { j })),
          ]),
        ),
      )
    }
  }
}

// -- runtime_kill_lsp ----------------------------------------------------

fn runtime_kill_lsp_definition() -> Json {
  json.object([
    #("name", json.string("runtime_kill_lsp")),
    #(
      "description",
      json.string(
        "Terminate cached LSP worker(s). Routes through pool so the "
          <> "next tool call re-spawns transparently — use when an "
          <> "LSP appears stuck. Cannot kill anything other than the "
          <> "supervised LSP workers. Pass `server_id` to target one "
          <> "specific server when a language has multiple (per "
          <> "ADR-019). Omit `server_id` to kill every server cached "
          <> "for the (language, workspace) pair.",
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
              "language",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("Language id, e.g. `rust`, `go`, `typescript`."),
                ),
              ]),
            ),
            #(
              "workspace",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("Workspace root path the LSP serves."),
                ),
              ]),
            ),
            #(
              "server_id",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Optional. Per-language server id (e.g. `pyright`, "
                      <> "`ruff`). Omit to kill every server cached for "
                      <> "the language+workspace pair.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.array(["language", "workspace"], of: json.string),
        ),
      ]),
    ),
  ])
}

fn handle_kill_lsp(pool: Pool, args: Option(Dynamic)) -> ToolResult {
  use language <- result.try(decode_string_field(args, "language"))
  use workspace <- result.try(decode_string_field(args, "workspace"))
  // Optional server_id arg (ADR-019 Stage 2): when present, kill that
  // one server. Empty string (the default) kills every server cached
  // for (language, workspace) — back-compat with single-server
  // languages where callers never thought about server_id.
  use server_id <- result.try(decode_string_field_default(
    args,
    "server_id",
    "",
  ))
  case pool.kill_lsp(pool, language, workspace, server_id) {
    pool.Killed(count) ->
      Ok(
        "{\"killed\":true,\"count\":"
          <> int.to_string(count)
          <> ",\"language\":\""
          <> language
          <> "\",\"workspace\":\""
          <> workspace
          <> case server_id {
            "" -> "\"}"
            s -> "\",\"server_id\":\"" <> s <> "\"}"
          },
      )
    pool.NotFound ->
      Ok(
        "{\"killed\":false,\"reason\":\"no cached LSP for ("
          <> language
          <> ", "
          <> workspace
          <> case server_id {
            "" -> ""
            s -> ", " <> s
          }
          <> ")\"}",
      )
  }
}

// -- runtime_trace_calls -------------------------------------------------

fn runtime_trace_calls_definition() -> Json {
  json.object([
    #("name", json.string("runtime_trace_calls")),
    #(
      "description",
      json.string(
        "Capture function calls into one module via recon_trace. "
          <> "Gated behind `[runtime] trace_calls_enabled = true` "
          <> "(or PHAROS_RUNTIME_TRACE_ENABLED=1) — refuses otherwise. "
          <> "Caps: "
          <> int.to_string(trace_calls_max_duration_ms)
          <> "ms duration, "
          <> int.to_string(trace_calls_max_events)
          <> " max events. Refuses to trace BEAM hot modules "
          <> "(`erlang`, `ets`, `gleam@otp@actor`, "
          <> "`gleam@erlang@process`).",
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
              "module",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Module to trace (Erlang atom name, e.g. "
                      <> "`pharos@lsp@proc`).",
                  ),
                ),
              ]),
            ),
            #(
              "function",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Function name; omit or `_` for any function.",
                  ),
                ),
              ]),
            ),
            #(
              "arity",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string("Arity; omit or -1 for any arity."),
                ),
              ]),
            ),
            #(
              "duration_ms",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Trace window (default 3000, max "
                      <> int.to_string(trace_calls_max_duration_ms)
                      <> ").",
                  ),
                ),
              ]),
            ),
            #(
              "max_events",
              json.object([
                #("type", json.string("integer")),
                #(
                  "description",
                  json.string(
                    "Auto-stop after this many events (default 500, "
                      <> "max "
                      <> int.to_string(trace_calls_max_events)
                      <> ").",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["module"], of: json.string)),
      ]),
    ),
  ])
}

fn handle_trace_calls(args: Option(Dynamic)) -> ToolResult {
  let cfg = config.cached()
  case cfg.runtime.trace_calls_enabled {
    False ->
      Error(
        "runtime_trace_calls is disabled. Enable it in pharos.toml under "
          <> "[runtime] trace_calls_enabled = true (or set "
          <> "PHAROS_RUNTIME_TRACE_ENABLED=1) and restart pharos",
      )
    True -> trace_calls_inner(args)
  }
}

fn trace_calls_inner(args: Option(Dynamic)) -> ToolResult {
  use module_text <- result.try(decode_string_field(args, "module"))
  case is_hot_module(module_text) {
    True ->
      Error(
        "refusing to trace hot module `"
          <> module_text
          <> "` — would overwhelm the BEAM scheduler",
      )
    False -> trace_calls_run(module_text, args)
  }
}

fn trace_calls_run(module_text: String, args: Option(Dynamic)) -> ToolResult {
  let function_text =
    decode_string_field_default(args, "function", "_")
    |> result.unwrap("_")
  let arity_int =
    decode_int_field(args, "arity", -1)
    |> result.unwrap(-1)
  let raw_duration =
    decode_int_field(args, "duration_ms", 3000)
    |> result.unwrap(3000)
  let raw_events =
    decode_int_field(args, "max_events", 500)
    |> result.unwrap(500)
  let duration = clamp(raw_duration, 100, trace_calls_max_duration_ms)
  let events = clamp(raw_events, 1, trace_calls_max_events)

  let module_dyn = atom_dynamic(module_text)
  let function_dyn = case function_text {
    "_" -> runtime.wildcard()
    other -> atom_dynamic(other)
  }
  let arity_dyn = case arity_int {
    -1 -> runtime.wildcard()
    n -> int_dynamic(n)
  }

  case runtime.trace_calls(module_dyn, function_dyn, arity_dyn, #(duration, events)) {
    Error(reason) -> Error("recon_trace refused: " <> reason)
    Ok(lines) ->
      Ok(
        json.to_string(
          json.object([
            #("module", json.string(module_text)),
            #("function", json.string(function_text)),
            #("arity", json.int(arity_int)),
            #("duration_ms", json.int(duration)),
            #("max_events", json.int(events)),
            #(
              "events",
              json.array(list.map(lines, json.string), of: fn(j) { j }),
            ),
          ]),
        ),
      )
  }
}

fn is_hot_module(name: String) -> Bool {
  case name {
    "erlang" | "ets" | "gleam@otp@actor" | "gleam@erlang@process" -> True
    _ -> False
  }
}

fn clamp(value: Int, min_val: Int, max_val: Int) -> Int {
  case value < min_val, value > max_val {
    True, _ -> min_val
    _, True -> max_val
    _, _ -> value
  }
}

// -- helpers --------------------------------------------------------------

fn decode_string_field(
  args: Option(Dynamic),
  field: String,
) -> Result(String, String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use value <- decode.field(field, decode.string)
    decode.success(value)
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `" <> field <> ": string`" })
}

fn decode_string_field_default(
  args: Option(Dynamic),
  field: String,
  default: String,
) -> Result(String, String) {
  case args {
    None -> Ok(default)
    Some(raw) -> {
      let decoder = {
        use value <- decode.optional_field(field, default, decode.string)
        decode.success(value)
      }
      decode.run(raw, decoder)
      |> result.map_error(fn(_) {
        "expected `" <> field <> ": string` (or omit)"
      })
    }
  }
}

fn decode_int_field(
  args: Option(Dynamic),
  field: String,
  default: Int,
) -> Result(Int, String) {
  case args {
    None -> Ok(default)
    Some(raw) -> {
      let decoder = {
        use value <- decode.optional_field(field, default, decode.int)
        decode.success(value)
      }
      decode.run(raw, decoder)
      |> result.map_error(fn(_) {
        "expected `" <> field <> ": integer` (or omit)"
      })
    }
  }
}

@external(erlang, "erlang", "binary_to_atom")
fn atom_dynamic(text: String) -> Dynamic

@external(erlang, "pharos_runtime_ffi", "int_to_dynamic")
fn int_dynamic(n: Int) -> Dynamic

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil
