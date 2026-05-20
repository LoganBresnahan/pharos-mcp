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

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pharos/config
import pharos/tools/session_overrides
import pharos/tools/tool_helpers
import pharos/log
import pharos/log/entry
import pharos/log/trace_ring
import pharos/lsp/capabilities as lsp_capabilities
import pharos/lsp/pool.{type Pool}
import pharos/lsp/registry
import pharos/lsp/registry_toml
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
    #("runtime_language_config", runtime_language_config_definition),
    #("runtime_set_tool_timeout", runtime_set_tool_timeout_definition),
    #("runtime_effective_tool_config", runtime_effective_tool_config_definition),
    #("runtime_lsp_state", runtime_lsp_state_definition),
    #("runtime_pool_recon", runtime_pool_recon_definition),
    #("runtime_server_capabilities", runtime_server_capabilities_definition),
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
    "runtime_language_config" -> Some(handle_language_config(arguments))
    "runtime_set_tool_timeout" -> Some(handle_set_tool_timeout(arguments))
    "runtime_effective_tool_config" ->
      Some(handle_effective_tool_config(arguments))
    "runtime_lsp_state" -> Some(handle_lsp_state(pool))
    "runtime_pool_recon" -> Some(handle_pool_recon(arguments))
    "runtime_server_capabilities" ->
      Some(handle_server_capabilities(pool))
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

  // Snapshot the trace_ring's current size so we can return only
  // entries captured DURING the window. The trace_ring is always-on
  // (M11 fix for the parallel-dispatch race that left
  // sequentially-sound captures empty under concurrent producer +
  // trace_lsp dispatch). No filter toggle, no race: the producer
  // writes unconditionally, this read just reports the delta.
  //
  // The set_target_level call still runs — it activates the gated
  // log path so stderr/file sinks see the wire entries during the
  // window — but trace_lsp's return value comes from the
  // unconditional ring, not from the filter-gated log ring.
  let _ = log.set_target_level("pharos/lsp/trace", Some(entry.Debug))
  let before = trace_ring.size()
  sleep(duration)
  let _ = log.set_target_level("pharos/lsp/trace", None)
  let after = trace_ring.size()
  // Read captured-during-window entries plus a small slack so an
  // emit landing right after our `after` read is not lost. Filter
  // by "lsp wire" to defend against future co-tenants on the ring.
  let captured = trace_ring.tail(after - before + 10, "lsp wire")
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

// -- runtime_language_config ---------------------------------------------

fn runtime_language_config_definition() -> Json {
  json.object([
    #("name", json.string("runtime_language_config")),
    #(
      "description",
      json.string(
        "Print the bundled-default registry entry for one language as "
          <> "TOML. Output is paste-ready: copy into pharos.toml's "
          <> "`[languages.<id>]` and `[[languages.<id>.servers]]` "
          <> "blocks, edit one or more fields, save. Use when you need "
          <> "to override `initialization_options_json` or "
          <> "`workspace_configuration_json` (whole-blob replace) and "
          <> "want the bundled default as a starting point. Mirrors "
          <> "the `pharos --print-language-config <lang>` CLI flag.",
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
                  json.string(
                    "Language id, e.g. `rust`, `python`, `typescript`. "
                      <> "Match against the registry's keys; case-sensitive.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.preprocessed_array([json.string("language")])),
      ]),
    ),
  ])
}

fn handle_language_config(args: Option(Dynamic)) -> ToolResult {
  case decode_string_field(args, "language") {
    Error(reason) ->
      Error("Invalid runtime_language_config params: " <> reason)
    Ok(language) -> {
      let registry = registry.cached()
      case dict.get(registry, language) {
        Error(_) -> {
          let known =
            dict.keys(registry)
            |> string_join(", ")
          Error(
            "language `"
            <> language
            <> "` not found in registry. Known: "
            <> known,
          )
        }
        Ok(config) -> Ok(registry_toml.render_language(config))
      }
    }
  }
}

@external(erlang, "lists", "join")
fn list_join(sep: String, xs: List(String)) -> List(String)

fn string_join(xs: List(String), sep: String) -> String {
  list_join(sep, xs)
  |> list_iolist_to_binary
}

@external(erlang, "erlang", "iolist_to_binary")
fn list_iolist_to_binary(xs: List(String)) -> String

// -- runtime_set_tool_timeout -------------------------------------------

fn runtime_set_tool_timeout_definition() -> Json {
  json.object([
    #("name", json.string("runtime_set_tool_timeout")),
    #(
      "description",
      json.string(
        "Set a session-scoped `default_timeout_ms` for one MCP tool, "
          <> "optionally narrowed to one language. Survives until "
          <> "pharos restarts; takes precedence over `[tool_config.*]` "
          <> "in pharos.toml. Use when an LSP timeout suggests the "
          <> "default is too tight and you want every subsequent call "
          <> "in this session to inherit the bump without passing "
          <> "`timeout_ms` each time. Resolution stack: compile-time → "
          <> "TOML per-tool → TOML per-tool×lang → THIS → per-call. "
          <> "Returns the new effective configuration as JSON.",
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
              "tool",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "MCP tool name (e.g. `find_references`, "
                      <> "`format_document`, `hover`).",
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
                    "Optional language id (e.g. `rust`, `java`, "
                      <> "`scala`). Omit to set the per-tool global "
                      <> "default. When supplied, the override only "
                      <> "applies when pharos resolves a call's URI to "
                      <> "this language.",
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
                    "New default timeout in milliseconds. Must be > 0.",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.preprocessed_array([
            json.string("tool"),
            json.string("timeout_ms"),
          ]),
        ),
      ]),
    ),
  ])
}

fn handle_set_tool_timeout(args: Option(Dynamic)) -> ToolResult {
  use tool <- result.try(decode_string_field(args, "tool"))
  use timeout_ms <- result.try(decode_required_int(args, "timeout_ms"))
  use lang <- result.try(decode_optional_string(args, "language"))
  case timeout_ms > 0 {
    False -> Error("timeout_ms must be > 0 (got " <> int.to_string(timeout_ms) <> ")")
    True -> {
      session_overrides.set(tool, lang, timeout_ms)
      let lang_text = case lang {
        Some(l) -> l
        None -> "*"
      }
      // Structured shape per ADR 022 — fields stay parseable for
      // the upcoming runtime_effective_tool_config digest.
      log.fields_at(
        "pharos/tool_config/autotune",
        entry.Info,
        "session override applied",
        [
          #("tool", tool),
          #("language", lang_text),
          #("timeout_ms", int.to_string(timeout_ms)),
        ],
      )
      Ok(
        "{\"tool\":\""
          <> tool
          <> "\",\"language\":"
          <> case lang {
            Some(l) -> "\"" <> l <> "\""
            None -> "null"
          }
          <> ",\"timeout_ms\":"
          <> int.to_string(timeout_ms)
          <> ",\"scope\":\"session\"}",
      )
    }
  }
}

fn decode_required_int(
  args: Option(Dynamic),
  field: String,
) -> Result(Int, String) {
  use raw <- result.try(option.to_result(args, "arguments object missing"))
  let decoder = {
    use value <- decode.field(field, decode.int)
    decode.success(value)
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "expected `" <> field <> ": int`" })
}

fn decode_optional_string(
  args: Option(Dynamic),
  field: String,
) -> Result(Option(String), String) {
  case args {
    None -> Ok(None)
    Some(raw) -> {
      let decoder = {
        use value <- decode.optional_field(
          field,
          None,
          decode.map(decode.string, Some),
        )
        decode.success(value)
      }
      decode.run(raw, decoder)
      |> result.map_error(fn(_) {
        "expected optional `" <> field <> ": string`"
      })
    }
  }
}

// -- runtime_effective_tool_config --------------------------------------

fn runtime_effective_tool_config_definition() -> Json {
  json.object([
    #("name", json.string("runtime_effective_tool_config")),
    #(
      "description",
      json.string(
        "Inspect the per-tool timeout configuration as resolved RIGHT "
          <> "NOW. Returns three sections: `session_overrides` (set "
          <> "this session via runtime_set_tool_timeout, lost on "
          <> "restart), `toml_overrides` (loaded from "
          <> "[tool_config.<name>] / [tool_config.<name>.<lang>] in "
          <> "pharos.toml), and `effective_summary` for any (tool, "
          <> "lang) combo the LLM passes. Useful when a tool times "
          <> "out unexpectedly and you need to see which layer is "
          <> "winning. Pass `tool` alone to scope the dump; pass both "
          <> "`tool` and `language` to compute the resolved value "
          <> "with source attribution.",
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
              "tool",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "Optional tool name. If omitted, every tool with "
                      <> "any override is included.",
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
                    "Optional language id. When supplied alongside "
                      <> "`tool`, the response includes an "
                      <> "`effective_summary` resolving the timeout "
                      <> "for that combo with source attribution.",
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

fn handle_effective_tool_config(args: Option(Dynamic)) -> ToolResult {
  use tool_filter <- result.try(decode_optional_string(args, "tool"))
  use language_filter <- result.try(decode_optional_string(args, "language"))

  let session_snapshot = session_overrides.snapshot()
  let toml_snapshot = config.cached().tool_config

  let session_section =
    render_session_overrides(session_snapshot, tool_filter)
  let toml_section = render_toml_overrides(toml_snapshot, tool_filter)
  let summary_section = case tool_filter, language_filter {
    Some(t), Some(l) ->
      ",\"effective_summary\":"
      <> render_effective_summary(t, Some(l), session_snapshot, toml_snapshot)
    Some(t), None ->
      ",\"effective_summary\":"
      <> render_effective_summary(t, None, session_snapshot, toml_snapshot)
    _, _ -> ""
  }

  Ok(
    "{\"session_overrides\":"
      <> session_section
      <> ",\"toml_overrides\":"
      <> toml_section
      <> summary_section
      <> "}",
  )
}

fn render_session_overrides(
  snapshot: dict.Dict(String, session_overrides.ToolOverride),
  tool_filter: Option(String),
) -> String {
  let entries =
    snapshot
    |> dict.to_list
    |> list.filter(fn(pair) {
      let #(name, _) = pair
      case tool_filter {
        None -> True
        Some(t) -> name == t
      }
    })
    |> list.map(fn(pair) {
      let #(name, ovr) = pair
      let global_part = case ovr.global {
        None -> "null"
        Some(n) -> int.to_string(n)
      }
      let langs_part =
        ovr.languages
        |> dict.to_list
        |> list.map(fn(lp) {
          let #(lang, ms) = lp
          "\"" <> lang <> "\":" <> int.to_string(ms)
        })
        |> string_join(",")
      "\""
      <> name
      <> "\":{\"global\":"
      <> global_part
      <> ",\"languages\":{"
      <> langs_part
      <> "}}"
    })
    |> string_join(",")
  "{" <> entries <> "}"
}

fn render_toml_overrides(
  snapshot: dict.Dict(String, config.ToolConfig),
  tool_filter: Option(String),
) -> String {
  let entries =
    snapshot
    |> dict.to_list
    |> list.filter(fn(pair) {
      let #(name, _) = pair
      case tool_filter {
        None -> True
        Some(t) -> name == t
      }
    })
    |> list.map(fn(pair) {
      let #(name, tc) = pair
      let global_part = case tc.default_timeout_ms {
        None -> "null"
        Some(n) -> int.to_string(n)
      }
      let langs_part =
        tc.languages
        |> dict.to_list
        |> list.map(fn(lp) {
          let #(lang, sub) = lp
          let sub_global = case sub.default_timeout_ms {
            None -> "null"
            Some(n) -> int.to_string(n)
          }
          "\"" <> lang <> "\":" <> sub_global
        })
        |> string_join(",")
      "\""
      <> name
      <> "\":{\"default_timeout_ms\":"
      <> global_part
      <> ",\"languages\":{"
      <> langs_part
      <> "}}"
    })
    |> string_join(",")
  "{" <> entries <> "}"
}

fn render_effective_summary(
  tool: String,
  lang: Option(String),
  session_snapshot: dict.Dict(String, session_overrides.ToolOverride),
  toml_snapshot: dict.Dict(String, config.ToolConfig),
) -> String {
  // Walk the same precedence stack as resolve_tool_timeout but
  // also report which layer won.
  let session_hit = session_overrides.get(tool, lang)
  let toml_hit = case dict.get(toml_snapshot, tool) {
    Error(_) -> None
    Ok(tc) -> {
      let per_lang = case lang {
        None -> None
        Some(l) ->
          case dict.get(tc.languages, l) {
            Ok(sub) -> sub.default_timeout_ms
            Error(_) -> None
          }
      }
      case per_lang {
        Some(_) -> per_lang
        None -> tc.default_timeout_ms
      }
    }
  }
  // Strip unused snapshot args (Gleam warns otherwise) — they were
  // passed in case the caller wanted to render layer-by-layer in
  // the future without re-fetching.
  let _ = session_snapshot
  let _ = toml_snapshot
  let #(value, source) = case session_hit, toml_hit {
    Some(n), _ -> #(int.to_string(n), "session_override")
    None, Some(n) -> #(int.to_string(n), "toml")
    None, None -> #("null", "compile_default")
  }
  let lang_part = case lang {
    Some(l) -> "\"" <> l <> "\""
    None -> "null"
  }
  "{\"tool\":\""
  <> tool
  <> "\",\"language\":"
  <> lang_part
  <> ",\"timeout_ms\":"
  <> value
  <> ",\"source\":\""
  <> source
  <> "\"}"
}

// -- runtime_lsp_state ---------------------------------------------------

fn runtime_lsp_state_definition() -> Json {
  json.object([
    #("name", json.string("runtime_lsp_state")),
    #(
      "description",
      json.string(
        "Snapshot every LSP pharos is tracking — both in-flight spawns "
          <> "(Spawning / Probing) and finished entries (Ready / Failed). "
          <> "ADR-024. Per cache key `(language, workspace, server_id)` "
          <> "returns the current state, spawn timestamp, probe attempt "
          <> "count, and last probe error if any. Useful for diagnosing "
          <> "slow first calls (is the LSP still warming?) or stuck "
          <> "spawners (Failed with a reason). No side effects.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ]),
    ),
  ])
}

fn handle_lsp_state(pool: Pool) -> ToolResult {
  let snap = pool.snapshot(pool)
  let pool.PoolSnapshot(
    entries: entries,
    mailbox_len: mailbox_len,
    inflight_key_count: inflight_keys,
    inflight_waiter_total: inflight_waiters,
    spawner_monitor_count: spawner_monitors,
    lsp_child_monitor_count: child_monitors,
    cache_size: cache_size,
  ) = snap
  let payload =
    json.object([
      #(
        "pool",
        json.object([
          #("mailbox_len", json.int(mailbox_len)),
          #("inflight_key_count", json.int(inflight_keys)),
          #("inflight_waiter_total", json.int(inflight_waiters)),
          #("spawner_monitor_count", json.int(spawner_monitors)),
          #("lsp_child_monitor_count", json.int(child_monitors)),
          #("cache_size", json.int(cache_size)),
        ]),
      ),
      #("entries", json.array(entries, of: lsp_state_entry_to_json)),
    ])
    |> json.to_string
  Ok(payload)
}

fn lsp_state_entry_to_json(entry: pool.LspStateEntry) -> Json {
  let pool.LspStateEntry(
    language: language,
    workspace: workspace,
    server_id: server_id,
    state: state,
    spawned_at_unix_ms: spawned_at,
    probe_attempts: attempts,
    last_probe_error: maybe_err,
    inflight_waiters: inflight_waiters,
    pid: maybe_pid,
  ) = entry
  let #(state_label, state_reason) = case state {
    pool.Spawning -> #("Spawning", None)
    pool.Probing -> #("Probing", None)
    pool.Ready -> #("Ready", None)
    pool.Failed(reason) -> #("Failed", Some(reason))
  }
  let last_err = case maybe_err {
    Some(s) -> json.string(s)
    None -> json.null()
  }
  let reason = case state_reason {
    Some(s) -> json.string(s)
    None -> json.null()
  }
  let pid_json = case maybe_pid {
    Some(p) -> json.string(p)
    None -> json.null()
  }
  json.object([
    #("language", json.string(language)),
    #("workspace", json.string(workspace)),
    #("server_id", json.string(server_id)),
    #("state", json.string(state_label)),
    #("state_reason", reason),
    #("spawned_at_unix_ms", json.int(spawned_at)),
    #("probe_attempts", json.int(attempts)),
    #("last_probe_error", last_err),
    #("inflight_waiters", json.int(inflight_waiters)),
    #("pid", pid_json),
  ])
}

// -- runtime_pool_recon --------------------------------------------------

const default_pool_recon_top_n: Int = 20

fn runtime_pool_recon_definition() -> Json {
  json.object([
    #("name", json.string("runtime_pool_recon")),
    #(
      "description",
      json.string(
        "Pool-actor BEAM-level diagnostics. Returns the pool process's "
          <> "current mailbox depth, memory, current_function, and "
          <> "(best-effort) sys:get_state dump; plus the top-N BEAM "
          <> "processes by mailbox length and stacktraces for every "
          <> "in-flight spawn worker. Use to diagnose pool-blocked "
          <> "spawn cascades and to see where spawners are parked "
          <> "when many gets queue. ADR-024 follow-up. Read-only.",
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
              "top_n",
              json.object([
                #("type", json.string("integer")),
                #("minimum", json.int(1)),
                #("default", json.int(default_pool_recon_top_n)),
                #(
                  "description",
                  json.string(
                    "Limit on the number of top-mailbox processes returned.",
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

fn handle_pool_recon(arguments: Option(Dynamic)) -> ToolResult {
  let top_n = case arguments {
    None -> default_pool_recon_top_n
    Some(args) -> {
      let decoder = {
        use value <- decode.optional_field(
          "top_n",
          default_pool_recon_top_n,
          decode.int,
        )
        decode.success(value)
      }
      case decode.run(args, decoder) {
        Ok(n) -> n
        Error(_) -> default_pool_recon_top_n
      }
    }
  }
  let diag = ffi_pool_diag(top_n)
  Ok(pool_diag_to_json(diag))
}

type PoolInfoRow {
  PoolInfoRow(
    pid: String,
    name: String,
    mailbox_len: Int,
    memory: Int,
    current_function: String,
    status: String,
  )
}

type TopProc {
  TopProc(
    pid: String,
    name: String,
    mailbox_len: Int,
    memory: Int,
    current_function: String,
  )
}

type SpawnerTrace {
  SpawnerTrace(pid: String, current_function: String, stack: String)
}

type PoolDiag {
  PoolDiag(
    pool: PoolInfoRow,
    top_mailboxes: List(TopProc),
    pool_state_dump: String,
    spawners: List(SpawnerTrace),
  )
}

@external(erlang, "pharos_runtime_ffi", "pool_diag")
fn ffi_pool_diag(top_n: Int) -> PoolDiag

fn pool_diag_to_json(d: PoolDiag) -> String {
  let PoolDiag(pool: p, top_mailboxes: top, pool_state_dump: dump, spawners: spawners) =
    d
  json.object([
    #("pool", pool_info_to_json(p)),
    #("top_mailboxes", json.array(top, of: top_proc_to_json)),
    #("pool_state_dump", json.string(dump)),
    #("spawners", json.array(spawners, of: spawner_to_json)),
  ])
  |> json.to_string
}

fn pool_info_to_json(p: PoolInfoRow) -> Json {
  let PoolInfoRow(
    pid: pid,
    name: name,
    mailbox_len: mq,
    memory: mem,
    current_function: cur,
    status: status,
  ) = p
  json.object([
    #("pid", json.string(pid)),
    #("registered_name", json.string(name)),
    #("mailbox_len", json.int(mq)),
    #("memory_bytes", json.int(mem)),
    #("current_function", json.string(cur)),
    #("status", json.string(status)),
  ])
}

fn top_proc_to_json(p: TopProc) -> Json {
  let TopProc(
    pid: pid,
    name: name,
    mailbox_len: mq,
    memory: mem,
    current_function: cur,
  ) = p
  json.object([
    #("pid", json.string(pid)),
    #("registered_name", json.string(name)),
    #("mailbox_len", json.int(mq)),
    #("memory_bytes", json.int(mem)),
    #("current_function", json.string(cur)),
  ])
}

fn spawner_to_json(s: SpawnerTrace) -> Json {
  let SpawnerTrace(pid: pid, current_function: cur, stack: stack) = s
  json.object([
    #("pid", json.string(pid)),
    #("current_function", json.string(cur)),
    #("stack", json.string(stack)),
  ])
}

// -- runtime_server_capabilities ----------------------------------------

fn runtime_server_capabilities_definition() -> Json {
  json.object([
    #("name", json.string("runtime_server_capabilities")),
    #(
      "description",
      json.string(
        "Snapshot the LSP `ServerCapabilities` for every Ready session "
          <> "pharos is tracking. Per active `(language, workspace, "
          <> "server_id)`, returns the verbatim `capabilities` object the "
          <> "server advertised during `initialize` — the canonical record "
          <> "of which standard LSP methods this server implements "
          <> "(hoverProvider, callHierarchyProvider, codeActionProvider, "
          <> "etc.). Use to discover whether a method is reachable via "
          <> "`lsp_request_raw` before constructing the call. Server-"
          <> "specific extension methods (e.g. `rust-analyzer/expandMacro`, "
          <> "`java/classFileContents`) are NOT advertised here — they "
          <> "exist outside the LSP capability schema. Read-only.",
      ),
    ),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ]),
    ),
  ])
}

fn handle_server_capabilities(pool: Pool) -> ToolResult {
  let snap = pool.snapshot(pool)
  let session_lines =
    snap.entries
    |> list.filter_map(ready_entry_to_capabilities_json)
  let joined = string.join(session_lines, ",")
  Ok("{\"sessions\":[" <> joined <> "]}")
}

fn ready_entry_to_capabilities_json(
  entry: pool.LspStateEntry,
) -> Result(String, Nil) {
  case entry.state, entry.pid {
    pool.Ready, Some(pid_text) -> {
      use pid <- result.try(runtime.parse_pid(pid_text))
      use caps <- result.try(lsp_capabilities.lookup_by_pid(pid))
      Ok(
        "{\"language\":"
        <> json.to_string(json.string(entry.language))
        <> ",\"workspace\":"
        <> json.to_string(json.string(entry.workspace))
        <> ",\"server_id\":"
        <> json.to_string(json.string(entry.server_id))
        <> ",\"pid\":"
        <> json.to_string(json.string(pid_text))
        <> ",\"capabilities\":"
        <> tool_helpers.json_encode(caps)
        <> "}",
      )
    }
    _, _ -> Error(Nil)
  }
}
