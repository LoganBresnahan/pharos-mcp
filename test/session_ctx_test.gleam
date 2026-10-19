//// Per-session context (ADR-034): config, registry, memory roots,
//// cancel keys and timeout overrides resolve through the session
//// bound to the calling process, so two sessions in one BEAM don't
//// see each other's.
////
//// Each case binds sessions in spawned processes: binding the test
//// process itself would leak into every later test.

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import pharos/config
import pharos/lsp/registry
import pharos/mcp/request_workers
import pharos/session_ctx.{type SessionCtx}
import pharos/tools/memory
import pharos/tools/session_overrides

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_fs_ffi", "is_regular_file")
fn is_regular_file(path: String) -> Bool

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

/// Run `body` in a fresh process bound to `ctx` and return its value.
fn in_session(ctx: SessionCtx, body: fn() -> a) -> a {
  let reply = process.new_subject()
  process.spawn(fn() {
    session_ctx.bind(ctx)
    process.send(reply, body())
  })
  let assert Ok(value) = process.receive(reply, 5000)
  value
}

fn temp_dir(tag: String) -> String {
  let dir =
    "/tmp/pharos-session-ctx-test-"
    <> tag
    <> "-"
    <> int.to_string(int.absolute_value(unique_int()))
  let _ = shell("rm -rf " <> dir <> " && mkdir -p " <> dir)
  dir
}

pub fn resolve_reads_the_given_env_not_the_process_env_test() {
  let env = dict.from_list([#("PHAROS_TOOLS", "read")])
  let cfg =
    config.resolve("/", fn(name) { option.from_result(dict.get(env, name)) })
  cfg.tools
  |> should.equal(config.ToolFilter(entries: ["read"]))
}

pub fn bound_session_config_wins_over_process_config_test() {
  let a = session_ctx.new("a", "/", dict.from_list([#("PHAROS_TOOLS", "read")]))
  let b =
    session_ctx.new("b", "/", dict.from_list([#("PHAROS_TOOLS", "write")]))
  in_session(a, fn() { config.cached().tools })
  |> should.equal(config.ToolFilter(entries: ["read"]))
  in_session(b, fn() { config.cached().tools })
  |> should.equal(config.ToolFilter(entries: ["write"]))
}

pub fn project_toml_is_found_from_the_session_cwd_test() {
  let with_toml = temp_dir("toml")
  let _ =
    shell(
      "printf '[languages.zz_test]\\ncommand = \"zz-ls\"\\n"
      <> "file_extensions = [\".zzt\"]\\nroot_markers = [\"zz.marker\"]\\n' > "
      <> with_toml
      <> "/.pharos.toml",
    )
  let without = temp_dir("plain")
  let a = session_ctx.new("a", with_toml, dict.new())
  let b = session_ctx.new("b", without, dict.new())
  in_session(a, fn() { dict.has_key(registry.cached(), "zz_test") })
  |> should.be_true
  in_session(b, fn() { dict.has_key(registry.cached(), "zz_test") })
  |> should.be_false
  let _ = shell("rm -rf " <> with_toml <> " " <> without)
  Nil
}

pub fn scoped_keys_differ_across_sessions_test() {
  let a = session_ctx.new("a", "/", dict.new())
  let b = session_ctx.new("b", "/", dict.new())
  let key_a = in_session(a, fn() { session_ctx.scoped("2") })
  let key_b = in_session(b, fn() { session_ctx.scoped("2") })
  should.not_equal(key_a, key_b)
}

pub fn a_cancel_key_from_one_session_misses_the_other_test() {
  request_workers.init()
  let a = session_ctx.new("cancel-a", "/", dict.new())
  let b = session_ctx.new("cancel-b", "/", dict.new())
  let pid = process.self()
  in_session(a, fn() { request_workers.insert(session_ctx.scoped("7"), pid) })
  in_session(b, fn() { request_workers.lookup(session_ctx.scoped("7")) })
  |> should.be_error
  in_session(a, fn() { request_workers.lookup(session_ctx.scoped("7")) })
  |> should.equal(Ok(pid))
  in_session(a, fn() { request_workers.delete(session_ctx.scoped("7")) })
}

pub fn timeout_overrides_stay_in_their_session_test() {
  let a = session_ctx.new("ovr-a", "/", dict.new())
  let b = session_ctx.new("ovr-b", "/", dict.new())
  in_session(a, fn() { session_overrides.set("hover", None, 123_000) })
  in_session(a, fn() { session_overrides.get("hover", None) })
  |> should.equal(Some(123_000))
  in_session(b, fn() { session_overrides.get("hover", None) })
  |> should.equal(None)
  session_overrides.drop("ovr-a")
  in_session(a, fn() { session_overrides.get("hover", None) })
  |> should.equal(None)
}

pub fn project_memories_land_under_the_session_cwd_test() {
  let cwd = temp_dir("mem")
  let user = temp_dir("mem-user")
  let ctx =
    session_ctx.new(
      "mem",
      cwd,
      dict.from_list([#("PHAROS_USER_MEMORY_ROOT", user)]),
    )
  in_session(ctx, fn() {
    memory.save(
      "session-cwd-note",
      "project",
      "lands under the session cwd",
      "body",
      False,
      "2026-10-19T00:00:00Z",
    )
  })
  |> should.be_ok
  is_regular_file(cwd <> "/.pharos/memories/project/session-cwd-note.md")
  |> should.be_true
  let _ = shell("rm -rf " <> cwd <> " " <> user)
  Nil
}

pub fn unbound_process_falls_back_to_direct_test() {
  session_ctx.id()
  |> should.equal(session_ctx.direct_id)
}
