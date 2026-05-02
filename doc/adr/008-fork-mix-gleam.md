# 008. Fork mix_gleam to remove third-party stall risk on the build chain

**Status:** Accepted
**Date:** 2026-05-02

## Context

ADR-005 chose Mix + `mix_gleam` as the build chain. `mix_gleam` is the Mix archive that teaches Mix how to compile Gleam source — without it, the standard Mix release flow (which Burrito requires per ADR-004) cannot consume Gleam code. The choice of build chain hinges on `mix_gleam` working correctly with current Erlang, Elixir, and Gleam.

Investigation of upstream `gleam-lang/mix_gleam` revealed:

- The last Hex release is **v0.6.2 from November 2023** (≈ 2.5 years before this ADR), pinned to Gleam pre-1.0 conventions.
- The `main` branch is labeled `0.7.0-dev` but is functionally near-identical to v0.6.2 — only six cosmetic commits between the v0.6.2 tag and `main`, none touching application logic. (5 of the 6 are CI/badge bumps from February 2024; the 6th is an April-2026 README URL update.)
- Six issues are open with no movement, including #42 ("Support for `mix release` releases") which would directly affect our Milestone 6 goal of Burrito-wrapped binary distribution.
- Under Elixir 1.19, `mix_gleam` v0.6.2 emits a `Tuple.append/2` deprecation warning from `Mix.Tasks.Gleam.Deps.Get`. The same call becomes a hard error in Elixir 1.20+.

The upstream project is **functional but not actively developed.** It is a small piece of Elixir code (≈ 9 source files, ≈ 400 lines total — six Mix tasks plus four helper modules) whose role is narrow: invoke `gleam compile-package --target erlang` at the right moment in the Mix compilation lifecycle, and rewrite Gleam dependency manifests into Mix-compatible form.

Three options were considered:

**Option A — Stay on upstream Hex v0.6.2.** Lowest effort. Accepts the deprecation warning, accepts the risk that issue #42 bites at Milestone 6 with no upstream remediation, accepts that future Gleam or Elixir releases may break the archive without anyone fixing it.

**Option B — Pin to upstream `main` (v0.7.0-dev) via git install.** Slightly more current, but the gain is illusory — the six commits ahead of v0.6.2 are cosmetic. Does not solve the deprecation, does not solve issue #42, just adds a git install step.

**Option C — Fork the project under our control and apply patches as needed.** Owns the build chain dependency. Patches we'd want immediately are small (the deprecation fix is a one-line change; the default-template bump is a few lines). Future patches (mix release support, new Gleam versions, etc.) can be applied without an upstream-maintainer bottleneck.

The cost differential between B and C is essentially the cost of running `gh repo fork` once and pushing patches. The benefit differential is full control over the most fragile piece of the build chain.

## Decision

Fork upstream `gleam-lang/mix_gleam` to `LoganBresnahan/mix_gleam`. Apply compatibility patches and ship them as v0.7.0 from the fork.

`mix_gleam` is installed as a Mix archive via the github source:

```bash
mix archive.install --force github LoganBresnahan/mix_gleam
```

Both the developer's local install and CI use this command. Documented in the project README and `.github/workflows/ci.yml`.

The fork is treated as a vendored dependency — small enough that we own and evolve it, but tracked as a separate repository to keep its concerns from polluting the main project's history. Upstream is monitored for any non-cosmetic changes; if an upstream commit lands that we want, it can be cherry-picked into the fork manually.

The first patches shipped in the fork (v0.7.0):

- Replaced deprecated `Tuple.append/2` with explicit tuple construction
- Bumped the default `mix gleam.new --retro` template from `gleam_stdlib ~> 0.32` to `~> 1.0`, and `gleeunit ~> 1.0` to `~> 1.10`
- Bumped the project's own `:elixir` requirement from `~> 1.9` to `~> 1.15`
- Promoted `0.7.0-dev` to `0.7.0`

## Consequences

**Easier:**
- `mix compile --warnings-as-errors` runs cleanly under Elixir 1.19 (the deprecation noise is gone)
- We control when and how to address issue #42 if it bites at Milestone 6 — no waiting for upstream
- Future Gleam/Elixir compatibility patches can be shipped on our schedule
- Onboarding instructions are unambiguous (one canonical install command; no "try Hex first, fall back to source" branching)

**Harder:**
- We now maintain a small Elixir library. The library's surface area is narrow but not zero — Mix-task semantics, Gleam compiler invocation flags, and the home-grown TOML parser in `MixGleam.Config` all need to keep working as upstream tools evolve.
- Cross-repo coordination: a Gleam release that changes `gleam compile-package` flags would require a fork patch in addition to consumer-side changes.
- Upstream improvements (rare, but possible) require manual cherry-pick instead of `mix archive.install hex`.

**Living with:**
- Upstream is the canonical source of the work, not us. If the upstream maintainer revives the project significantly, we'll evaluate switching back. The fork is intended as a maintenance vehicle, not a permanent divergence.
- The fork does not publish to Hex — it is github-only. Consumers must use `mix archive.install github`. Hex publication is a future possibility but requires Hex namespace decisions that we don't need to make now.

## Alternatives considered

- **Option A (stay on Hex v0.6.2).** Rejected: hard error coming in Elixir 1.20, no path to fix issue #42 if it blocks distribution.
- **Option B (pin to upstream main via git).** Rejected: zero functional improvement over A, all the same risks.
- **Drop mix_gleam entirely; write our own ~300-line glue inside `mix.exs`.** Considered as a Plan C should the fork prove too painful. The mechanism is well-understood (Mix.Task plus a shell call to `gleam compile-package`); the home-grown TOML parser is the only nontrivial part and `gleam.toml` shape is small enough to parse with a regex. Held in reserve as ADR-014 territory if needed.
- **Switch to pure Gleam project, abandon Mix and Burrito.** Considered and rejected in ADR-005 — Burrito requires Mix releases. Re-rejecting here.
