//// What a pharos.toml may contain, and a check of a parsed file against
//// it (#32).
////
//// `pharos/config` decodes each key by name and treats anything else as
//// absent, so a misspelled key, a value of the wrong type, a value out of
//// range or a table missing what it needs used to do nothing and say
//// nothing. `check/2` walks the parsed document against the known keys of
//// each table (top level, `[server]`, `[log]`, `[lsp]`, `[runtime]`,
//// `[bridge]`, `[languages.<id>]`, `[[languages.<id>.servers]]`,
//// `custom_uri_schemes`, `[tool_config.<name>]`) and returns one `Problem`
//// per stray key, wrongly typed or invalid value, unknown tool or language
//// name, and missing required key. It changes nothing about how the file
//// is applied: `config` still does with each value what it did, and now
//// says so (a `BadValue` names what that is).
////
//// The key lists here and the decoders in `pharos/config` must agree. A
//// key `config` decodes but this module doesn't list warns on every use,
//// which the example-config test catches; a key listed here but not
//// decoded goes silent again, which review has to catch.
////
//// Older names stay accepted without a warning, so configs written for
//// earlier releases don't start warning: `readiness_timeout_ms` (renamed
//// `ready_timeout_ms` by ADR-024; `config` still reads it).

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import pharos/log/filter
import pharos/lsp/languages
import pharos/tools/names

pub type Problem {
  /// `key` is the dotted path from the top of the file; `suggestion` is
  /// the closest known key in the same table, when one is close.
  UnknownKey(key: String, suggestion: Option(String))
  /// `expected` and `got` are phrases: "an integer", "a string".
  WrongType(key: String, expected: String, got: String)
  /// A name pharos doesn't know, where the name itself is the setting: a
  /// tool in `[tool_config.<name>]`, a language in
  /// `[tool_config.<name>.<lang>]`, an entry of `tools = [...]`. `kind`
  /// says which.
  UnknownName(
    key: String,
    name: String,
    kind: String,
    suggestion: Option(String),
  )
  /// The right type but a value pharos can't use as meant. `effect` says
  /// what pharos does with it instead ("read as push", "ignored").
  BadValue(key: String, value: String, expected: String, effect: String)
  /// A table without a key it needs; `effect` says what follows.
  MissingKey(key: String, missing: String, effect: String)
  /// A key that belongs in another table: `belongs` names it.
  MisplacedKey(key: String, belongs: String)
  /// A key pharos accepts but doesn't act on; `why` says so.
  NotUsed(key: String, why: String)
}

/// The shape a value must have.
type Shape {
  Str
  /// Any value; the key is accepted but does nothing.
  Unused(why: String)
  /// A string that must not be empty.
  NonEmptyStr(effect: String)
  /// A string from a fixed set, compared as written or (for `transport`)
  /// trimmed and lowercased, as `config` reads it.
  OneOf(accepted: List(String), fold: Bool, expected: String, effect: String)
  Integer
  IntAtLeast(min: Int, effect: String)
  IntBetween(min: Int, max: Int, effect: String)
  Boolean
  StrList
  /// `file_extensions`: strings, none of them empty.
  Extensions
  /// `tools = [...]`: tool names, categories or presets.
  ToolFilter
  /// `[log] filter`: clauses `log/filter` can parse.
  LogFilter
  /// A table whose values are all strings (`document_language_ids`).
  StrTable
  /// A table with exactly these keys.
  Table(fields: List(#(String, Shape)))
  /// A table with any keys, every value of this shape.
  TableOf(Shape)
  /// A table of this shape that must hold these keys: (key, effect).
  Requiring(Shape, required: List(#(String, String)))
  /// An array of tables, every element of this shape.
  ArrayOf(Shape)
  /// `[languages]`: a language table per id, with the keys a language or
  /// server new to pharos needs.
  Languages
  /// `[tool_config]`: a table per tool name, holding `default_timeout_ms`
  /// and a table per language id.
  ToolConfig
}

/// What a check knows besides the document: the bundled languages and
/// their servers, and the languages earlier config files defined (the
/// global file, when checking the project one).
type Context {
  Context(
    bundled: List(#(String, List(String))),
    earlier: List(String),
    /// The server ids earlier files defined, per language.
    earlier_servers: List(#(String, List(String))),
    tools: List(String),
  )
}

/// Every problem in a parsed pharos.toml, in file-path order. `earlier`
/// holds the languages config files read before this one defined, each
/// with the server ids they defined for it, so a language or server added
/// there isn't reported as new here.
pub fn check(
  document: Dynamic,
  earlier: List(#(String, List(String))),
) -> List(Problem) {
  let earlier_languages = list.map(earlier, fn(pair) { pair.0 })
  let bundled =
    languages.default_registry()
    |> dict.to_list
    |> list.map(fn(pair) {
      let #(id, language) = pair
      #(id, list.map(language.servers, fn(server) { server.id }))
    })
  let context =
    Context(
      bundled: bundled,
      earlier: earlier_languages,
      earlier_servers: earlier,
      tools: names.all(),
    )
  check_value(context, "", top_level(), document)
}

// -- The known keys -------------------------------------------------------

const ignored = "ignored"

fn top_level() -> Shape {
  Table([
    #(
      "transport",
      OneOf(
        ["stdio", "http", "both"],
        True,
        "stdio, http or both",
        "ignored; the transport stays as it was",
      ),
    ),
    #("tools", ToolFilter),
    #(
      "server",
      Table([
        #(
          "transport",
          OneOf(
            ["stdio", "http", "both"],
            True,
            "stdio, http or both",
            "ignored; the transport stays as it was",
          ),
        ),
        #(
          "http",
          Table([
            #("port", IntBetween(0, 65_535, "the HTTP listener can't bind")),
            #("bind", NonEmptyStr(ignored)),
            #("port_file", NonEmptyStr(ignored)),
          ]),
        ),
      ]),
    ),
    #(
      "log",
      Table([
        #("filter", LogFilter),
        #("file", NonEmptyStr(ignored)),
        #("ring", Boolean),
        #("stderr", Boolean),
        #("file_max_bytes", IntAtLeast(1, ignored)),
        #("file_keep_rotated", IntAtLeast(0, ignored)),
      ]),
    ),
    #("lsp", Table([#("trace", Boolean)])),
    #("runtime", Table([#("trace_calls_enabled", Boolean)])),
    // Still decoded, so older configs load, but nothing reads it: the
    // editor extension's listener (M7) isn't built.
    #(
      "bridge",
      Table([
        #(
          "port",
          Unused(
            "nothing reads it yet: the editor-extension listener isn't built",
          ),
        ),
      ]),
    ),
    #("languages", Languages),
    #("tool_config", ToolConfig),
  ])
}

/// Keys a `[[languages.<id>.servers]]` entry and the flat
/// `[languages.<id>]` shape share: the flat ones patch the primary server.
fn server_keys() -> List(#(String, Shape)) {
  let ready = IntAtLeast(1, "the readiness wait ends at once")
  let off = IntAtLeast(0, "read as 0 (off)")
  [
    #("id", Str),
    #("command", NonEmptyStr("the server can't start")),
    #("args", StrList),
    #(
      "diagnostics_mode",
      OneOf(
        [
          "push", "Push", "PUSH", "pull", "Pull", "PULL", "tsserver", "Tsserver",
          "TSSERVER",
        ],
        False,
        "push, pull or tsserver",
        "ignored; the bundled mode stays",
      ),
    ),
    #("readiness_token", Str),
    #("ready_timeout_ms", ready),
    // ADR-024's old name for ready_timeout_ms, still read.
    #("readiness_timeout_ms", ready),
    #(
      "initialize_timeout_ms",
      IntAtLeast(1, "ignored; the bundled timeout stays"),
    ),
    #("lazy_workspace_index_ms", off),
    #("save_check_grace_ms", off),
    #("publish_settle_ms", off),
    #("empty_publish_settle_ms", off),
    #("open_settle_ms", off),
    #("silence_settle_ms", off),
    #("silence_open_floor_ms", off),
    #("empty_after_close_is_clear", Boolean),
    #("full_change_as_range", Boolean),
    #("generic_names_carry_params", Boolean),
    #("workspace_symbol_modules_only", Boolean),
    #("pull_after_change_ms", off),
    #(
      "position_encoding",
      OneOf(
        ["utf-8", "utf-16", "utf-32"],
        True,
        "utf-8, utf-16 or utf-32",
        "ignored; UTF-16 stays",
      ),
    ),
    #(
      "returned_position_encoding",
      OneOf(
        ["utf-8", "utf-16", "utf-32"],
        True,
        "utf-8, utf-16 or utf-32",
        "ignored; UTF-16 stays",
      ),
    ),
    #("watch_files", Boolean),
    #("initialization_options_json", Str),
    #("workspace_configuration_json", Str),
  ]
}

fn server() -> Shape {
  Table([#("methods", StrList), ..server_keys()])
}

fn language() -> Shape {
  Table(list.append(server_keys(), language_fields()))
}

/// The keys only a `[languages.<id>]` table has.
fn language_fields() -> List(#(String, Shape)) {
  [
    #("file_extensions", Extensions),
    #("document_language_ids", StrTable),
    #("root_markers", StrList),
    #("vendor_segments", StrList),
    #("dependency_cache_fragments", StrList),
    #("env_keys", StrList),
    #("idle_stop_secs", IntAtLeast(0, "ignored; the bundled idle limit stays")),
    #("servers", ArrayOf(server())),
    #(
      "custom_uri_schemes",
      TableOf(
        Requiring(
          Table([
            #("fetch_method", NonEmptyStr("fetches through the scheme fail")),
            #("fetch_response_field", Str),
          ]),
          [#("fetch_method", "the scheme is ignored")],
        ),
      ),
    ),
  ]
}

fn tool_language_block() -> Shape {
  Table([#("default_timeout_ms", tool_timeout())])
}

fn tool_timeout() -> Shape {
  IntAtLeast(1, "ignored; the tool's built-in default stays")
}

// -- The walk -------------------------------------------------------------

fn check_value(
  context: Context,
  path: String,
  shape: Shape,
  value: Dynamic,
) -> List(Problem) {
  case shape {
    Str -> expect(path, value, is_string(value), "a string")
    Unused(why) -> [NotUsed(path, why)]
    NonEmptyStr(effect) ->
      case as_string(value) {
        Error(_) -> [WrongType(path, "a string", kind(value))]
        Ok("") -> [BadValue(path, "", "not empty", effect)]
        Ok(_) -> []
      }
    OneOf(accepted, fold, expected, effect) ->
      case as_string(value) {
        Error(_) -> [WrongType(path, "a string", kind(value))]
        Ok(text) -> {
          let compared = case fold {
            True -> string.lowercase(string.trim(text))
            False -> text
          }
          case list.contains(accepted, compared) {
            True -> []
            False -> [BadValue(path, text, expected, effect)]
          }
        }
      }
    Integer -> expect(path, value, is_int(value), "an integer")
    IntAtLeast(min, effect) ->
      case as_int(value) {
        Error(_) -> [WrongType(path, "an integer", kind(value))]
        Ok(n) if n < min -> [
          BadValue(path, int.to_string(n), at_least(min), effect),
        ]
        Ok(_) -> []
      }
    IntBetween(min, max, effect) ->
      case as_int(value) {
        Error(_) -> [WrongType(path, "an integer", kind(value))]
        Ok(n) if n < min || n > max -> [
          BadValue(
            path,
            int.to_string(n),
            int.to_string(min) <> " to " <> int.to_string(max),
            effect,
          ),
        ]
        Ok(_) -> []
      }
    Boolean -> expect(path, value, is_bool(value), "true or false")
    StrList ->
      case string_list(path, value) {
        Ok(_) -> []
        Error(problem) -> [problem]
      }
    Extensions ->
      case string_list(path, value) {
        Error(problem) -> [problem]
        Ok(items) ->
          case list.contains(items, ""), list.all(items, fn(e) { e == "" }) {
            False, _ -> []
            True, False -> [
              BadValue(
                path,
                "",
                "no empty entry",
                "dropped; the other extensions stay",
              ),
            ]
            // Nothing valid left: the whole list is ignored, as `config`
            // does, rather than leaving the language no extension.
            True, True -> [
              BadValue(
                path,
                "",
                "no empty entry",
                ignored_extensions_effect(context, path),
              ),
            ]
          }
      }
    ToolFilter ->
      case string_list(path, value) {
        Error(problem) -> [problem]
        Ok(items) -> {
          let known = list.append(context.tools, names.filter_aliases())
          let unknown =
            list.filter_map(items, fn(item) {
              case list.contains(known, item) {
                True -> Error(Nil)
                False ->
                  Ok(UnknownName(
                    path,
                    item,
                    "tool, category or preset",
                    closest(item, known),
                  ))
              }
            })
          // `config` ignores a list with no valid entry: it would expose
          // no tools at all. An explicit `[]` is taken as written.
          case items != [] && list.length(unknown) == list.length(items) {
            False -> unknown
            True ->
              list.append(unknown, [
                BadValue(
                  path,
                  string.join(items, ", "),
                  "at least one tool, category or preset",
                  "ignored; the earlier setting stays (\"default\" unless an earlier file set it)",
                ),
              ])
          }
        }
      }
    LogFilter ->
      case as_string(value) {
        Error(_) -> [WrongType(path, "a string", kind(value))]
        Ok(spec) ->
          list.map(filter.unparsed_clauses(spec), fn(clause) {
            BadValue(
              path,
              clause,
              "a level (debug, info, warn, error) or target=level (or =off)",
              "skipped",
            )
          })
      }
    StrTable ->
      case as_table(value) {
        Error(_) -> [WrongType(path, "a table of strings", kind(value))]
        Ok(entries) ->
          list.flat_map(entries, fn(entry) {
            expect(join(path, entry.0), entry.1, is_string(entry.1), "a string")
          })
      }
    Table(fields) ->
      case as_table(value) {
        Error(_) -> [WrongType(path, "a table", kind(value))]
        Ok(entries) ->
          list.flat_map(entries, fn(entry) {
            let #(key, sub) = entry
            case list.key_find(fields, key) {
              Ok(sub_shape) ->
                check_value(context, join(path, key), sub_shape, sub)
              Error(_) -> [
                UnknownKey(
                  join(path, key),
                  closest(key, list.map(fields, fn(f) { f.0 })),
                ),
              ]
            }
          })
      }
    TableOf(inner) ->
      case as_table(value) {
        Error(_) -> [WrongType(path, "a table", kind(value))]
        Ok(entries) ->
          list.flat_map(entries, fn(entry) {
            check_value(context, join(path, entry.0), inner, entry.1)
          })
      }
    Requiring(inner, required) -> {
      let found = check_value(context, path, inner, value)
      case as_table(value) {
        Error(_) -> found
        Ok(entries) ->
          list.append(
            found,
            list.filter_map(required, fn(pair) {
              case list.key_find(entries, pair.0) {
                Ok(_) -> Error(Nil)
                Error(_) -> Ok(MissingKey(path, pair.0, pair.1))
              }
            }),
          )
      }
    }
    ArrayOf(inner) ->
      case as_list(value) {
        Error(_) -> [WrongType(path, "an array of tables", kind(value))]
        Ok(items) ->
          list.index_map(items, fn(item, i) {
            check_value(context, index(path, i), inner, item)
          })
          |> list.flatten
      }
    Languages ->
      case as_table(value) {
        Error(_) -> [WrongType(path, "a table", kind(value))]
        Ok(entries) ->
          list.flat_map(entries, fn(entry) {
            let #(id, body) = entry
            let at = join(path, id)
            list.append(
              check_value(context, at, language(), body)
                |> list.map(misplaced(_, id)),
              language_requirements(context, id, at, body),
            )
          })
      }
    ToolConfig ->
      case as_table(value) {
        Error(_) -> [WrongType(path, "a table", kind(value))]
        Ok(entries) ->
          list.flat_map(entries, fn(entry) {
            let #(tool, body) = entry
            let at = join(path, tool)
            let name = case list.contains(context.tools, tool) {
              True -> []
              False -> [
                UnknownName(at, tool, "tool", closest(tool, context.tools)),
              ]
            }
            list.append(name, tool_table(context, at, body))
          })
      }
  }
}

/// An unknown key in a language table that is a server-only key
/// (`methods`), or one in a `[[servers]]` entry that is a language-level
/// key (`file_extensions`), is in the wrong table: say which one.
fn misplaced(problem: Problem, id: String) -> Problem {
  case problem {
    UnknownKey(key, _) -> {
      let last = case list.last(string.split(key, ".")) {
        Ok(segment) -> segment
        Error(_) -> key
      }
      let in_server = string.contains(key, ".servers[")
      let language_only =
        list.filter_map(language_fields(), fn(field) {
          case list.key_find(server_keys(), field.0) {
            Ok(_) -> Error(Nil)
            Error(_) -> Ok(field.0)
          }
        })
      let languages_id = join("languages", id)
      case in_server, last {
        False, "methods" ->
          MisplacedKey(key, "[[" <> languages_id <> ".servers]]")
        True, _ ->
          case list.contains(language_only, last) {
            True -> MisplacedKey(key, "[" <> languages_id <> "]")
            False -> problem
          }
        False, _ -> problem
      }
    }
    _ -> problem
  }
}

/// `[tool_config.<name>]`'s body: `default_timeout_ms`, and a table per
/// language id. A scalar under any other key is a stray key.
fn tool_table(context: Context, path: String, value: Dynamic) -> List(Problem) {
  case as_table(value) {
    Error(_) -> [WrongType(path, "a table", kind(value))]
    Ok(entries) ->
      list.flat_map(entries, fn(entry) {
        let #(key, sub) = entry
        let at = join(path, key)
        case key, as_table(sub) {
          "default_timeout_ms", _ ->
            check_value(context, at, tool_timeout(), sub)
          // A per-language block. Whether the language exists is checked
          // once every config file is read (`config`), since a language
          // the project file adds can be named in the global one.
          _, Ok(_) -> check_value(context, at, tool_language_block(), sub)
          _, Error(_) -> [UnknownKey(at, closest(key, ["default_timeout_ms"]))]
        }
      })
  }
}

/// What a language or server new to pharos must say, since nothing
/// bundled fills it in: a language needs a `command` and
/// `file_extensions`; a `[[servers]]` entry needs an `id` (one without is
/// skipped), and a server new to the language needs a `command`.
fn language_requirements(
  context: Context,
  id: String,
  path: String,
  value: Dynamic,
) -> List(Problem) {
  case as_table(value) {
    Error(_) -> []
    Ok(entries) -> {
      let bundled_servers = list.key_find(context.bundled, id)
      let new_language =
        bundled_servers == Error(Nil) && !list.contains(context.earlier, id)
      let servers = case list.key_find(entries, "servers") {
        Ok(raw) ->
          case as_list(raw) {
            Ok(items) -> items
            Error(_) -> []
          }
        Error(_) -> []
      }
      let flat_command = has_key(entries, "command")
      let known_servers =
        list.append(
          case bundled_servers {
            Ok(ids) -> ids
            Error(_) -> []
          },
          case list.key_find(context.earlier_servers, id) {
            Ok(ids) -> ids
            Error(_) -> []
          },
        )
      let server_problems =
        list.index_map(servers, fn(item, i) {
          case as_table(item) {
            Error(_) -> []
            Ok(fields) -> {
              let at = index(join(path, "servers"), i)
              case list.key_find(fields, "id") {
                Error(_) -> [MissingKey(at, "id", "the entry is ignored")]
                Ok(server_id) ->
                  case
                    has_key(fields, "command")
                    || { i == 0 && flat_command }
                    || list.contains(known_servers, dynamic_text(server_id))
                  {
                    True -> []
                    False -> [
                      MissingKey(at, "command", "the server can't start"),
                    ]
                  }
              }
            }
          }
        })
        |> list.flatten
      let language_problems = case new_language {
        False -> []
        True ->
          list.flatten([
            case flat_command || servers != [] {
              True -> []
              False -> [
                MissingKey(
                  path,
                  "command",
                  "the language has no server to start",
                ),
              ]
            },
            case has_key(entries, "file_extensions") {
              True -> []
              False -> [
                MissingKey(
                  path,
                  "file_extensions",
                  "no file is routed to the language",
                ),
              ]
            },
          ])
      }
      list.append(language_problems, server_problems)
    }
  }
}

fn expect(
  path: String,
  value: Dynamic,
  ok: Bool,
  expected: String,
) -> List(Problem) {
  case ok {
    True -> []
    False -> [WrongType(path, expected, kind(value))]
  }
}

fn string_list(path: String, value: Dynamic) -> Result(List(String), Problem) {
  case as_list(value) {
    Error(_) -> Error(WrongType(path, "an array of strings", kind(value)))
    Ok(items) ->
      case list.find(items, fn(item) { !is_string(item) }) {
        Ok(item) ->
          Error(WrongType(
            path,
            "an array of strings",
            "an array holding " <> kind(item),
          ))
        Error(_) -> Ok(list.filter_map(items, as_string))
      }
  }
}

fn at_least(min: Int) -> String {
  case min {
    0 -> "0 or more"
    _ -> "at least " <> int.to_string(min)
  }
}

/// A dotted path, with a key quoted as TOML would need it
/// (`document_language_ids.".go"`).
fn join(path: String, key: String) -> String {
  let shown = case key != "" && list.all(string.to_graphemes(key), bare_char) {
    True -> key
    False -> "\"" <> key <> "\""
  }
  case path {
    "" -> shown
    _ -> path <> "." <> shown
  }
}

fn bare_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    c,
  )
}

fn index(path: String, i: Int) -> String {
  path <> "[" <> int.to_string(i) <> "]"
}

fn has_key(entries: List(#(String, Dynamic)), key: String) -> Bool {
  case list.key_find(entries, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// A string value as written, or "" for anything else.
fn dynamic_text(value: Dynamic) -> String {
  case as_string(value) {
    Ok(text) -> text
    Error(_) -> ""
  }
}

// -- What a value is ------------------------------------------------------

fn as_string(value: Dynamic) -> Result(String, Nil) {
  decode.run(value, decode.string) |> nil_error
}

fn as_int(value: Dynamic) -> Result(Int, Nil) {
  decode.run(value, decode.int) |> nil_error
}

fn is_string(value: Dynamic) -> Bool {
  as_string(value) |> is_ok
}

fn is_int(value: Dynamic) -> Bool {
  as_int(value) |> is_ok
}

fn is_bool(value: Dynamic) -> Bool {
  decode.run(value, decode.bool) |> is_ok
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn nil_error(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn as_list(value: Dynamic) -> Result(List(Dynamic), Nil) {
  case value_kind(value) {
    "array" -> decode.run(value, decode.list(decode.dynamic)) |> nil_error
    _ -> Error(Nil)
  }
}

/// A table's entries sorted by key, so problems come out in a stable order.
fn as_table(value: Dynamic) -> Result(List(#(String, Dynamic)), Nil) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(table) ->
      Ok(
        dict.to_list(table)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
      )
    Error(_) -> Error(Nil)
  }
}

/// A phrase for what a parsed TOML value is.
fn kind(value: Dynamic) -> String {
  case value_kind(value) {
    "table" -> "a table"
    "array" -> "an array"
    "string" -> "a string"
    "bool" -> "true/false"
    "integer" -> "an integer"
    "float" -> "a decimal number"
    _ -> "a date/time"
  }
}

@external(erlang, "pharos_toml_ffi", "value_kind")
fn value_kind(value: Dynamic) -> String

// -- Suggestions ----------------------------------------------------------

/// The known name nearest `typed` by edit distance, when it is near
/// enough to be a likely misspelling: at most 2 edits, or a quarter of the
/// known name's length for long names.
pub fn closest(typed: String, known: List(String)) -> Option(String) {
  let letters = string.to_graphemes(typed)
  let scored =
    list.map(known, fn(k) { #(k, distance(letters, string.to_graphemes(k))) })
    |> list.filter(fn(pair) { pair.1 <= int.max(2, string.length(pair.0) / 4) })
    |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
  case scored {
    [#(best, _), ..] -> Some(best)
    [] -> None
  }
}

/// Levenshtein distance, one row at a time.
fn distance(a: List(String), b: List(String)) -> Int {
  let first_row = [0, ..list.index_map(b, fn(_, i) { i + 1 })]
  let last_row =
    list.index_fold(a, first_row, fn(previous, char_a, i) {
      next_row(b, char_a, previous, [i + 1], i + 1)
    })
  case list.last(last_row) {
    Ok(d) -> d
    Error(_) -> 0
  }
}

/// Builds the next row; `acc` holds the new row reversed, its head being
/// the cell to the left.
fn next_row(
  b: List(String),
  char_a: String,
  previous: List(Int),
  acc: List(Int),
  left: Int,
) -> List(Int) {
  case b, previous {
    [char_b, ..rest_b], [diagonal, above, ..rest_previous] -> {
      let cost = case char_a == char_b {
        True -> 0
        False -> 1
      }
      let cell = int.min(int.min(left + 1, above + 1), diagonal + cost)
      next_row(rest_b, char_a, [above, ..rest_previous], [cell, ..acc], cell)
    }
    _, _ -> list.reverse(acc)
  }
}

/// What an all-empty `file_extensions` list leaves: a bundled language
/// keeps its bundled extensions; any other has none (a later file's
/// `[languages.<id>]` replaces an earlier one's whole), so it matches no
/// file.
fn ignored_extensions_effect(context: Context, path: String) -> String {
  let id = case string.split(path, ".") {
    ["languages", id, ..] -> id
    _ -> ""
  }
  case list.any(context.bundled, fn(pair) { pair.0 == id }) {
    True -> "ignored; the bundled extensions stay"
    False ->
      "ignored; the language has no bundled extensions, so it matches no file"
  }
}
