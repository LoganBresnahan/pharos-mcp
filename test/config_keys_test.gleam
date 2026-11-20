//// #32: pharos.toml keys `config` doesn't know, and values of the wrong
//// type, are each reported once; everything the docs, the template, the
//// accepted old names and `--print-language-config` write is not.

import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pharos
import pharos/config
import pharos/config_keys.{
  BadValue, MisplacedKey, MissingKey, NotUsed, UnknownKey, UnknownName,
  WrongType,
}
import pharos/lsp/languages
import pharos/lsp/registry
import pharos/lsp/registry_toml
import pharos/mcp/server
import pharos/tools/names

@external(erlang, "pharos_toml_ffi", "parse")
fn toml_parse(input: BitArray) -> Result(Dynamic, String)

@external(erlang, "pharos_fs_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "pharos_runtime_ffi", "first_config_check")
fn first_config_check(path: String, bytes: BitArray, writer_up: Bool) -> Bool

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn problems(text: String) -> List(config_keys.Problem) {
  let assert Ok(parsed) = toml_parse(bit_array.from_string(text))
  config_keys.check(parsed, [])
}

pub fn misspelled_and_wrong_typed_key_warn_once_each_test() {
  problems(
    "[languages.rust]
ready_timeout_msx = 60000
lazy_workspace_index_ms = \"yes\"
",
  )
  |> should.equal([
    WrongType(
      "languages.rust.lazy_workspace_index_ms",
      "an integer",
      "a string",
    ),
    UnknownKey("languages.rust.ready_timeout_msx", Some("ready_timeout_ms")),
  ])
}

pub fn every_known_key_with_its_type_is_quiet_test() {
  problems(
    "transport = \"stdio\"
tools = [\"default\"]

[server]
transport = \"http\"

[server.http]
port = 3535
bind = \"127.0.0.1\"
port_file = \"/tmp/port\"

[log]
filter = \"info\"
file = \"/tmp/pharos.log\"
ring = true
stderr = false
file_max_bytes = 1000000
file_keep_rotated = 3

[lsp]
trace = false

[runtime]
trace_calls_enabled = false

[languages.mylang]
id = \"mylang\"
command = \"mylang-lsp\"
args = [\"--stdio\"]
file_extensions = [\".my\"]
document_language_ids = { \".my\" = \"mylang\" }
root_markers = [\"my.toml\"]
vendor_segments = [\"/vendor/\"]
dependency_cache_fragments = [\"/cache/\"]
env_keys = [\"MY_HOME\"]
idle_stop_secs = 0
diagnostics_mode = \"pull\"
readiness_token = \"indexing\"
initialization_options_json = '{}'
workspace_configuration_json = '{}'
ready_timeout_ms = 1
initialize_timeout_ms = 1
lazy_workspace_index_ms = 1
save_check_grace_ms = 1
full_change_as_range = true
pull_after_change_ms = 1

[[languages.mylang.servers]]
id = \"second\"
command = \"second-lsp\"
args = []
methods = [\"textDocument/hover\"]
diagnostics_mode = \"push\"
readiness_token = \"\"
ready_timeout_ms = 1
initialize_timeout_ms = 1
lazy_workspace_index_ms = 1
save_check_grace_ms = 1
full_change_as_range = false
pull_after_change_ms = 1
initialization_options_json = '{}'
workspace_configuration_json = '{}'

[languages.mylang.custom_uri_schemes.\"my-scheme\"]
fetch_method = \"my/read\"
fetch_response_field = \"text\"

[tool_config.hover]
default_timeout_ms = 1000

[tool_config.hover.mylang]
default_timeout_ms = 2000
",
  )
  |> should.equal([])
}

pub fn old_key_names_are_accepted_quietly_test() {
  problems(
    "[languages.rust]
readiness_timeout_ms = 60000

[[languages.java.servers]]
id = \"jdtls\"
readiness_timeout_ms = 60000
",
  )
  |> should.equal([])
}

pub fn server_entry_problems_name_the_entry_test() {
  problems(
    "[[languages.python.servers]]
id = \"pyright\"

[[languages.python.servers]]
id = \"ruff\"
comand = \"ruff\"
methods = \"textDocument/formatting\"
",
  )
  |> should.equal([
    UnknownKey("languages.python.servers[1].comand", Some("command")),
    WrongType(
      "languages.python.servers[1].methods",
      "an array of strings",
      "a string",
    ),
  ])
}

pub fn tool_config_problems_test() {
  problems(
    "[tool_config.hover]
default_timeout = 5000

[tool_config.find_references]
default_timeout_ms = \"90000\"

[tool_config.find_references.java]
default_timeout_ms = 1.5
",
  )
  |> should.equal([
    WrongType(
      "tool_config.find_references.default_timeout_ms",
      "an integer",
      "a string",
    ),
    WrongType(
      "tool_config.find_references.java.default_timeout_ms",
      "an integer",
      "a decimal number",
    ),
    UnknownKey("tool_config.hover.default_timeout", Some("default_timeout_ms")),
  ])
}

pub fn other_shapes_test() {
  problems(
    "tools = [\"read\", 3]

[logs]
filter = \"debug\"

[server.http]
port = \"3535\"

[languages]
rust = \"rust-analyzer\"

[languages.go]
document_language_ids = { \".go\" = 1 }
servers = { id = \"gopls\" }
full_change_as_range = \"true\"
something_else_entirely = 1
",
  )
  |> should.equal([
    WrongType(
      "languages.go.document_language_ids.\".go\"",
      "a string",
      "an integer",
    ),
    WrongType("languages.go.full_change_as_range", "true or false", "a string"),
    WrongType("languages.go.servers", "an array of tables", "a table"),
    UnknownKey("languages.go.something_else_entirely", None),
    WrongType("languages.rust", "a table", "a string"),
    UnknownKey("logs", Some("log")),
    WrongType("server.http.port", "an integer", "a string"),
    WrongType("tools", "an array of strings", "an array holding an integer"),
  ])
}

pub fn unknown_tool_and_language_names_test() {
  problems(
    "[tool_config.hovr]
default_timeout_ms = 1000

[tool_config.hover.rsut]
default_timeout_ms = 1000

[tool_config.hover.rust.deeper]
default_timeout_ms = 1000
",
  )
  |> should.equal([
    // The language is checked once every file is read
    // (config.unknown_tool_languages).
    UnknownKey("tool_config.hover.rust.deeper", None),
    UnknownName("tool_config.hovr", "hovr", "tool", Some("hover")),
  ])
}

pub fn a_language_an_earlier_file_defined_is_known_test() {
  let assert Ok(parsed) =
    toml_parse(<<
      "[tool_config.hover.mylang]\ndefault_timeout_ms = 1000\n

[languages.mylang]\nsave_check_grace_ms = 1\n",
    >>)
  config_keys.check(parsed, [#("mylang", [])]) |> should.equal([])
}

pub fn tool_names_match_the_registered_tools_test() {
  list.sort(names.all(), string.compare)
  |> should.equal(list.sort(server.registered_tool_names(), string.compare))
}

pub fn invalid_values_of_the_right_type_test() {
  problems(
    "transport = \" HTTP \"
tools = [\"reed\", \"hover\", \"default\"]

[server]
transport = \"htpp\"

[server.http]
port = 70000
bind = \"\"

[log]
filter = \"debgu, pharos/lsp=loud, info\"
file_max_bytes = 0
file_keep_rotated = -1

[languages.ruby]
diagnostics_mode = \"pul\"
initialize_timeout_ms = 0
ready_timeout_ms = -5
idle_stop_secs = -1
lazy_workspace_index_ms = -1
command = \"\"
file_extensions = [\".rb\", \"\"]

[tool_config.hover]
default_timeout_ms = 0
",
  )
  |> should.equal([
    BadValue(
      "languages.ruby.command",
      "",
      "not empty",
      "the server can't start",
    ),
    BadValue(
      "languages.ruby.diagnostics_mode",
      "pul",
      "push, pull or tsserver",
      "ignored; the bundled mode stays",
    ),
    BadValue(
      "languages.ruby.file_extensions",
      "",
      "no empty entry",
      "dropped; the other extensions stay",
    ),
    BadValue(
      "languages.ruby.idle_stop_secs",
      "-1",
      "0 or more",
      "ignored; the bundled idle limit stays",
    ),
    BadValue(
      "languages.ruby.initialize_timeout_ms",
      "0",
      "at least 1",
      "ignored; the bundled timeout stays",
    ),
    BadValue(
      "languages.ruby.lazy_workspace_index_ms",
      "-1",
      "0 or more",
      "read as 0 (off)",
    ),
    BadValue(
      "languages.ruby.ready_timeout_ms",
      "-5",
      "at least 1",
      "the readiness wait ends at once",
    ),
    BadValue("log.file_keep_rotated", "-1", "0 or more", "ignored"),
    BadValue("log.file_max_bytes", "0", "at least 1", "ignored"),
    BadValue(
      "log.filter",
      "debgu",
      "a level (debug, info, warn, error) or target=level (or =off)",
      "skipped",
    ),
    BadValue(
      "log.filter",
      "pharos/lsp=loud",
      "a level (debug, info, warn, error) or target=level (or =off)",
      "skipped",
    ),
    BadValue("server.http.bind", "", "not empty", "ignored"),
    BadValue(
      "server.http.port",
      "70000",
      "0 to 65535",
      "the HTTP listener can't bind",
    ),
    BadValue(
      "server.transport",
      "htpp",
      "stdio, http or both",
      "ignored; the transport stays as it was",
    ),
    BadValue(
      "tool_config.hover.default_timeout_ms",
      "0",
      "at least 1",
      "ignored; the tool's built-in default stays",
    ),
    UnknownName("tools", "reed", "tool, category or preset", Some("read")),
  ])
}

pub fn tools_with_no_valid_entry_test() {
  problems("tools = [\"reed\", \"wirte\"]\n")
  |> should.equal([
    UnknownName("tools", "reed", "tool, category or preset", Some("read")),
    UnknownName("tools", "wirte", "tool, category or preset", Some("write")),
    BadValue(
      "tools",
      "reed, wirte",
      "at least one tool, category or preset",
      "ignored; the earlier setting stays (\"default\" unless an earlier file set it)",
    ),
  ])
  problems("tools = []\n") |> should.equal([])
}

pub fn bridge_port_does_nothing_yet_test() {
  problems("[bridge]\nport = 31337\n")
  |> should.equal([
    NotUsed(
      "bridge.port",
      "nothing reads it yet: the editor-extension listener isn't built",
    ),
  ])
}

// -- Invalid values are ignored: the config is the one without them -------

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn write_text(path: String, text: String) -> Result(Nil, String)

fn resolved(text: String) -> config.Config {
  let path =
    "/tmp/pharos-config-keys-test-"
    <> string.inspect(unique_integer())
    <> ".toml"
  let assert Ok(Nil) = write_text(path, text)
  config.resolve("/nonexistent-pharos-config-keys-test", fn(name) {
    case name {
      "PHAROS_CONFIG_FILE" -> Some(path)
      _ -> None
    }
  })
}

pub fn invalid_diagnostics_mode_keeps_the_bundled_mode_test() {
  let bad = resolved("[languages.ruby]\ndiagnostics_mode = \"pul\"\n")
  bad.languages
  |> should.equal(resolved("[languages.ruby]\n").languages)
  let assert Ok(ruby) = dict.get(registry.build(bad), "ruby")
  let assert [server_config, ..] = ruby.servers
  server_config.diagnostics_mode |> should.equal(languages.Pull)
}

pub fn tools_with_no_valid_entry_keep_the_earlier_setting_test() {
  resolved("tools = [\"reed\"]\n").tools
  |> should.equal(resolved("").tools)
  resolved("tools = [\"reed\"]\n").tools
  |> should.equal(config.ToolFilter(entries: ["default"]))
  // Taken as written: no tools at all, as before.
  resolved("tools = []\n").tools |> should.equal(config.ToolFilter(entries: []))
}

pub fn non_positive_initialize_timeout_keeps_the_default_test() {
  resolved("[languages.java]\ninitialize_timeout_ms = 0\n").languages
  |> should.equal(resolved("[languages.java]\n").languages)
  resolved(
    "[[languages.java.servers]]\nid = \"jdtls\"\ninitialize_timeout_ms = -5\n",
  ).languages
  |> should.equal(
    resolved("[[languages.java.servers]]\nid = \"jdtls\"\n").languages,
  )
}

pub fn non_positive_tool_timeout_keeps_the_compiled_default_test() {
  resolved(
    "[tool_config.hover]\ndefault_timeout_ms = 0\n[tool_config.hover.rust]\ndefault_timeout_ms = -1\n",
  ).tool_config
  |> should.equal(
    resolved("[tool_config.hover]\n[tool_config.hover.rust]\n").tool_config,
  )
}

pub fn negative_idle_stop_is_ignored_test() {
  resolved("[languages.java]\nidle_stop_secs = -1\n").languages
  |> should.equal(resolved("[languages.java]\n").languages)
}

pub fn empty_file_extension_is_dropped_test() {
  resolved("[languages.ruby]\nfile_extensions = [\".rb\", \"\"]\n").languages
  |> should.equal(
    resolved("[languages.ruby]\nfile_extensions = [\".rb\"]\n").languages,
  )
}

pub fn misplaced_keys_say_where_they_belong_test() {
  problems(
    "[languages.rust]
methods = [\"textDocument/hover\"]

[[languages.rust.servers]]
id = \"rust-analyzer\"
file_extensions = [\".rs\"]
",
  )
  |> should.equal([
    MisplacedKey("languages.rust.methods", "[[languages.rust.servers]]"),
    MisplacedKey(
      "languages.rust.servers[0].file_extensions",
      "[languages.rust]",
    ),
  ])
}

pub fn dates_are_named_as_dates_test() {
  problems(
    "[languages.rust]
command = 1979-05-27
args = 1979-05-27T07:32:00Z
",
  )
  |> should.equal([
    WrongType("languages.rust.args", "an array of strings", "a date/time"),
    WrongType("languages.rust.command", "a string", "a date/time"),
  ])
}

// -- Project config file names (#32, Logan's option b) -------------------

@external(erlang, "pharos_fs_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

fn temp_root(tag: String) -> String {
  let root = "/tmp/pharos-" <> tag <> "-" <> string.inspect(unique_integer())
  let assert Ok(Nil) = mkdir_p(root)
  root
}

fn no_env(_name: String) -> option.Option(String) {
  None
}

pub fn project_config_either_name_alone_test() {
  let root = temp_root("dotted")
  let assert Ok(Nil) = write_text(root <> "/.pharos.toml", "")
  config.find_project_config(root, no_env)
  |> should.equal(#(Some(root <> "/.pharos.toml"), []))

  let root = temp_root("plain")
  let assert Ok(Nil) =
    write_text(root <> "/pharos.toml", "tools = [\"read\"]\n")
  config.find_project_config(root, no_env)
  |> should.equal(#(Some(root <> "/pharos.toml"), []))
  // And it's applied.
  config.resolve(root, no_env).tools
  |> should.equal(config.ToolFilter(entries: ["read"]))
}

pub fn project_config_both_names_the_dotted_one_wins_test() {
  let root = temp_root("both")
  let assert Ok(Nil) = write_text(root <> "/.pharos.toml", "")
  let assert Ok(Nil) = write_text(root <> "/pharos.toml", "")
  config.find_project_config(root, no_env)
  |> should.equal(
    #(Some(root <> "/.pharos.toml"), [
      #(root <> "/pharos.toml", root <> "/.pharos.toml"),
    ]),
  )
}

pub fn project_config_nearer_directory_wins_test() {
  let root = temp_root("nearer")
  let assert Ok(Nil) = mkdir_p(root <> "/a/b/c")
  let assert Ok(Nil) = write_text(root <> "/a/.pharos.toml", "")
  let assert Ok(Nil) = write_text(root <> "/a/b/pharos.toml", "")
  config.find_project_config(root <> "/a/b/c", no_env)
  |> should.equal(#(Some(root <> "/a/b/pharos.toml"), []))

  let root = temp_root("nearer2")
  let assert Ok(Nil) = mkdir_p(root <> "/a/b/c")
  let assert Ok(Nil) = write_text(root <> "/a/pharos.toml", "")
  let assert Ok(Nil) = write_text(root <> "/a/b/.pharos.toml", "")
  config.find_project_config(root <> "/a/b/c", no_env)
  |> should.equal(#(Some(root <> "/a/b/.pharos.toml"), []))
}

pub fn project_config_never_reads_the_global_file_test() {
  // A project under the XDG config directory: the walk passes the global
  // pharos.toml and must not take it as a project file.
  let root = temp_root("global")
  let assert Ok(Nil) = mkdir_p(root <> "/cfg/pharos/proj")
  let assert Ok(Nil) = write_text(root <> "/cfg/pharos/pharos.toml", "")
  let env = fn(name) {
    case name {
      "XDG_CONFIG_HOME" -> Some(root <> "/cfg")
      _ -> None
    }
  }
  let #(found, _) = config.find_project_config(root <> "/cfg/pharos/proj", env)
  case found {
    Some(path) -> string.starts_with(path, root) |> should.be_false
    None -> Nil
  }
  // Nor the file PHAROS_CONFIG_FILE names, spelt differently.
  let root = temp_root("configfile")
  let assert Ok(Nil) = write_text(root <> "/pharos.toml", "")
  let env = fn(name) {
    case name {
      "PHAROS_CONFIG_FILE" -> Some(root <> "//./pharos.toml")
      _ -> None
    }
  }
  let #(found, _) = config.find_project_config(root, env)
  case found {
    Some(path) -> string.starts_with(path, root) |> should.be_false
    None -> Nil
  }
}

pub fn a_server_an_earlier_file_defined_is_known_test() {
  // F3: the global file defines gopls2 with a command; the project file
  // patches it without one.
  let assert Ok(parsed) =
    toml_parse(<<
      "[[languages.go.servers]]\nid = \"gopls2\"\nargs = [\"-v\"]\n",
    >>)
  config_keys.check(parsed, [#("go", ["gopls2"])]) |> should.equal([])
  config_keys.check(parsed, [])
  |> should.equal([
    MissingKey("languages.go.servers[0]", "command", "the server can't start"),
  ])
}

pub fn unknown_tool_languages_are_checked_across_files_test() {
  resolved("[tool_config.hover.rsut]\ndefault_timeout_ms = 1000\n")
  |> config.unknown_tool_languages
  |> should.equal([#("tool_config.hover.rsut", "rsut", Some("rust"))])
  // F2: the global file names a language only the project file defines.
  let root = temp_root("toollang")
  let assert Ok(Nil) =
    write_text(
      root <> "/.pharos.toml",
      "[languages.foo]\ncommand = \"foo-lsp\"\nfile_extensions = [\".foo\"]\n",
    )
  let global = root <> "/global.toml"
  let assert Ok(Nil) =
    write_text(global, "[tool_config.hover.foo]\ndefault_timeout_ms = 1000\n")
  config.resolve(root, fn(name) {
    case name {
      "PHAROS_CONFIG_FILE" -> Some(global)
      _ -> None
    }
  })
  |> config.unknown_tool_languages
  |> should.equal([])
}

pub fn only_empty_file_extensions_keep_the_bundled_ones_test() {
  // F1: nothing valid left means the list is ignored, not [].
  resolved("[languages.ruby]\nfile_extensions = [\"\"]\n").languages
  |> should.equal(resolved("[languages.ruby]\n").languages)
  problems("[languages.ruby]\nfile_extensions = [\"\"]\n")
  |> should.equal([
    BadValue(
      "languages.ruby.file_extensions",
      "",
      "no empty entry",
      "ignored; the bundled extensions stay",
    ),
  ])
  // An explicit empty list is taken as written.
  resolved("[languages.ruby]\nfile_extensions = []\n").languages
  |> should.not_equal(resolved("[languages.ruby]\n").languages)
}

pub fn dotted_global_file_taken_by_the_walk_is_not_ignored_test() {
  // F5: cwd is the XDG directory, which holds only .pharos.toml: the walk
  // reads it as the project file, so it isn't "not read".
  let root = temp_root("dottedglobal")
  let assert Ok(Nil) = mkdir_p(root <> "/cfg/pharos")
  let assert Ok(Nil) = write_text(root <> "/cfg/pharos/.pharos.toml", "")
  let env = fn(name) {
    case name {
      "XDG_CONFIG_HOME" -> Some(root <> "/cfg")
      _ -> None
    }
  }
  config.dotted_global_ignored(root <> "/cfg/pharos", env) |> should.equal(None)
  config.dotted_global_ignored(root, env)
  |> should.equal(
    Some(#(
      root <> "/cfg/pharos/.pharos.toml",
      root <> "/cfg/pharos/pharos.toml",
    )),
  )
}

pub fn missing_required_keys_test() {
  problems(
    "[languages.mylang]
save_check_grace_ms = 1

[[languages.python.servers]]
command = \"mypy\"

[[languages.python.servers]]
id = \"mypy\"

[[languages.python.servers]]
id = \"ruff\"

[languages.scala.custom_uri_schemes.\"metals-decode\"]
fetch_response_field = \"value\"
",
  )
  |> should.equal([
    MissingKey(
      "languages.mylang",
      "command",
      "the language has no server to start",
    ),
    MissingKey(
      "languages.mylang",
      "file_extensions",
      "no file is routed to the language",
    ),
    MissingKey("languages.python.servers[0]", "id", "the entry is ignored"),
    MissingKey(
      "languages.python.servers[1]",
      "command",
      "the server can't start",
    ),
    MissingKey(
      "languages.scala.custom_uri_schemes.metals-decode",
      "fetch_method",
      "the scheme is ignored",
    ),
  ])
}

pub fn print_language_config_output_is_quiet_test() {
  let text = registry_toml.render_registry(languages.default_registry())
  problems(text) |> should.equal([])
}

pub fn example_config_is_quiet_test() {
  let assert Ok(bytes) = read_file("doc/example-pharos.toml")
  let assert Ok(text) = bit_array.to_string(bytes)
  let snippets = examples(text)
  // The extraction must actually find the examples, or this proves nothing.
  { list.length(snippets) >= 25 } |> should.be_true
  let all = string.join(snippets, "\n")
  list.each(
    [
      "readiness_timeout_ms",
      "initialize_timeout_ms",
      "lazy_workspace_index_ms",
      "save_check_grace_ms",
      "full_change_as_range",
      "pull_after_change_ms",
      "default_timeout_ms",
      "initialization_options_json",
      "document_language_ids",
    ],
    fn(key) { string.contains(all, key <> " = ") |> should.be_true },
  )
  list.each(snippets, fn(snippet) { problems(snippet) |> should.equal([]) })
}

pub fn default_config_template_is_quiet_test() {
  let snippets = examples(pharos.default_config_template)
  { list.length(snippets) >= 12 } |> should.be_true
  list.each(snippets, fn(snippet) { problems(snippet) |> should.equal([]) })
}

pub fn first_config_check_once_per_content_test() {
  let path =
    "/nonexistent/pharos-" <> string.inspect(unique_integer()) <> ".toml"
  first_config_check(path, <<"a = 1">>, False) |> should.be_true
  first_config_check(path, <<"a = 1">>, False) |> should.be_false
  // Once more when the writer comes up: one copy through its sinks.
  first_config_check(path, <<"a = 1">>, True) |> should.be_true
  first_config_check(path, <<"a = 1">>, True) |> should.be_false
  first_config_check(path, <<"a = 2">>, True) |> should.be_true
  first_config_check(path <> ".other", <<"a = 1">>, True) |> should.be_true
}

// -- Pulling the examples out of a commented config ----------------------

/// Every example in a config file whose examples are commented out, each
/// as its own TOML document (the file repeats tables across examples). An
/// example starts at a table header, commented or not; it takes the
/// assignments after it, commented (`# key = value`, with no indent after
/// the `# `, which is how prose and indented samples are told apart) or
/// not, and the body of a `'''` string. Lines before the first header
/// make the first example.
fn examples(text: String) -> List(String) {
  let #(done, current, _) =
    string.split(text, "\n")
    |> list.fold(#([], [], False), fn(state, line) {
      let #(done, current, in_string) = state
      case in_string {
        True -> {
          let body = case line {
            "# " <> rest -> rest
            "#" <> rest -> rest
            _ -> line
          }
          #(done, [body, ..current], !string.contains(body, "'''"))
        }
        False -> {
          let candidate = case line {
            "# " <> rest -> rest
            "#" <> _ -> ""
            _ -> line
          }
          case is_header(candidate), is_assignment(candidate) {
            True, _ -> #(push(done, current), [candidate], False)
            False, True -> #(
              done,
              [candidate, ..current],
              count(candidate, "'''") == 1,
            )
            False, False -> state
          }
        }
      }
    })
  push(done, current)
  |> list.reverse
  |> list.filter(fn(snippet) { string.contains(snippet, " = ") })
}

fn push(done: List(String), current: List(String)) -> List(String) {
  case current {
    [] -> done
    _ -> [string.join(list.reverse(current), "\n"), ..done]
  }
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

fn is_header(line: String) -> Bool {
  let inner = case line {
    "[[" <> rest -> string.drop_end(rest, 2)
    "[" <> rest -> string.drop_end(rest, 1)
    _ -> ""
  }
  string.ends_with(line, "]") && inner != "" && all_key_chars(inner)
}

fn is_assignment(line: String) -> Bool {
  case string.split_once(line, " = ") {
    Ok(#(key, _)) -> key != "" && all_key_chars(key)
    Error(_) -> False
  }
}

fn all_key_chars(s: String) -> Bool {
  string.to_graphemes(s)
  |> list.all(fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.\"",
      c,
    )
  })
}
