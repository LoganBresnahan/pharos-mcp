defmodule Pharos.MixProject do
  use Mix.Project

  @app :pharos
  @version "0.0.1"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [mix_gleam: "~> 0.7"],
      compilers: [:gleam | Mix.compilers()],
      erlc_paths: ["build/dev/erlang/#{@app}/_gleam_artefacts"],
      erlc_include_path: "build/dev/erlang/#{@app}/include",
      prune_code_paths: false,
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      start_permanent: Mix.env() == :prod
    ]
  end

  def application do
    [
      # `auto_boot: false` in :test so gleeunit suites can spin up
      # their own scoped supervisor / writer / pool instances without
      # racing the application's own root tree. Production and dev
      # paths boot the supervisor here so OTP application_controller
      # treats it as the application's primary process — which
      # `runtime_supervision_tree` walks to render pharos's tree
      # (limitation 2a from the M9.5 dogfood).
      mod: {:pharos_app_ffi, [auto_boot: Mix.env() != :test]},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:gleam_stdlib, "~> 1.0"},
      {:gleam_otp, "~> 1.2"},
      {:gleam_erlang, "~> 1.3"},
      {:gleam_json, "~> 3.1"},
      {:gleam_http, "~> 4.0"},
      {:mist, "~> 6.0"},
      {:pollux, "~> 1.0"},
      {:recon, "~> 2.5"},
      {:tomerl, "~> 0.5"},
      {:gleeunit, "~> 1.10", only: [:dev, :test], runtime: false},
      {:qcheck, "~> 1.0", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.5", runtime: false}
    ]
  end

  defp releases do
    [
      pharos: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            darwin_x64: [os: :darwin, cpu: :x86_64],
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            win_x64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp aliases do
    [
      "deps.get": ["deps.get", "gleam.deps.get"],
      # `&fix_app_names/1` works around hex package name vs OTP
      # application name mismatches in transitive deps (e.g. `hpack_erl`
      # whose OTP app is `hpack`). The fix runs after the original
      # `deps.compile` so missing `<hex_name>.app` files get aliased
      # before Mix's later validation step. Defined inline in mix.exs
      # rather than in lib/mix/tasks/ because lib/ is not compiled
      # until after dep validation passes — chicken-and-egg.
      #
      # `compile` is also aliased so that running `mix compile`,
      # `mix test`, or `mix release` from clean state triggers
      # `deps.compile` (and its alias chain) before the compile
      # task's own validation runs. Without this, Mix's internal
      # `Mix.Task.run("deps.compile")` from within `compile` does
      # not consult aliases, so the fix never fires. Two-step
      # `mix do deps.compile, compile` would also work but adds
      # cognitive overhead.
      #
      # Remove these alias entries and the helper functions below
      # when upstream Gleam ships the publish fix and affected deps
      # republish. See doc/adr/011-mix-app-name-symlink-workaround.md
      "deps.compile": ["deps.compile", &fix_app_names/1],
      compile: ["deps.compile", "compile"],
      # `mix start` invokes pharos:main/0 directly. The OTP application
      # callback (pharos_app_ffi:start/2) only auto-spawns main when
      # __BURRITO is set, so this -e path runs main exactly once. mix
      # run still loads applications (so the pool actor and other
      # children are running) — main is on top of that.
      start: ["run -e \":pharos.main()\""],
    ]
  end

  # See doc/adr/011-mix-app-name-symlink-workaround.md
  defp fix_app_names(_args) do
    build_lib = Path.join([Mix.Project.build_path(), "lib"])

    case File.ls(build_lib) do
      {:ok, deps} -> Enum.each(deps, &fix_dep_app_name(build_lib, &1))
      {:error, _} -> :ok
    end
  end

  defp fix_dep_app_name(build_lib, dep_name) do
    ebin = Path.join([build_lib, dep_name, "ebin"])
    expected = Path.join(ebin, "#{dep_name}.app")

    cond do
      not File.dir?(ebin) ->
        :ok

      File.exists?(expected) ->
        # Wrapper .app already in place from a prior run. The symlink
        # mirror dir likely also exists on disk, but `:code.add_pathz`
        # only persists for the lifetime of one Mix VM invocation —
        # subsequent `mix release` runs (separate VMs) can't resolve
        # the OTP-named app unless we re-add the path here.
        ensure_mirror_paths(build_lib, ebin, dep_name)

      true ->
        alias_app_if_unambiguous(ebin, expected, dep_name)
    end
  end

  # Re-add OTP-name mirror dirs to the VM's code path on every Mix
  # invocation, regardless of whether the wrapper .app was already
  # present. Walks every .app file in the dep's ebin and resolves any
  # otp_name != dep_name as a symlink target whose ebin should be on
  # the path. Idempotent — `:code.add_pathz` is safe to call multiple
  # times with the same path.
  defp ensure_mirror_paths(build_lib, ebin, dep_name) do
    Path.join(ebin, "*.app")
    |> Path.wildcard()
    |> Enum.each(fn actual ->
      otp_name = Path.basename(actual, ".app")

      if otp_name != dep_name do
        otp_dir = Path.join(build_lib, otp_name)

        if File.exists?(otp_dir) do
          otp_ebin =
            otp_dir
            |> Path.join("ebin")
            |> String.to_charlist()

          :code.add_pathz(otp_ebin)
        end
      end
    end)
  end

  defp alias_app_if_unambiguous(ebin, expected, dep_name) do
    case Path.wildcard(Path.join(ebin, "*.app")) do
      [actual] ->
        otp_name = Path.basename(actual, ".app")

        Mix.shell().info(
          "[pharos] aliasing #{dep_name}.app -> #{otp_name}.app " <>
            "(hex name differs from OTP app name)"
        )

        write_wrapper_app(actual, expected, dep_name, otp_name)
        mirror_dep_dir_under_otp_name(ebin, dep_name, otp_name)

      _ ->
        :ok
    end
  end

  # `mix release` walks the application graph and resolves each dep by
  # its OTP application name, expecting `_build/<env>/lib/<otp_name>/ebin/
  # <otp_name>.app`. The wrapper above only patches the hex-named ebin
  # dir; release still fails with "Could not find application :<otp_name>"
  # because no `_build/.../<otp_name>/` directory exists. Mirror the dep's
  # build directory under the OTP name as a symlink (or copy on Windows)
  # so release-time path resolution succeeds. The mirror points at the
  # same beam files, so updates to one are visible through the other.
  defp mirror_dep_dir_under_otp_name(ebin, dep_name, otp_name) do
    if dep_name != otp_name do
      build_lib = Path.dirname(Path.dirname(ebin))
      otp_dir = Path.join(build_lib, otp_name)

      unless File.exists?(otp_dir) do
        if File.ln_s(dep_name, otp_dir) != :ok do
          File.cp_r!(Path.join(build_lib, dep_name), otp_dir)
        end
      end

      # Ensure the mirror dir is on the running VM's code path so
      # `:code.lib_dir/1` (used by `mix release` to resolve apps) finds
      # it. Without this step, the symlink is in place on disk but the
      # application controller never sees it because Mix only adds
      # paths for known deps and `<otp_name>` is not a declared dep.
      otp_ebin = Path.join(otp_dir, "ebin") |> String.to_charlist()
      :code.add_pathz(otp_ebin)
    end
  end

  # The wrapper file declares an empty application named after the hex
  # package name that depends on the real OTP application. This satisfies
  # Mix's `validate_app/1` filename check while leaving the runtime
  # application graph correct: starting `hpack_erl` cascades to start
  # `hpack` (which holds the actual modules), and consumers that
  # reference `hpack` directly (as mist's compiled `.app` does) skip the
  # wrapper entirely.
  defp write_wrapper_app(actual_path, expected_path, dep_name, otp_name) do
    vsn = read_app_vsn(actual_path)

    contents = """
    {application, #{dep_name},
      [{description, "Workaround alias for hex package #{dep_name} (real OTP app: #{otp_name}). Generated by mix.exs fix_app_names. See doc/adr/011-mix-app-name-symlink-workaround.md"},
       {vsn, "#{vsn}"},
       {registered, []},
       {applications, [kernel, stdlib, #{otp_name}]},
       {env, []},
       {modules, []}]}.
    """

    File.write!(expected_path, contents)
  end

  defp read_app_vsn(path) do
    {:ok, [{:application, _, props}]} = :file.consult(String.to_charlist(path))

    case List.keyfind(props, :vsn, 0) do
      {:vsn, vsn} when is_list(vsn) -> List.to_string(vsn)
      {:vsn, vsn} when is_binary(vsn) -> vsn
      _ -> "0.0.0"
    end
  end
end
