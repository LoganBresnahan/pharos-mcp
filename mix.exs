defmodule Pharos.MixProject do
  use Mix.Project

  @app :pharos
  # SemVer base. First public release ships as 0.1.0 (OSS convention:
  # 0.x.y signals early-stage / breaking-change-allowed; 1.0.0 is
  # reserved for the stable-API promise).
  #
  # The effective version computed by `version/0` appends a SemVer
  # build-metadata suffix (`+<id>`) on every non-release build:
  #   - `PHAROS_BUILD_ID=<id>` env wins (CI / release pipeline).
  #   - Otherwise short git SHA, falling back to `local` outside git.
  #   - Set `PHAROS_RELEASE=1` to ship the clean base version
  #     (e.g. `0.1.0`) at tag time.
  #
  # Why this matters: Burrito names its extracted-runtime directory
  # `<release>_erts-<erts>_<app_version>/` and gates re-extraction on
  # that directory's existence (deps/burrito/src/wrapper.zig, `main` checking
  # `_metadata.json` under the dir from `get_install_dir`).
  # If two builds share the same version string, the second build
  # silently reuses the first build's extracted beam files — a known
  # foot-gun that bit us once during ADR-029 dogfood. Suffixing the
  # version per build forces a fresh extract automatically.
  @version_base "0.1.4"

  defp version do
    case System.get_env("PHAROS_RELEASE") do
      "1" -> @version_base
      _ -> "#{@version_base}+#{build_suffix()}"
    end
  end

  defp build_suffix do
    case System.get_env("PHAROS_BUILD_ID") do
      nil ->
        case System.cmd("git", ["rev-parse", "--short=8", "HEAD"],
                        stderr_to_stdout: true) do
          {sha, 0} -> sha |> String.trim() |> sanitize_semver_suffix()
          _ -> "local"
        end

      build_id ->
        sanitize_semver_suffix(build_id)
    end
  end

  # SemVer 2.0.0 build metadata must match `[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*`.
  # Strip anything else; substitute `-` for forbidden chars to keep a
  # readable suffix even when callers pass tag refs or branch names.
  defp sanitize_semver_suffix(raw) do
    raw
    |> String.replace(~r/[^0-9A-Za-z.-]/, "-")
    |> case do
      "" -> "local"
      s -> s
    end
  end

  def project do
    [
      app: @app,
      version: version(),
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
      # `:crypto` — `pharos_session_ffi:generate_session_id/0` uses
      # `crypto:strong_rand_bytes/1` for HTTP `Mcp-Session-Id`s. Under
      # `mix release` (Burrito), apps not listed here are stripped, so
      # the runtime sees `Undef` on the first crypto call when pharos
      # boots in `PHAROS_TRANSPORT=http` mode. Surfaced as HTTP 500
      # on the first POST /mcp under release runtime; works under dev
      # runtime where crypto is loaded by default.
      extra_applications: [:logger, :crypto]
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
      # Pinned transitive (pollux -> oas_generator_utils -> gleam_javascript).
      # 1.0.1 is byte-identical to 1.0.0 in `src/` — the only change is its
      # gleam.toml raising `gleam = ">= 0.32.0"` to `">= 1.13.0"`. That bump
      # is nonetheless enough to break us: on 1.0.1 the erlang-target build of
      # `oas_generator_utils` fails to resolve `gleam/javascript/array` ("No
      # module has been found with the name `array`"), deterministically and
      # from a clean tree; on 1.0.0 it builds. The package declares
      # `target = "javascript"` in BOTH versions, so that alone is not the
      # trigger — the precise mechanism is unconfirmed, only the pass/fail
      # boundary is. Retest on the next gleam_javascript or
      # oas_generator_utils release; unpin if it builds clean.
      {:gleam_javascript, "1.0.0", override: true},
      {:gleeunit, "~> 1.10", only: [:dev, :test], runtime: false},
      {:qcheck, "~> 1.0", only: [:dev, :test], runtime: false},
      # A fork of Burrito v1.5.0, not hex. Fork-only: nothing goes upstream.
      # Upstream 1.5.0 crashes running pharos servers on a version bump: every
      # launch deletes all semver-older unpacks with no in-use check, and the
      # launcher passed `"-mode embedded"` as one argv element, so the VM ran
      # interactive and lazy-loaded modules from the unpack being deleted.
      # The fork (see FORK.md on the branch) boots embedded for real, skips
      # any unpack whose `.burrito-in-use` flock is held, keeps the
      # wrapper's own log lines off stdout, and adds `maintenance purge`,
      # which `pharos --purge-cache` delegates to.
      #
      # Still 1.5.x underneath, deliberately: Burrito 1.6.0 raises its
      # required Zig to 0.16.0 (`Burrito.check_zig_version/0`), while our
      # release toolchain — and the `mlugg/setup-zig` pin in
      # .github/workflows/release.yml — is 0.15.2. Under 1.6.0 the compile and
      # assemble steps both succeed and only the wrap step fails, so the
      # breakage is invisible to `mix gleam.test` and only shows up at release
      # time. Rebasing the fork onto 1.6.0 means bumping Zig to 0.16.0 and
      # re-verifying all five cross-compiled targets; that is its own work.
      {:burrito,
       github: "LoganBresnahan/burrito",
       ref: "4407714f192e47c0e3b4794a8f16d8f3fdbe93f4",
       runtime: false}
    ]
  end

  defp releases do
    [
      pharos: [
        steps: release_steps()
      ]
    ]
  end

  # ADR-035: after Mix assembles the release, trim the runtime, install
  # the native shim (ADR-034) as bin/pharos, check what every native file
  # links, and pack `_build/package/pharos-<version>-<target>.tar.gz` plus
  # the target's npm platform package. Each target builds on its own
  # runner (no cross-compilation), so the steps act on the VM running Mix.
  # See lib/mix/pharos/release_steps.ex.
  defp release_steps do
    [
      &prepend_mirror_paths/1,
      &Mix.Pharos.ReleaseSteps.clean/1,
      :assemble,
      &check_boot_script/1,
      &Mix.Pharos.ReleaseSteps.trim_release/1,
      &Mix.Pharos.ReleaseSteps.build_shim/1,
      &Mix.Pharos.ReleaseSteps.check_native/1,
      &Mix.Pharos.ReleaseSteps.package/1
    ]
  end

  # Re-run the ADR-011 path fix immediately before :assemble. The
  # `deps.compile` alias already prepended the mirror dirs, but by the
  # time the release task reaches assembly Mix has re-prepended every
  # dep's ebin, so `hpack_erl/ebin` sits ahead of `hpack/ebin` again
  # (observed: index 7 vs 34) and systools would resolve hpack's boot
  # path from the wrong dir. See ensure_mirror_paths/3.
  defp prepend_mirror_paths(release) do
    fix_app_names([])
    release
  end

  # Fail the release if the generated boot script cannot boot in
  # embedded mode. Embedded boot executes every `{primLoad, Mods}` in
  # `start.script` against the `{path, Dirs}` preceding it, and a
  # single module not found under those dirs aborts with
  # `{load_failed, Mods}`. Interactive mode never exercises primLoad,
  # so a broken path stays invisible until the VM runs embedded for
  # real — which is what happened to hpack: the boot script pointed at
  # `$RELEASE_LIB/hpack_erl/ebin/hpack-0.3.0/ebin`, a dir that does not
  # exist in the assembled release (see ensure_mirror_paths/3 and
  # doc/adr/011-mix-app-name-symlink-workaround.md). Runs before
  # the shim build and packaging, so the failure lands in seconds.
  defp check_boot_script(release) do
    script =
      Path.join([release.path, "releases", release.version, "start.script"])

    {:ok, [{:script, _, instructions}]} =
      :file.consult(String.to_charlist(script))

    expand = fn dir ->
      dir
      |> List.to_string()
      |> String.replace("$ROOT", release.path)
      |> String.replace("$RELEASE_LIB", Path.join(release.path, "lib"))
    end

    {_, problems} =
      Enum.reduce(instructions, {[], []}, fn
        {:path, dirs}, {_, acc} ->
          dirs = Enum.map(dirs, expand)
          missing = for d <- dirs, not File.dir?(d), do: "missing path #{d}"
          {dirs, acc ++ missing}

        {:primLoad, mods}, {dirs, acc} ->
          unloadable =
            for m <- mods,
                beam = "#{m}.beam",
                not Enum.any?(dirs, &File.regular?(Path.join(&1, beam))),
                do: "unloadable module #{m}"

          {dirs, acc ++ unloadable}

        _, state ->
          state
      end)

    case Enum.uniq(problems) do
      [] ->
        Mix.shell().info("[pharos] start.script boot check passed")
        release

      problems ->
        Mix.raise(
          "[pharos] start.script would not boot in embedded mode:\n  " <>
            Enum.join(problems, "\n  ")
        )
    end
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
      {:ok, deps} ->
        Enum.each(deps, &fix_dep_app_name(build_lib, &1))
        retarget_wrapper_consumers(build_lib, deps)

      {:error, _} ->
        :ok
    end
  end

  # Point every dep `.app` that lists a wrapper (`hpack_erl`) at the
  # real OTP app (`hpack`) instead. `mix release` builds its app list
  # from these files, and a consumer naming the wrapper puts the empty
  # wrapper app in the release. systools then finds `hpack_erl.app`
  # first through the `hpack` mirror (a symlink to `hpack_erl`, so it
  # holds both `.app` files), cannot strip a dir named for another app,
  # and emits `$RELEASE_LIB/hpack/ebin/hpack_erl-0.3.0/ebin`: an
  # unbootable boot script. Whether mix_gleam writes `hpack_erl` or
  # `hpack` into mist.app varied between builds (a fresh CI checkout
  # got the former, an old local _build the latter), so this makes it
  # deterministic: no consumer names a wrapper, and no wrapper ships.
  defp retarget_wrapper_consumers(build_lib, deps) do
    real_deps = Enum.reject(deps, &(File.read_link(Path.join(build_lib, &1)) |> elem(0) == :ok))

    wrappers =
      for dep <- real_deps,
          app = Path.join([build_lib, dep, "ebin", "#{dep}.app"]),
          wrapper_app?(app),
          {:ok, [{:application, _, props}]} = :file.consult(String.to_charlist(app)),
          {:applications, apps} = List.keyfind(props, :applications, 0),
          into: %{},
          do: {String.to_atom(dep), List.last(apps)}

    if wrappers != %{} do
      for dep <- real_deps,
          app <- Path.wildcard(Path.join([build_lib, dep, "ebin", "*.app"])),
          not wrapper_app?(app),
          do: retarget_app_file(app, wrappers)
    end
  end

  defp retarget_app_file(path, wrappers) do
    {:ok, [{:application, name, props}]} = :file.consult(String.to_charlist(path))

    case List.keyfind(props, :applications, 0) do
      {:applications, apps} ->
        retargeted = Enum.map(apps, &Map.get(wrappers, &1, &1))

        if retargeted != apps do
          props = List.keystore(props, :applications, 0, {:applications, retargeted})
          File.write!(path, :io_lib.format("~p.~n", [{:application, name, props}]))
        end

      nil ->
        :ok
    end
  end

  defp fix_dep_app_name(build_lib, dep_name) do
    ebin = Path.join([build_lib, dep_name, "ebin"])
    expected = Path.join(ebin, "#{dep_name}.app")

    cond do
      not File.dir?(ebin) ->
        :ok

      wrapper_app?(expected) ->
        # Wrapper .app already in place from a prior run. The symlink
        # mirror dir likely also exists on disk, but `:code.add_patha`
        # only persists for the lifetime of one Mix VM invocation —
        # subsequent `mix release` runs (separate VMs) can't resolve
        # the OTP-named app unless we re-add the path here.
        ensure_mirror_paths(build_lib, ebin, dep_name)

      File.exists?(expected) ->
        # A real app — or the OTP-named mirror itself (`hpack` ->
        # `hpack_erl`), which shows the wrapper's `hpack_erl.app`
        # through the link. Mirroring from it would put `hpack_erl/ebin`
        # back at the head of the code path; see ensure_mirror_paths/3.
        :ok

      true ->
        alias_app_if_unambiguous(ebin, expected, dep_name)
    end
  end

  # Re-add OTP-name mirror dirs to the VM's code path on every Mix
  # invocation, regardless of whether the wrapper .app was already
  # present. Walks every .app file in the dep's ebin and resolves any
  # otp_name != dep_name as a symlink target whose ebin should be on
  # the path. Idempotent — `:code.add_patha` is safe to call multiple
  # times with the same path.
  #
  # `add_patha` (prepend), not `add_pathz`: systools resolves each
  # app's boot-script path from the first code-path dir holding its
  # `.app`. With the mirror appended, `hpack.app` is found under
  # `<lib>/hpack_erl/ebin`, systools cannot strip a dir whose name is
  # not the app's, and the boot script gets
  # `$RELEASE_LIB/hpack_erl/ebin/hpack-0.3.0/ebin` — a path the
  # assembled release does not contain. Interactive mode shrugs that
  # off; embedded mode aborts boot. Prepending makes systools see
  # `<lib>/hpack/ebin` and emit `$RELEASE_LIB/hpack-0.3.0/ebin`.
  # check_boot_script/1 enforces the result at release time.
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

          :code.add_patha(otp_ebin)
        end
      end
    end)
  end

  defp wrapper_app?(path) do
    with {:ok, [{:application, _, props}]} <-
           :file.consult(String.to_charlist(path)),
         {:description, desc} <- List.keyfind(props, :description, 0) do
      desc |> to_string() |> String.starts_with?("Workaround alias for hex package")
    else
      _ -> false
    end
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
      # Prepended for the boot-script reason in ensure_mirror_paths/3.
      otp_ebin = Path.join(otp_dir, "ebin") |> String.to_charlist()
      :code.add_patha(otp_ebin)
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
