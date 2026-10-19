defmodule Mix.Pharos.ReleaseSteps do
  @moduledoc """
  The release steps after Mix's `:assemble` (ADR-035): trim the runtime, put the native shim in
  as `bin/pharos`, check what the native files link, and pack the release for one target.

  `trim_release/1`, `check_native/1` and the parsers under them are ported from geex's
  `Mix.Tasks.Geex.Deploy` (geex ADR-0041 §1, §3, at geex c7e4f76), so the two apps ship by the
  same rules. Each step takes and returns the `%Mix.Release{}`.
  """

  @package "_build/package"

  # The VM programs a running pharos uses: the emulator, its launcher, the port-program forker
  # every LSP spawn goes through, and the resolver it starts on a host lookup.
  @erts_keep ~w(beam.smp erlexec erl_child_setup inet_gethost)

  # Test scaffolding never loaded: crypto's test engine links libcrypto on its own.
  @release_drop ["lib/crypto-*/priv/lib/otp_test_engine.so"]

  # What a Linux release may link: glibc's own libraries, and libgcc_s, GCC's unwinder, which
  # the shim's Rust std links and every glibc system has.
  @linux_system ~w(libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1
                   ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 libgcc_s.so.1)

  # The oldest glibc the Linux release supports: Ubuntu 22.04's, where it is built.
  @glibc_floor {2, 35}

  @doc """
  Empty the release directory before `:assemble`. `--overwrite` leaves an earlier build's
  `erts-*` and `releases/<version>/` in place, and they would ship in the package.
  """
  def clean(%Mix.Release{path: path} = release) do
    File.rm_rf!(path)
    release
  end

  @doc """
  Drop the VM programs pharos never runs and strip the ones it does (`strip -S`, GNU's and
  Apple's alike; re-signed ad hoc on macOS, where a strip breaks the linker's signature and
  Apple silicon kills the program), drop test scaffolding, and remove Mix's own launch scripts
  and the distribution cookie: the shim replaces the scripts, pharos never starts
  distribution, and a published cookie is everyone's. Windows keeps its runtime whole.
  """
  def trim_release(%Mix.Release{path: path, version: version} = release) do
    unless windows?() do
      [bin] = Path.wildcard(Path.join(path, "erts-*/bin"))
      trim_erts(bin, System.find_executable("strip"))
    end

    for pattern <- @release_drop, file <- Path.wildcard(Path.join(path, pattern)),
        do: File.rm!(file)

    rel = Path.join(path, "releases/#{version}")

    scripts =
      [Path.join(path, "bin"), Path.join(path, "releases/COOKIE")] ++
        for f <- ~w(elixir elixir.bat iex iex.bat env.sh env.bat remote.vm.args
                    start_clean.boot start_clean.script),
            do: Path.join(rel, f)

    Enum.each(scripts, &File.rm_rf!/1)
    release
  end

  @doc false
  def trim_erts(bin, strip) do
    for f <- File.ls!(bin), f not in @erts_keep, do: File.rm_rf!(Path.join(bin, f))
    kept = for f <- @erts_keep, File.exists?(Path.join(bin, f)), do: Path.join(bin, f)

    if strip do
      {_, 0} = System.cmd(strip, ["-S" | kept], stderr_to_stdout: true)
      if darwin?(), do: sign(kept)
    else
      Mix.shell().info("[pharos] no `strip` on the PATH; the VM keeps its debug information")
    end
  end

  @doc """
  Build the shim (ADR-034) with cargo and install it as `bin/pharos` (`bin/pharos.exe`).
  """
  def build_shim(%Mix.Release{path: path} = release) do
    cargo = System.find_executable("cargo") || Mix.raise("[pharos] cargo is not on the PATH")

    {out, status} =
      System.cmd(cargo, ["build", "--release", "--manifest-path", "shim/Cargo.toml"],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("[pharos] cargo build failed:\n" <> out)

    exe = if windows?(), do: "pharos.exe", else: "pharos"
    dest = Path.join([path, "bin", exe])
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(Path.join("shim/target/release", exe), dest)
    File.chmod!(dest, 0o755)
    if darwin?(), do: sign([dest])
    release
  end

  @doc """
  Fail a release build (`PHAROS_RELEASE=1`) on any native file the release can't count on
  where it runs (`native_problems/2`). A local build, which carries whatever OTP built it and
  runs only here, gets a note.
  """
  def check_native(%Mix.Release{path: path} = release) do
    case native_problems(path, :os.type()) do
      [] ->
        Mix.shell().info("[pharos] native check passed")

      problems ->
        message = "the release's native code " <> Enum.join(problems, "; ")

        if System.get_env("PHAROS_RELEASE") == "1",
          do: Mix.raise("[pharos] " <> message),
          else: Mix.shell().info("[pharos] (a local build, so only a note) " <> message)
    end

    release
  end

  @doc """
  Write `BUILD_ID`, pack the release as `_build/package/pharos-<version>-<target>.tar.gz`
  (a `.zip` on Windows) with a top directory of the same name and a `SHA256SUMS` beside it,
  and copy it into its npm platform package's `release/`.
  """
  def package(%Mix.Release{path: path, version: version} = release) do
    File.write!(Path.join(path, "BUILD_ID"), build_id(path) <> "\n")

    out = Path.expand(@package)
    File.rm_rf!(out)
    File.mkdir_p!(out)
    name = "pharos-#{version}-#{target()}"
    staged = Path.join(out, name)
    File.cp_r!(path, staged)

    archive =
      if windows?() do
        file = "#{name}.zip"
        files = staged |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)

        {:ok, _} =
          :zip.create(String.to_charlist(file), Enum.map(files, &String.to_charlist(Path.relative_to(&1, out))),
            cwd: String.to_charlist(out)
          )

        file
      else
        file = "#{name}.tar.gz"

        {_, 0} =
          System.cmd("tar", ["-C", out, "-czf", file, name],
            cd: out,
            env: [{"COPYFILE_DISABLE", "1"}],
            stderr_to_stdout: true
          )

        file
      end

    File.rm_rf!(staged)
    sha = :crypto.hash(:sha256, File.read!(Path.join(out, archive))) |> Base.encode16(case: :lower)
    File.write!(Path.join(out, "SHA256SUMS"), "#{sha}  #{archive}\n")

    npm = Path.join(["npm", "@pharos-mcp", npm_platform(), "release"])
    File.rm_rf!(npm)
    File.cp_r!(path, npm)

    Mix.shell().info("[pharos] packed #{Path.join(out, archive)} and #{npm}")
    release
  end

  @doc """
  `BUILD_ID` (ADR-034): the first 16 hex digits of a SHA-256 over every file of the release
  (ERTS, `lib/`, `releases/`, the shim), each as its digest and its path relative to the
  release, so the id moves with any byte and not with the directory.
  """
  def build_id(path) do
    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, path))
    |> Enum.reject(&(&1 == "BUILD_ID"))
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn rel, acc ->
      digest = :crypto.hash(:sha256, File.read!(Path.join(path, rel))) |> Base.encode16(case: :lower)
      :crypto.hash_update(acc, "#{digest}  #{rel}\n")
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  The release's target, `<os>-<arch>`: `linux`, `darwin` or `win32`, and `x64` or `arm64`, from
  the VM that built it (each target builds on its own runner, ADR-035 §2).

      iex> Mix.Pharos.ReleaseSteps.target({:unix, :linux}, "aarch64-unknown-linux-gnu")
      "linux-arm64"

      iex> Mix.Pharos.ReleaseSteps.target({:unix, :darwin}, "x86_64-apple-darwin24.6.0")
      "darwin-x64"

      iex> Mix.Pharos.ReleaseSteps.target({:win32, :nt}, "win32")
      "win32-x64"
  """
  def target, do: target(:os.type(), to_string(:erlang.system_info(:system_architecture)))

  def target(os_type, architecture) do
    os =
      case os_type do
        {:unix, :linux} -> "linux"
        {:unix, :darwin} -> "darwin"
        {:win32, _} -> "win32"
      end

    arch =
      cond do
        String.starts_with?(architecture, ["aarch64", "arm64"]) -> "arm64"
        os == "win32" -> "x64"
        String.starts_with?(architecture, ["x86_64", "amd64"]) -> "x64"
      end

    "#{os}-#{arch}"
  end

  # The npm platform package a target ships in: Windows is `win-x64` there (its name predates
  # the tarball convention, and trusted publishing pins it).
  defp npm_platform do
    case target() do
      "win32-" <> arch -> "win-" <> arch
      other -> other
    end
  end

  @doc """
  What in the release at `rel` it can't count on where it runs, on the OS `os_type`:

    * on Linux, a shared library outside `@linux_system` that a VM program, a NIF or the shim
      links, or a glibc symbol newer than the 2.35 floor;
    * on macOS, a library outside the OS (`/usr/lib`, `/System/Library`), or a Mach-O whose code
      signature doesn't verify.

  `[]` when there's nothing. Windows is not checked.
  """
  def native_problems(rel, os_type) do
    for file <- native_files(rel), problem <- file_problems(file, os_type) do
      "#{Path.relative_to(file, rel)} #{problem}"
    end
  end

  defp native_files(rel) do
    Path.wildcard(Path.join(rel, "erts-*/bin/*")) ++
      Path.wildcard(Path.join(rel, "lib/*/priv/**/*.so")) ++
      Path.wildcard(Path.join(rel, "bin/pharos"))
  end

  defp file_problems(_file, {:win32, _}), do: []

  defp file_problems(file, {:unix, :darwin}) do
    {otool, 0} = System.cmd("otool", ["-L", file], stderr_to_stdout: true)
    {id, _} = System.cmd("otool", ["-D", file], stderr_to_stdout: true)

    foreign =
      for lib <- otool_libraries(otool) -- otool_id(id),
          not String.starts_with?(lib, ["/usr/lib/", "/System/Library/"]),
          do: "links #{lib}"

    case System.cmd("codesign", ["--verify", "--strict", file], stderr_to_stdout: true) do
      {_, 0} -> foreign
      {out, _} -> foreign ++ ["has no valid code signature: #{String.trim(out)}"]
    end
  end

  defp file_problems(file, _linux) do
    {dynamic, 0} = System.cmd("readelf", ["-d", file], stderr_to_stdout: true)
    {symbols, 0} = System.cmd("readelf", ["-W", "--dyn-syms", file], stderr_to_stdout: true)

    foreign = for lib <- elf_needed(dynamic), lib not in @linux_system, do: "links #{lib}"

    case glibc_needed(symbols) do
      newer when newer > @glibc_floor ->
        {major, minor} = newer
        foreign ++ ["needs glibc #{major}.#{minor}, newer than the 2.35 floor"]

      _ ->
        foreign
    end
  end

  @doc """
  The libraries in `readelf -d`'s output (its `NEEDED` entries).

      iex> Mix.Pharos.ReleaseSteps.elf_needed(\"""
      ...>  0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]
      ...>  0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
      ...>  0x000000000000000e (SONAME)             Library soname: [x.so]
      ...> \""")
      ["libgcc_s.so.1", "libc.so.6"]
  """
  def elf_needed(readelf) do
    for [_, lib] <- Regex.scan(~r/\(NEEDED\)\s+Shared library: \[([^\]]+)\]/, readelf), do: lib
  end

  @doc """
  The newest glibc symbol version named in `readelf --dyn-syms`'s output, or `{0, 0}`.

      iex> Mix.Pharos.ReleaseSteps.glibc_needed(\"""
      ...>      1: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND memcpy@GLIBC_2.14 (2)
      ...>      2: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND pthread_create@GLIBC_2.34 (3)
      ...>      3: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND free@GLIBC_2.2.5 (4)
      ...> \""")
      {2, 34}
  """
  def glibc_needed(readelf) do
    Regex.scan(~r/@GLIBC_(\d+)\.(\d+)/, readelf)
    |> Enum.map(fn [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)} end)
    |> Enum.max(fn -> {0, 0} end)
  end

  @doc """
  A Mach-O's own install name, from `otool -D`'s output (none for a program or a bundle). A
  dylib's `otool -L` lists it first, as if it linked itself.

      iex> Mix.Pharos.ReleaseSteps.otool_id(\"""
      ...> lib/x-1.0/priv/x.so:
      ...> /Users/runner/work/x/target/release/deps/libx.dylib
      ...> \""")
      ["/Users/runner/work/x/target/release/deps/libx.dylib"]

      iex> Mix.Pharos.ReleaseSteps.otool_id("erts-16.1.1/bin/beam.smp:\\n")
      []
  """
  def otool_id(otool) do
    otool |> String.split("\n", trim: true) |> Enum.drop(1) |> Enum.map(&String.trim/1)
  end

  @doc """
  The libraries in `otool -L`'s output: each indented line's path.

      iex> Mix.Pharos.ReleaseSteps.otool_libraries(\"""
      ...> erts/bin/beam.smp:
      ...> \t/usr/lib/libncurses.5.4.dylib (compatibility version 5.4.0, current version 5.4.0)
      ...> \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
      ...> \""")
      ["/usr/lib/libncurses.5.4.dylib", "/usr/lib/libSystem.B.dylib"]
  """
  def otool_libraries(otool) do
    for line <- String.split(otool, "\n"),
        String.starts_with?(line, "\t"),
        do: line |> String.trim() |> String.replace(~r/ \(compatibility version.*\)$/, "")
  end

  defp sign(files) do
    {_, 0} = System.cmd("codesign", ["-s", "-", "-f" | files], stderr_to_stdout: true)
  end

  defp darwin?, do: :os.type() == {:unix, :darwin}
  defp windows?, do: match?({:win32, _}, :os.type())
end
