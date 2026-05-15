//// Shape contract tests for small Erlang FFI modules.
////
//// Each FFI declares a Gleam-side return type. Erlang has no way to
//// enforce that contract — a typo or refactor inside the .erl can
//// return a tuple that does not match the Gleam variant, and the
//// next pattern match crashes the calling process silently. These
//// tests exercise each FFI with safe inputs and assert the value
//// matches the declared shape. Compile-time already enforces
//// argument types; this catches runtime shape drift.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should

// -- pharos_env_ffi: get -------------------------------------------------
//
// Returns Option(String). The Erlang side fronts `os:getenv/1` and
// wraps the result in `{some, Binary}` / `none`. Defensive wrap on
// `unicode:characters_to_binary` is what we want to validate — an
// env var with non-UTF8 bytes must not break the Option(String)
// shape contract.

@external(erlang, "pharos_env_ffi", "get")
fn env_get(name: String) -> Option(String)

pub fn env_get_unset_returns_none_test() {
  // A name that very likely is not set in the test runner env.
  case env_get("PHAROS_FFI_TEST_DEFINITELY_UNSET_ZZZ") {
    None -> should.equal(1, 1)
    Some(_) -> should.fail()
  }
}

pub fn env_get_set_returns_some_test() {
  set_env("PHAROS_FFI_TEST_SET", "hello")
  case env_get("PHAROS_FFI_TEST_SET") {
    Some(value) -> should.equal(value, "hello")
    None -> should.fail()
  }
  unset_env("PHAROS_FFI_TEST_SET")
}

pub fn env_get_empty_value_returns_some_empty_test() {
  set_env("PHAROS_FFI_TEST_EMPTY", "")
  case env_get("PHAROS_FFI_TEST_EMPTY") {
    Some(value) -> should.equal(value, "")
    None -> should.fail()
  }
  unset_env("PHAROS_FFI_TEST_EMPTY")
}

pub fn env_get_non_utf8_value_returns_some_test() {
  // Set a value with raw byte 0xFF (invalid UTF-8 start byte).
  // The FFI must absorb the `{error, _, _}` return shape from
  // unicode:characters_to_binary and still yield a Some(Binary)
  // — never let the {error, _} tuple leak as the Option value.
  set_env_raw_bytes("PHAROS_FFI_TEST_NONUTF8", <<104, 105, 255>>)
  case env_get("PHAROS_FFI_TEST_NONUTF8") {
    Some(_) -> should.equal(1, 1)
    None -> should.fail()
  }
  unset_env("PHAROS_FFI_TEST_NONUTF8")
}

// -- pharos_framing_ffi: find --------------------------------------------
//
// Wraps `binary:match/2`. Returns Result(Int, Nil) where Ok(N) is the
// byte offset of needle. binary:match returns `nomatch` or `{Pos,Len}`.

@external(erlang, "pharos_framing_ffi", "find")
fn framing_find(haystack: BitArray, needle: BitArray) -> Result(Int, Nil)

pub fn framing_find_match_test() {
  let haystack = <<"Content-Length: 42\r\n\r\nbody":utf8>>
  let needle = <<"\r\n\r\n":utf8>>
  case framing_find(haystack, needle) {
    Ok(pos) -> should.equal(pos, 18)
    Error(_) -> should.fail()
  }
}

pub fn framing_find_no_match_test() {
  let haystack = <<"no separator here":utf8>>
  let needle = <<"\r\n\r\n":utf8>>
  case framing_find(haystack, needle) {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

pub fn framing_find_empty_haystack_test() {
  let needle = <<"\r\n\r\n":utf8>>
  case framing_find(<<>>, needle) {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

// -- pharos_session_ffi: generate_session_id -----------------------------
//
// Returns a 32-char lowercase hex string. Used for HTTP session ids;
// must be URL-safe and stable shape.

@external(erlang, "pharos_session_ffi", "generate_session_id")
fn generate_session_id() -> String

pub fn session_id_shape_test() {
  let id = generate_session_id()
  should.equal(string.length(id), 32)
  // All chars must be lowercase hex.
  let chars = string.to_graphemes(id)
  let valid =
    list.all(chars, fn(c) {
      case c {
        "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
        "a" | "b" | "c" | "d" | "e" | "f" -> True
        _ -> False
      }
    })
  should.equal(valid, True)
}

pub fn session_id_unique_test() {
  // Two consecutive calls must not collide (cryptographic randomness).
  let a = generate_session_id()
  let b = generate_session_id()
  should.equal(a == b, False)
}

// -- pharos_toml_ffi: parse + format_error --------------------------------

import gleam/dynamic.{type Dynamic}

@external(erlang, "pharos_toml_ffi", "parse")
fn toml_parse(input: String) -> Result(Dynamic, String)

pub fn toml_parse_valid_test() {
  case toml_parse("key = \"value\"\n") {
    Ok(_) -> should.equal(1, 1)
    Error(_) -> should.fail()
  }
}

pub fn toml_parse_invalid_returns_error_string_test() {
  case toml_parse("[invalid syntax here") {
    Error(reason) -> {
      // Reason must be a printable binary, not a raw tuple.
      should.equal(string.length(reason) > 0, True)
    }
    Ok(_) -> should.fail()
  }
}

// -- pharos_fs_ffi: which_executable -------------------------------------

@external(erlang, "pharos_fs_ffi", "which_executable")
fn which_executable(cmd: String) -> Result(String, Nil)

pub fn which_executable_finds_sh_test() {
  // /bin/sh is on every POSIX system; either absolute lookup or PATH
  // lookup must succeed.
  case which_executable("sh") {
    Ok(path) -> should.equal(string.length(path) > 0, True)
    Error(_) -> should.fail()
  }
}

pub fn which_executable_missing_returns_error_test() {
  case which_executable("definitely_not_a_real_executable_xyzzy") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

pub fn which_executable_absolute_path_test() {
  // Absolute path that exists.
  case which_executable("/bin/sh") {
    Ok(path) -> should.equal(path, "/bin/sh")
    Error(_) -> should.fail()
  }
}

pub fn which_executable_absolute_missing_test() {
  case which_executable("/this/path/does/not/exist/zzz") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

// -- pharos_fs_ffi: cwd ---------------------------------------------------

@external(erlang, "pharos_fs_ffi", "cwd")
fn fs_cwd() -> String

pub fn fs_cwd_returns_nonempty_test() {
  let cwd = fs_cwd()
  // Test runner always has a cwd; binary must be non-empty and look
  // absolute (starts with /).
  should.equal(string.length(cwd) > 0, True)
  should.equal(string.starts_with(cwd, "/"), True)
}

// -- pharos_fs_ffi: dirname / is_regular_file / is_directory --------------

@external(erlang, "pharos_fs_ffi", "dirname")
fn dirname(path: String) -> String

@external(erlang, "pharos_fs_ffi", "is_regular_file")
fn is_regular_file(path: String) -> Bool

@external(erlang, "pharos_fs_ffi", "is_directory")
fn is_directory(path: String) -> Bool

pub fn dirname_test() {
  should.equal(dirname("/a/b/c"), "/a/b")
  should.equal(dirname("/a"), "/")
}

pub fn is_regular_file_test() {
  // /bin/sh is a regular file (or a symlink to one — filelib:is_regular
  // dereferences symlinks).
  should.equal(is_regular_file("/bin/sh"), True)
  should.equal(is_regular_file("/this/does/not/exist"), False)
}

pub fn is_directory_test() {
  should.equal(is_directory("/tmp"), True)
  should.equal(is_directory("/this/does/not/exist"), False)
}

// -- Test-local FFI helpers ----------------------------------------------

@external(erlang, "pharos_ffi_shape_test_support", "set_env")
fn set_env(name: String, value: String) -> Nil

@external(erlang, "pharos_ffi_shape_test_support", "unset_env")
fn unset_env(name: String) -> Nil

@external(erlang, "pharos_ffi_shape_test_support", "set_env_raw_bytes")
fn set_env_raw_bytes(name: String, value: BitArray) -> Nil
