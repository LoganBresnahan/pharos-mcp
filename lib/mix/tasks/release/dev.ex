defmodule Mix.Tasks.Release.Dev do
  @moduledoc """
  Local release rebuild for development (ADR-035): a clean
  `_build/prod`, then `mix release`, which packs this machine's
  target into `_build/package/` and leaves a runnable release at
  `_build/prod/rel/pharos` (`bin/pharos` is the shim).

  Nothing is extracted at run time any more, so there is no cache to
  wipe: a rebuild gets a new BUILD_ID, and with it its own daemon
  (ADR-034). This task used to delete pharos's Burrito unpacks under
  `~/.local/share/.burrito/`, which running 0.1.x sessions use; it no
  longer touches anything outside the repo.

  After this task completes, install the package (the printed
  install.sh line) and reconnect `/mcp` in Claude Code, or point an
  MCP host at `_build/prod/rel/pharos/bin/pharos`. For released builds
  use `mix release.prod <vsn>`.
  """

  use Mix.Task

  @shortdoc "Clean rebuild of this machine's release at the current version"

  @impl Mix.Task
  def run(_args) do
    wipe_prod_build()
    Mix.shell().info("[release.dev] running `mix do compile, release --overwrite`")

    # Single subprocess invocation chaining compile + release via
    # `mix do compile + release`. The `+` is mix's task separator;
    # both tasks share one Mix VM so the compile alias chain
    # (deps.compile + fix_app_names) fires before release walks
    # the application graph. Splitting into two `System.cmd` calls
    # does NOT work — the second `mix release` re-walks deps in
    # its own VM without re-firing the alias, and ADR-011's
    # `hpack` workaround does not survive the gap.
    # `clear_env: true` discards every env var the parent Mix VM is
    # leaking into our shell — particularly the implicit MIX_ENV
    # (set to whatever ran release.dev), MIX_BUILD_PATH, MIX_TARGET,
    # and MIX_DEPS_PATH. Without the wipe the subprocess inherits a
    # half-configured Mix environment that loads `_build/dev` lib
    # paths instead of `_build/prod`, the hpack alias never fires,
    # and `mix release` fails with "Could not find application
    # :hpack". With the wipe the subprocess sees a fresh environment
    # identical to running `MIX_ENV=prod mix do ...` from a vanilla
    # shell. PATH and HOME are restored explicitly because Erlang's
    # port spawn would otherwise lose them.
    parent_env = %{
      "PATH" => System.get_env("PATH") || "",
      "HOME" => System.get_env("HOME") || "",
      "USER" => System.get_env("USER") || "",
      "MIX_ENV" => "prod"
    }
    {_out, status} = System.cmd(
      "mix",
      ["do", "compile", "+", "release", "--overwrite"],
      env: Map.to_list(parent_env),
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    )
    if status != 0 do
      Mix.raise("[release.dev] build failed (exit #{status})")
    end

    Mix.shell().info("")
    Mix.shell().info("[release.dev] package written to _build/package/; install it with:")
    Mix.shell().info(
      "[release.dev]   PHAROS_DOWNLOAD_URL=file://$PWD/_build/package sh install.sh --force --version <version>"
    )
    Mix.shell().info("[release.dev] then reconnect /mcp in Claude Code")
  end

  # Second and later rebuilds without this wipe hit the
  # `Could not find application :hpack` failure: ADR-011's
  # fix_app_names alias only fires when deps.compile decides
  # there is something to compile. On a warm `_build/prod`,
  # deps.compile no-ops, the symlink + wrapper file may have
  # been disturbed (e.g. a prior partial release run rewrote
  # the dir), and `mix release` errors during application
  # graph walk. Always nuking `_build/prod` makes the dev
  # rebuild idempotent at the cost of ~30s of recompile.
  defp wipe_prod_build do
    if File.dir?("_build/prod") do
      Mix.shell().info("[release.dev] wiping _build/prod for a clean alias rerun")
      File.rm_rf!("_build/prod")
    end
  end
end
