# 011. Local Mix.Task workaround for hex package name vs OTP application name mismatch

**Status:** Accepted
**Date:** 2026-05-04

## Context

Milestone 5 added `mist` as the HTTP transport. Mist (transitively) depends on `hpack_erl`, a hex package whose hex name (`hpack_erl`) differs from its OTP application name (`hpack`). The `pkg_name` field in `.app.src` exists in OTP exactly for this case, and rebar3 + `gleam build` both honor it. Mix does not.

When Mix runs `mix compile` against this project, its `Mix.Dep.Loader.validate_app/1` step builds the path `_build/<env>/lib/<dep.app>/ebin/<dep.app>.app` from the dep's atom (`dep.app == :hpack_erl`, taken from mist's published metadata). It looks for `_build/dev/lib/hpack_erl/ebin/hpack_erl.app`, finds none — the actual file written by rebar3 is `hpack.app` (named after the OTP application) — and refuses to compile. Helpful suggestion in the error message: "try changing the dependency name to `:hpack`."

Three layers contribute:

1. Mist's published Hex metadata writes the hex package name into the `app` field of each requirement entry instead of the OTP application name. The bug is on Gleam's `gleam publish` side, in `compiler-cli/src/publish.rs`. A fix has been drafted (see [gleam-fix.md](file:///home/oof/gleam-fix.md)) and the issue filed with `gleam-lang/gleam`.

2. `mix.lock` records what the Hex registry says, which is mist's broken metadata. Lock is authoritative for transitive resolution. Even if a future patched `mix_gleam` rewrites `deps/mist/mix.exs` correctly post-fetch, lock-level resolution still treats the dep as `:hpack_erl`.

3. Mix's `Mix.Dep.Loader` ignores `pkg_name` from `.app.src` (per [elixir-lang/elixir#10284 (2020)](https://github.com/elixir-lang/elixir/issues/10284), José Valim's stance is that consumers should use `{:otp_name, "...", hex: :hex_name}` syntax, putting the burden on whoever declares the dep — fine for direct deps, impossible for transitives whose declaration the consumer doesn't control).

The clean fix lives in Gleam's publish tooling. Until that fix lands and mist republishes with it (which also requires Hex's "no republishing same version" policy to be navigated via a new minor release), every consumer that uses Mix to build pharos hits this wall.

Milestone 6 (Burrito + npm distribution) requires `mix release`, which depends on `mix compile`. Without unblocking the build chain, M6 cannot ship. Three options were considered.

**Option A — Wait for upstream Gleam fix + mist republish.** Cleanest, no local code. Timeline indeterminate; depends on Gleam team review, Gleam release cadence, mist maintainer responsiveness, and the natural minor-bump pace of mist. Plausibly weeks to months. Blocks M6 entirely until then.

**Option B — Replace mist with cowboy or inets:httpd.** Removes the dependency on `hpack_erl`. Lift: ~150–300 lines of Erlang FFI to drive cowboy from Gleam, plus rewriting `pharos/mcp/http`. Cowboy's transitives (`cowlib`, `ranch`) have well-aligned hex/app names. Real cost: significant Erlang plumbing for what is otherwise a working M5 implementation. Future cost: lose Gleam-native HTTP types, gain Erlang interop surface to maintain.

**Option C — Local Mix.Task that creates the missing `<hex_name>.app` files post `deps.compile`.** Detects the mismatch by walking `_build/<env>/lib/<dep>/ebin/`, and when no `<dep>.app` is present but exactly one `*.app` is, copies the actual file to the expected name. Mix's `validate_app/1` then succeeds. Runtime is unaffected — Erlang's application controller resolves applications by their declared name, not by filename, so the copy is a no-op when the BEAM starts. Cost: ~50 lines of Elixir + a `mix.exs` alias entry + a doc-comment.

The forces:

- **M6 has a date pressure** that A does not satisfy.
- **B is a sledgehammer** for a tooling-naming bug that is not architectural.
- **C is mechanical and reversible.** The Mix.Task is removed when mist republishes against a Gleam release that includes the publish fix. No structural code change.
- **C is bounded.** It applies to any dep whose `_build/.../ebin/` directory contains exactly one `.app` whose name differs from the directory. That set is tiny in practice; today it is `hpack_erl` only. If it grows in the future, the dynamic detection catches new cases without code changes.

## Decision

Adopt **Option C**: ship a Mix.Task at `lib/mix/tasks/pharos/fix_app_names.ex` that creates `<hex_name>.app` as a copy of the actual `<otp_app>.app` whenever the two names differ. Wire it into the `deps.compile` alias in `mix.exs` so it fires on every Mix path that builds deps (`mix compile`, `mix test`, `mix release`).

### Mechanism

The hook runs in three steps for each `<dep>/ebin/` whose dep name does not match its `.app` file's OTP application name:

1. **Wrapper `.app` file.** Walks `_build/<env>/lib/`. For each subdirectory `<dep>/`, checks `<dep>/ebin/<dep>.app`. If absent and exactly one `*.app` file is present in `<dep>/ebin/`, writes a wrapper file at `<dep>.app` declaring an empty application named after the hex package that depends on the real OTP application. This satisfies Mix's `validate_app/1` filename check during `mix compile`. If zero or multiple `*.app` files are present, no action — the situation is either not-yet-compiled or genuinely ambiguous.

2. **Mirror directory under the OTP name.** Creates `_build/<env>/lib/<otp_name>/` as a symlink to `<dep>/` (Windows fallback: full copy via `File.cp_r/2`). `mix release` walks the application graph, resolving each dependency by its OTP application name through `:code.lib_dir/1`, which expects a directory whose parent is named `<otp_name>` containing an `ebin/<otp_name>.app` file. Without the mirror, release fails with `** (Mix) Could not find application :<otp_name>` even though the `.app` file exists under the hex-named directory. The mirror points at the same beam files; updates to one are visible through the other.

3. **Code-path registration.** Calls `:code.add_pathz('<otp_name>/ebin')` so the running mix VM's code server sees the mirror directory. Mix only adds paths for declared deps when the project starts, so without this step the symlink is in place on disk but `:code.lib_dir(:<otp_name>)` returns `{:error, :bad_name}` — the application controller never sees the mirror because `<otp_name>` is not a Mix-declared dep. `add_pathz` (append, not prepend) is used so it does not shadow legitimate apps with the same name should one ever exist.

Symlink rather than copy in step 2: avoids drift between the two directories and keeps disk usage flat. Copy is the Windows fallback because Windows symlinks require admin or developer mode. The duplicate paths live only in `_build/`; nothing is committed.

### Wiring

```elixir
defp aliases do
  [
    "deps.get": ["deps.get", "gleam.deps.get"],
    "deps.compile": ["deps.compile", "pharos.fix_app_names"],
    start: ["run -e \":pharos.main()\""],
  ]
end
```

The alias overrides Mix's built-in `deps.compile` task globally. Anywhere in Mix that triggers `deps.compile` (directly via `mix deps.compile`, or transitively via `mix compile`, `mix test`, `mix release`) runs the original task first, then our hook. By the time `validate_app/1` checks `<hex_name>.app` (after `deps.compile`), the alias file is in place.

No release-step hook is added to `releases` config. Burrito's assemble step copies `_build/<env>/lib/`'s contents wholesale; the alias has already populated the directory before assemble runs, so a release-time hook would be redundant.

### Removal criteria

This Mix.Task is removed when:

- a Gleam release ships the `gleam publish` fix that writes correct `app` fields for transitive deps, AND
- mist (or any other transitive dep this catches) publishes a new minor version using that Gleam release.

When `pharos`'s `manifest.toml` shows the dependency's `otp_app` field matching its `name` for every entry, this workaround is no longer needed. At that point, `mix.exs` drops the alias chain, the file at `lib/mix/tasks/pharos/fix_app_names.ex` is deleted, and the README pointer is removed.

The dynamic detection means the workaround is harmless even if removed prematurely — it would simply find nothing to fix. It can also stay in place indefinitely as a defensive measure if other Erlang transitives surface with the same naming pattern; the cost is one filesystem walk per `mix deps.compile`.

## Consequences

**Easier:**

- M6 unblocks immediately. `mix compile`, `mix gleam.test`, and `mix release` (up to Burrito's external `zig`/`xz` requirement) all succeed without manual intervention.
- The runtime binary is unaffected. Erlang's application controller uses application names declared inside `.app` files, not filenames, so the wrapper file is invisible to startup. Application boot proceeds via the real OTP-named application as the wrapper's `applications` list cascades into it.
- Detection is dynamic. Any future Erlang dep with a hex/app name mismatch is auto-fixed without touching this code.
- The fix is local, self-contained, and reversible. A single PR removes it cleanly when upstream catches up.

**Harder:**

- A new contributor reading `mix.exs` will see an unfamiliar `pharos.fix_app_names` task in the alias chain. Mitigated by the doc-comment in the task module pointing at this ADR.
- The workaround introduces a small ongoing maintenance obligation: monitor Gleam release notes for the publish fix, monitor mist's Hex page for republishes, and remove the workaround when both conditions are met. Captured as a memory note so future sessions know to check.
- The workaround does NOT solve the underlying ecosystem problem. Anyone else hitting this same bug from a Mix-consuming-Gleam direction will write their own version of this same Mix.Task. A documented workaround in this repo does not propagate to other projects.

**Living with:**

- The duplicate `.app` file is in `_build/`, not committed. Clean rebuilds regenerate it via the alias on every `deps.compile`. No drift risk.
- If `_build` is ever populated by a path that bypasses `deps.compile` (e.g. a CI cache restoration), the workaround does not run. The error returns. Solution: ensure CI runs `mix deps.compile` after cache restore, or add a release-step hook later if needed. YAGNI today; revisit if it bites.
- Burrito's wrapping is unaffected. `application:which_applications().` at runtime in the wrapped binary will list the OTP application by its real name (`hpack`), not the alias name (`hpack_erl`), proving the runtime is using the correct file.

## Alternatives considered

- **Option A — wait for upstream.** Rejected: M6 timeline pressure.
- **Option B — replace mist with cowboy / inets:httpd.** Rejected: ~150–300 lines of Erlang FFI to fix a build-tooling naming bug is disproportionate. Cowboy remains a fallback if mist becomes unmaintained for unrelated reasons.
- **Patch Mix itself to honor `pkg_name` in `Mix.Dep.Loader.validate_app/1`.** Considered. Mix maintainers' design stance ([elixir-lang/elixir#10284](https://github.com/elixir-lang/elixir/issues/10284)) treats this as user-error in consumer mix.exs files; the auto-detection patch would likely be rejected. Even if accepted, would ship in a future Elixir minor release — too slow for M6.
- **Symlink instead of copy.** Considered. Cross-platform issues (Windows admin requirement; Burrito tar behavior) make copy strictly safer. Disk cost is sub-1KB per affected dep.
- **Hardcoded list of `hpack_erl` instead of dynamic detection.** Considered. Marginally simpler code; loses zero-maintenance behavior when ecosystem evolves. Dynamic detection has equivalent runtime cost (filesystem walk is microseconds) and is more robust.
- **Hook on `deps.loadpaths` instead of `deps.compile`.** Considered. `deps.loadpaths` runs validation that we are trying to satisfy; hooking earlier risks ordering issues with deps that have not yet been compiled on a fresh build. `deps.compile` is the natural seam.
- **Hook as a Burrito `releases` step instead of a Mix alias.** Considered. Would only fire on `mix release`, leaving `mix compile` and `mix test` broken in dev/CI. Insufficient coverage.
