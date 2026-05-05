//// Log entry types and rendering.
////
//// One `LogEntry` per call to `pharos/log.{debug,info,warn,error}`.
//// The writer actor formats it once, then fans the rendered line out
//// to every enabled sink (stderr, ring buffer, future file). Sinks
//// share the same formatted string so log lines look identical
//// across destinations.
////
//// Format is human-first, grep-second: timestamp, level, target,
//// optional `cid=<id>`, message in quotes, fields as `key=value`
//// pairs separated by spaces. Values containing whitespace or `"`
//// are quoted. JSON output is not a goal — clip-then-grep beats jq
//// at this scale.

import gleam/list
import gleam/string

pub type Level {
  Debug
  Info
  Warn
  Critical
}

pub type LogEntry {
  LogEntry(
    timestamp_ms: String,
    level: Level,
    target: String,
    correlation_id: String,
    message: String,
    fields: List(#(String, String)),
  )
}

pub fn level_to_string(level: Level) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Warn -> "warn"
    Critical -> "error"
  }
}

pub fn level_rank(level: Level) -> Int {
  case level {
    Debug -> 0
    Info -> 1
    Warn -> 2
    Critical -> 3
  }
}

/// Parse a level name. Recognises `"debug"`, `"info"`, `"warn"`,
/// `"error"`. The `off` keyword is filter-layer concern, not parsed
/// here.
pub fn parse_level(raw: String) -> Result(Level, Nil) {
  case string.lowercase(string.trim(raw)) {
    "debug" -> Ok(Debug)
    "info" -> Ok(Info)
    "warn" -> Ok(Warn)
    "warning" -> Ok(Warn)
    "error" -> Ok(Critical)
    _ -> Error(Nil)
  }
}

/// Render an entry to its single-line stderr/ring representation.
/// Trailing newline is the writer's responsibility.
pub fn render(entry: LogEntry) -> String {
  let head =
    entry.timestamp_ms
    <> " "
    <> string.pad_end(level_to_string(entry.level), to: 5, with: " ")
    <> " "
    <> entry.target

  let cid = case entry.correlation_id {
    "" -> ""
    id -> " cid=" <> id
  }

  let msg = " msg=" <> quote(entry.message)

  let fields =
    entry.fields
    |> list.map(fn(pair) {
      let #(key, value) = pair
      " " <> key <> "=" <> quote(value)
    })
    |> string.concat

  head <> cid <> msg <> fields
}

fn quote(value: String) -> String {
  case needs_quoting(value) {
    False -> value
    True -> "\"" <> escape(value) <> "\""
  }
}

fn needs_quoting(value: String) -> Bool {
  case value {
    "" -> True
    _ ->
      string.contains(value, " ")
      || string.contains(value, "\"")
      || string.contains(value, "=")
      || string.contains(value, "\n")
  }
}

fn escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}
