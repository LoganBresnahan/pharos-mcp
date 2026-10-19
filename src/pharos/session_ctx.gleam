//// Per-session context (ADR-034).
////
//// One MCP session's working directory, environment, Config and
//// language registry. Direct mode builds one from the process's own
//// cwd and env; the daemon builds one per connection from its hello.
//// Both go through `new/3`, so the two modes resolve config the same
//// way.
////
//// A dispatcher process binds its session once (`bind/1`), and the
//// existing lookups (`config.cached/0`, `registry.cached/0`) resolve
//// through it. Processes with no bound session (the HTTP transport,
//// boot, tests) fall back to the process-wide values.
////
//// The env can hold secrets (API keys). Never log it or return it in
//// a response; report a session by `id` and `cwd`.

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import pharos/config.{type Config}
import pharos/env
import pharos/lsp/languages.{type LanguageConfig}
import pharos/lsp/registry

pub type SessionCtx {
  SessionCtx(
    id: String,
    cwd: String,
    env: Dict(String, String),
    config: Config,
    registry: Dict(String, LanguageConfig),
  )
}

/// Session id of direct mode: the one session of an in-process
/// stdio server, and the fallback for processes with none bound.
pub const direct_id = "direct"

pub fn new(id: String, cwd: String, env: Dict(String, String)) -> SessionCtx {
  let config = config.resolve(cwd, lookup_in(env))
  SessionCtx(
    id: id,
    cwd: cwd,
    env: env,
    config: config,
    registry: registry.build(config),
  )
}

/// Direct mode's context: the process's own cwd and env.
pub fn direct() -> SessionCtx {
  new(direct_id, process_cwd(), os_env())
}

/// Bind `ctx` to the calling process. Call once, first thing, in
/// every process that serves the session.
pub fn bind(ctx: SessionCtx) -> Nil {
  bind_ffi(ctx.id, ctx.cwd, ctx.env, ctx.config, ctx.registry)
}

/// The calling process's session id, or `direct_id` when none is
/// bound.
pub fn id() -> String {
  case id_ffi() {
    Ok(id) -> id
    Error(_) -> direct_id
  }
}

/// The calling process's session cwd, or the process cwd.
pub fn cwd() -> String {
  case cwd_ffi() {
    Ok(cwd) -> cwd
    Error(_) -> process_cwd()
  }
}

/// Look `name` up in the calling process's session env, or in the
/// process env when no session is bound.
pub fn getenv(name: String) -> Option(String) {
  case env_ffi() {
    Ok(session_env) -> lookup_in(session_env)(name)
    Error(_) -> env.get(name)
  }
}

/// Qualify a per-session key (an MCP request id) with the calling
/// process's session id. MCP ids are only unique within a
/// connection: two clients both send id `2`.
pub fn scoped(key: String) -> String {
  id() <> "|" <> key
}

fn lookup_in(env: Dict(String, String)) -> fn(String) -> Option(String) {
  fn(name) { option.from_result(dict.get(env, name)) }
}

@external(erlang, "pharos_session_ctx_ffi", "bind")
fn bind_ffi(
  id: String,
  cwd: String,
  env: Dict(String, String),
  config: Config,
  registry: Dict(String, LanguageConfig),
) -> Nil

@external(erlang, "pharos_session_ctx_ffi", "id")
fn id_ffi() -> Result(String, Nil)

@external(erlang, "pharos_session_ctx_ffi", "cwd")
fn cwd_ffi() -> Result(String, Nil)

@external(erlang, "pharos_session_ctx_ffi", "env")
fn env_ffi() -> Result(Dict(String, String), Nil)

@external(erlang, "pharos_session_ctx_ffi", "os_env")
fn os_env() -> Dict(String, String)

@external(erlang, "pharos_fs_ffi", "cwd")
fn process_cwd() -> String
