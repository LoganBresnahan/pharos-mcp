import Config

# MCP communicates over stdio: stdout is reserved for JSON-RPC frames.
# Route Erlang/Elixir kernel and OTP logger output to stderr so notices,
# info logs, and shutdown messages do not corrupt the protocol stream.
# The default handler writes to :standard_io otherwise.
#
# Compile-time config (config.exs) is required here, not runtime config
# (runtime.exs), because :kernel is already loaded by the time runtime
# config providers fire — Mix release prints `ERROR! Cannot configure
# :kernel because ... :kernel has already been loaded` and crashes.
#
# Guarded on Mix.env() because in plain `mix start` / `mix run` (dev
# env) the :kernel application is already started before config files
# load and Mix prints "Cannot configure base applications: [:kernel]"
# warnings. The warning is harmless but pollutes stderr; for release
# builds the config is consulted before :kernel boots, so the
# assignment takes.
if Mix.env() == :prod do
  config :kernel, :logger, [
    {:handler, :default, :logger_std_h,
     %{config: %{type: :standard_error}}}
  ]
end
