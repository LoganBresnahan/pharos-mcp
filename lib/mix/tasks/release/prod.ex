defmodule Mix.Tasks.Release.Prod do
  @moduledoc """
  Tagged release rebuild — bump version, commit, tag, build all
  targets.

  Usage:

      mix release.prod 0.1.0

  Steps performed:

    1. Refuse if the working tree has uncommitted changes
       (release tagging on dirty state would be a footgun).
    2. Replace the `@version_base "..."` attribute in `mix.exs` and
       the `version = "..."` line in `gleam.toml`. Both, because
       `mix.exs` drives the OTP application `vsn` that `pharos/version`
       reports and `gleam.toml` drives the Gleam compiler's view;
       shipping them out of sync is the bug 9b92aec fixed.
    3. `git commit -am "chore: release v<vsn>"`.
    4. `git tag v<vsn>`.
    5. `MIX_ENV=prod mix do compile, release --overwrite` — full
       multi-target Burrito build.

  Burrito's runtime extraction cache is keyed by version, so the
  new vsn means no cache wipe is needed: launching the binary will
  extract into a fresh `pharos_erts-<otp>_<new_vsn>` directory.

  Push the tag manually after verifying the binaries:

      git push && git push --tags
  """

  use Mix.Task

  @shortdoc "Bump version, commit, tag, build all targets at the new version"

  @impl Mix.Task
  def run([new_vsn]) do
    validate_vsn!(new_vsn)
    ensure_clean_git!()
    bump_mix_exs!(new_vsn)
    bump_gleam_toml!(new_vsn)
    commit_and_tag!(new_vsn)

    # Single subprocess invocation chaining compile + release via
    # `mix do compile + release`. See `release.dev` comment for
    # why splitting into two `System.cmd` calls breaks ADR-011's
    # `hpack` workaround.
    # Strip the parent Mix VM's env vars (MIX_BUILD_PATH, etc.) so
    # the subprocess sees a clean environment. See `release.dev`
    # for the underlying gotcha.
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
      Mix.raise("[release.prod] build failed (exit #{status})")
    end

    Mix.shell().info("")
    Mix.shell().info("[release.prod] v#{new_vsn} built. Verify burrito_out/ then run:")
    Mix.shell().info("[release.prod]   git push && git push --tags")
  end

  def run(_args) do
    Mix.raise("Usage: mix release.prod <new_version>")
  end

  defp validate_vsn!(vsn) do
    unless Regex.match?(~r/^\d+\.\d+\.\d+(-[\w.]+)?$/, vsn) do
      Mix.raise("Invalid semver: #{vsn}. Expected `MAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH-prerelease`.")
    end
  end

  defp ensure_clean_git! do
    {out, 0} = System.cmd("git", ["status", "--porcelain"])
    if String.trim(out) != "" do
      Mix.raise("Working tree has uncommitted changes. Commit or stash before tagging a release.")
    end
  end

  defp bump_mix_exs!(new_vsn) do
    path = "mix.exs"
    contents = File.read!(path)
    # Must track the attribute name in mix.exs. It was renamed
    # `@version` -> `@version_base` in d4e9058 (2026-05-21, the per-build
    # version suffix); this task was not updated with it, so the regex
    # matched nothing and every invocation raised here instead of bumping.
    # That rename landed four days BEFORE the v0.1.0 tag, so this task has
    # never successfully cut a release -- every tag from v0.1.0 through
    # v0.1.4 was bumped and tagged by hand, which is why no
    # "chore: release v<vsn>" commit (this task's signature) exists in the
    # history. Renaming the attribute again means updating this regex in
    # the same commit.
    updated =
      Regex.replace(~r/@version_base "\S+"/, contents, "@version_base \"#{new_vsn}\"",
        global: false
      )

    if updated == contents do
      Mix.raise("Could not locate `@version_base \"...\"` in #{path}.")
    end
    File.write!(path, updated)
    Mix.shell().info("[release.prod] mix.exs version -> #{new_vsn}")
  end

  defp bump_gleam_toml!(new_vsn) do
    path = "gleam.toml"
    if File.exists?(path) do
      contents = File.read!(path)
      updated = Regex.replace(~r/version = "\S+"/, contents, "version = \"#{new_vsn}\"", global: false)
      if updated == contents do
        Mix.raise("Could not locate `version = \"...\"` in #{path}.")
      end
      File.write!(path, updated)
      Mix.shell().info("[release.prod] gleam.toml version -> #{new_vsn}")
    end
  end

  defp commit_and_tag!(new_vsn) do
    {_, 0} = System.cmd("git", ["add", "mix.exs", "gleam.toml"])
    {_, 0} = System.cmd("git", ["commit", "-m", "chore: release v#{new_vsn}"])
    {_, 0} = System.cmd("git", ["tag", "v#{new_vsn}"])
    Mix.shell().info("[release.prod] committed + tagged v#{new_vsn}")
  end
end
