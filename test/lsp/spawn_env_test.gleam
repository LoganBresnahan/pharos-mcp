//// ADR-034: an LSP runs with the environment of the session that
//// started it, a bare command resolves on that session's `PATH`, and
//// the spawn fingerprint decides which sessions share an LSP.

import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/json
import gleam/string
import gleeunit/should
import pharos/lsp/languages
import pharos/lsp/pool
import pharos/lsp/port
import pharos/tools/session

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_fs_ffi", "setenv")
fn setenv(key: String, value: String) -> Nil

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

fn temp_dir(tag: String) -> String {
  let dir =
    "/tmp/pharos-spawn-env-test-"
    <> tag
    <> "-"
    <> int.to_string(int.absolute_value(unique_int()))
  let _ = shell("rm -rf " <> dir <> " && mkdir -p " <> dir)
  dir
}

/// Collect a child's stdout until it exits or goes quiet.
fn read_all(p: port.Port, acc: BitArray) -> String {
  case port.receive_data(p, 2000) {
    Ok(chunk) -> read_all(p, bit_array.append(acc, chunk))
    Error(_) -> {
      let assert Ok(text) = bit_array.to_string(acc)
      text
    }
  }
}

pub fn child_gets_exactly_the_session_env_test() {
  setenv("PHAROS_SPAWN_ENV_BEAM_ONLY", "leaked")
  let assert Ok(p) =
    port.spawn_with_env(
      "/bin/sh",
      [
        "-c",
        "printf '%s|%s' \"$PHAROS_SPAWN_ENV_SESSION\" \"${PHAROS_SPAWN_ENV_BEAM_ONLY-unset}\"",
      ],
      "/tmp",
      [
        #("PHAROS_SPAWN_ENV_SESSION", "from-session"),
        #("PATH", "/usr/bin:/bin"),
      ],
    )
  read_all(p, <<>>)
  |> should.equal("from-session|unset")
}

pub fn empty_env_inherits_the_beam_env_test() {
  setenv("PHAROS_SPAWN_ENV_INHERITED", "kept")
  let assert Ok(p) =
    port.spawn_with_env(
      "/bin/sh",
      ["-c", "printf '%s' \"$PHAROS_SPAWN_ENV_INHERITED\""],
      "/tmp",
      [],
    )
  read_all(p, <<>>)
  |> should.equal("kept")
}

pub fn bare_command_resolves_on_the_session_path_test() {
  let bin = temp_dir("bin")
  let _ =
    shell(
      "printf '#!/bin/sh\\nprintf found\\n' > "
      <> bin
      <> "/pharos-zz-fake-ls && chmod +x "
      <> bin
      <> "/pharos-zz-fake-ls",
    )
  let assert Ok(p) =
    port.spawn_with_env("pharos-zz-fake-ls", [], "/tmp", [
      #("PATH", bin <> ":/usr/bin:/bin"),
    ])
  read_all(p, <<>>)
  |> string.trim
  |> should.equal("found")
  // Not on the BEAM's own PATH, and not on a session PATH that lacks it.
  port.spawn_with_env("pharos-zz-fake-ls", [], "/tmp", [
    #("PATH", "/usr/bin:/bin"),
  ])
  |> should.be_error
  let _ = shell("rm -rf " <> bin)
  Nil
}

fn python() -> languages.LanguageConfig {
  let assert Ok(config) = dict.get(languages.default_registry(), "python")
  config
}

fn fingerprint(env: List(#(String, String))) -> String {
  let config = python()
  let assert Ok(server) = languages.primary_server(config)
  session.spawn_fingerprint(config, server, json.null(), env)
}

pub fn fingerprint_ignores_path_when_the_binary_resolves_the_same_test() {
  fingerprint([#("PATH", "/usr/bin:/bin")])
  |> should.equal(fingerprint([#("PATH", "/bin:/usr/bin:/nonexistent")]))
}

pub fn fingerprint_splits_on_an_env_key_test() {
  should.not_equal(
    fingerprint([#("VIRTUAL_ENV", "/proj/.venv")]),
    fingerprint([#("VIRTUAL_ENV", "/other/.venv")]),
  )
  should.not_equal(
    fingerprint([#("VIRTUAL_ENV", "/proj/.venv")]),
    fingerprint([]),
  )
}

pub fn fingerprint_ignores_vars_outside_env_keys_test() {
  fingerprint([#("ANTHROPIC_API_KEY", "a")])
  |> should.equal(fingerprint([#("ANTHROPIC_API_KEY", "b")]))
}

pub fn fingerprint_splits_on_a_different_resolved_binary_test() {
  let a = temp_dir("a")
  let b = temp_dir("b")
  let config = python()
  let assert Ok(server) = languages.primary_server(config)
  let make = fn(dir) {
    let _ =
      shell(
        "printf '#!/bin/sh\\n' > "
        <> dir
        <> "/"
        <> server.command
        <> " && chmod +x "
        <> dir
        <> "/"
        <> server.command,
      )
    Nil
  }
  make(a)
  make(b)
  should.not_equal(fingerprint([#("PATH", a)]), fingerprint([#("PATH", b)]))
  let _ = shell("rm -rf " <> a <> " " <> b)
  Nil
}

pub fn server_key_appends_the_variant_test() {
  let config = python()
  let assert Ok(server) = languages.primary_server(config)
  let spec = session.build_spawn_spec("/proj", config, server)
  pool.server_key(spec)
  |> should.equal(server.id <> "@" <> spec.variant)
  pool.server_key(pool.SpawnSpec(..spec, variant: ""))
  |> should.equal(server.id)
}
