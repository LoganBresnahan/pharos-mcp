import Config

# ADR-030 B1: disable OTP's default `logger_std_h` handler at the kernel
# config level so the BEAM does not panic during boot when stderr is
# closed or otherwise dead.
#
# Background: logger_std_h calls `io:put_chars(:standard_error, …)` on
# every event. When fd 2 is closed (host shutdown race, MCP client
# closing pipes, `2>/dev/null` patterns), that call raises `badarg`,
# which logger reports as a handler crash, which logger tries to log
# via the same dead handler, which raises again — BEAM terminates with
# slogan `Runtime terminating during boot ({badarg,[{io,put_chars,
# [standard_error,…`. Observed three times on 2026-05-22 (Phase 5
# pre-extract, MCP-spawn during host shutdown, MCP-spawn during user
# restart).
#
# `{:handler, :default, :undefined}` is OTP's documented way to
# suppress the default handler at startup. Pre-main log events go
# nowhere instead of crashing the runtime. Pharos installs its own
# `pharos_logger_h` (try/catch-wrapped logger_std_h) inside
# `pharos:main/0` once the runtime is up; that handler picks up
# events from the moment main runs.
#
# Compile-time config (config.exs) is required here, not runtime
# config (runtime.exs), because :kernel is already loaded by the
# time runtime config providers fire — Mix release prints
# `ERROR! Cannot configure :kernel because :kernel has already been
# loaded` and crashes.
#
# Guarded on Mix.env() because in plain `mix start` / `mix run` (dev
# env) the :kernel application is already started before config files
# load and Mix prints "Cannot configure base applications: [:kernel]"
# warnings. The warning is harmless but pollutes stderr; for release
# builds the config is consulted before :kernel boots, so the
# assignment takes.
if Mix.env() == :prod do
  # ADR-030 B1: silence every default logger handler at boot so a
  # dead `:standard_error` (closed fd 2, host shutdown race) cannot
  # crash BEAM during the OTP startup window and so log events
  # cannot leak to `:standard_io` (the MCP JSON-RPC channel).
  #
  # Three handlers have to be addressed because Elixir's `:logger`
  # app installs more than just the OTP kernel default:
  #
  # 1. **OTP kernel default** — set to `:undefined`. Elixir's
  #    `Logger.App` removes whatever default handler is present at
  #    application start anyway (`Logger.App.remove_erlang_handler/0`),
  #    so any module we put here gets removed seconds later.
  # 2. **Elixir Logger default handler** — `default_handler: false`
  #    stops `Logger.App.add_elixir_handler/1` from installing
  #    Elixir's own `logger_std_h` writing to standard_io.
  # 3. **Elixir backend handler** — `backends: []` stops
  #    `Logger.Backends.Internal` from starting; its `init/1`
  #    unconditionally calls
  #    `:logger.add_handler(Logger, Logger.Backends.Handler, …)`
  #    which writes to the configured device (default: stdout in
  #    `-noshell` mode).
  #
  # Net effect: between BEAM startup and `pharos:main/0` no logger
  # handlers exist; events are silently dropped. `pharos:main/0`
  # installs `pharos_sasl_capture` (module = `pharos_logger_h`,
  # destination = `standard_error` with try/catch) as the only
  # post-main handler. The drop window is the few milliseconds
  # between :logger app start and pharos:main reaching its install
  # call — those events are uninteresting OTP / SASL boot chatter.
  config :logger,
    default_handler: false,
    backends: []

  # Leave the kernel `:default` handler unconfigured. At boot OTP
  # installs its own emergency `:simple` handler (`logger_simple_h`)
  # which is harmless when stderr is healthy but writes to stdout
  # via `:user` when stderr is closed. `pharos:main/0` replaces
  # `:simple` with `pharos_logger_h` immediately on startup —
  # OTP's `logger.erl` auto-removes `:simple` when any handler
  # named `:default` is added (kernel-10.4/src/logger.erl:844).
end
