//// #20: environment values, HOME, `which` and shell commands keep their
//// non-ASCII characters. They used to pass through binary_to_list /
//// list_to_binary, which read each UTF-8 byte as a character: `é` came
//// back as the wrong bytes and `漢` crashed with badarg.

import gleam/erlang/charlist.{type Charlist}
import gleeunit/should

// The OS's own view: environment values as characters, the way a shell
// or a parent process sets them. pharos's setenv/getenv must agree with
// these. On main they only agreed with each other: each converted one
// character per byte, and the two mistakes cancelled out.
@external(erlang, "os", "putenv")
fn os_putenv(key: Charlist, value: Charlist) -> Bool

@external(erlang, "os", "getenv")
fn os_getenv(key: Charlist) -> Charlist

/// Runs `f` with `key` set to `value` (as the OS sets it) and restores
/// the old value afterwards, even if `f` crashes.
@external(erlang, "fs_env_unicode_test_support", "with_env")
fn with_env(key: String, value: String, f: fn() -> a) -> a

@external(erlang, "pharos_fs_ffi", "getenv")
fn getenv(key: String) -> Result(String, Nil)

@external(erlang, "pharos_fs_ffi", "setenv")
fn setenv(key: String, value: String) -> Nil

@external(erlang, "pharos_fs_ffi", "home_dir")
fn home_dir() -> String

@external(erlang, "pharos_fs_ffi", "which_executable")
fn which_executable(cmd: String) -> Result(String, Nil)

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_fs_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn atomic_write_text(path: String, text: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "rm_rf")
fn rm_rf(path: String) -> Result(Nil, String)

pub fn env_values_keep_non_ascii_characters_test() {
  // Set by the OS, read by pharos.
  os_putenv(
    charlist.from_string("PHAROS_TEST_UNICODE_20"),
    charlist.from_string("/tmp/café/漢字"),
  )
  getenv("PHAROS_TEST_UNICODE_20") |> should.equal(Ok("/tmp/café/漢字"))
  // Set by pharos, read by the OS.
  setenv("PHAROS_TEST_UNICODE_20B", "/tmp/hé/漢")
  os_getenv(charlist.from_string("PHAROS_TEST_UNICODE_20B"))
  |> charlist.to_string
  |> should.equal("/tmp/hé/漢")
}

pub fn home_dir_keeps_a_non_ascii_home_test() {
  with_env("HOME", "/tmp/hömé 漢", home_dir)
  |> should.equal("/tmp/hömé 漢")
}

pub fn which_finds_a_server_under_a_non_ascii_path_test() {
  let dir = "/tmp/pharos_which_test_20/bin é 漢"
  let tool = dir <> "/pharos-test-tool-20"
  let assert Ok(Nil) = mkdir_p(dir)
  let assert Ok(Nil) = atomic_write_text(tool, "#!/bin/sh\nexit 0\n")
  let _ = shell("chmod +x '" <> tool <> "'")
  // By absolute path, and through PATH. Clean up before judging, so a
  // failure leaves nothing behind.
  let absolute = which_executable(tool)
  let assert Ok(path) = getenv("PATH")
  let on_path =
    with_env("PATH", dir <> ":" <> path, fn() {
      which_executable("pharos-test-tool-20")
    })
  let _ = rm_rf("/tmp/pharos_which_test_20")
  absolute |> should.equal(Ok(tool))
  on_path |> should.equal(Ok(tool))
}

pub fn shell_commands_keep_non_ascii_text_test() {
  shell("printf %s 'café 漢'") |> should.equal("café 漢")
}

@external(erlang, "pharos_fs_ffi", "binary_to_name")
fn binary_to_name(b: String) -> Charlist

@external(erlang, "pharos_fs_ffi", "name_to_binary")
fn name_to_binary(name: Charlist) -> String

/// What process_comm and ps_lstart's macOS `ps` fallbacks rely on: the
/// characters os:cmd returns convert back to the bytes they spell.
/// Linux reads /proc instead, so the fallbacks can't run here.
pub fn names_round_trip_through_the_native_encoding_test() {
  let path = "/Applications/Éditeur 漢/bin/server"
  path |> binary_to_name |> name_to_binary |> should.equal(path)
  charlist.from_string(path) |> name_to_binary |> should.equal(path)
}
