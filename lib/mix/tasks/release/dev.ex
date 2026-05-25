defmodule Mix.Tasks.Release.Dev do
  @moduledoc """
  Local Burrito rebuild for development.

  Wipes the Burrito runtime cache and rebuilds every target. The
  cache wipe is the load-bearing step: Burrito keys its extracted
  release directory by `pharos_erts-<otp>_<vsn>`, so without a
  bump the wrapper binary is replaced but the inner BEAM bundle
  on disk at `~/.local/share/.burrito/<key>/` is reused. Result:
  the new binary executes the OLD code. The wipe forces re-
  extraction on next launch.

  Use this for every dev-time rebuild that does NOT bump the
  version. For released builds use `mix release.prod <vsn>`.

  After this task completes, reconnect `/mcp` in Claude Code (or
  any MCP host) so it spawns the fresh binary.
  """

  use Mix.Task

  @shortdoc "Wipe Burrito cache + rebuild all targets at current version"

  @impl Mix.Task
  def run(_args) do
    wipe_burrito_cache()
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
    Mix.shell().info("[release.dev] binaries written to burrito_out/")
    Mix.shell().info("[release.dev] reconnect /mcp in Claude Code to pick up the new binary")
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

  defp wipe_burrito_cache do
    cache_root = Path.join([System.user_home!(), ".local", "share", ".burrito"])
    case File.ls(cache_root) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          # Only wipe dev-build caches. Dev versions always contain `+`
          # (the build_suffix from mix.exs); release/rc caches never do
          # (clean SemVer or `-rc1` suffix). Preserves any globally-
          # installed npm rc/release pharos so dev rebuilds don't force
          # the user's other pharos to re-extract.
          if String.starts_with?(entry, "pharos_") and String.contains?(entry, "+") do
            full = Path.join(cache_root, entry)
            Mix.shell().info("[release.dev] wiping Burrito cache: #{full}")
            File.rm_rf!(full)
          end
        end)

      {:error, _} ->
        Mix.shell().info("[release.dev] no Burrito cache present, skipping wipe")
    end
  end
end
