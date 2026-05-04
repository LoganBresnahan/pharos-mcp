# 005. Build chain: Mix project with mix_gleam, source 100% Gleam

**Status:** Accepted
**Date:** 2026-05-02

## Context

ADR-001 chose Gleam. ADR-004 chose Burrito for binary distribution. Burrito is implemented as a Mix release step — it consumes the output of `mix release` and wraps it in a Zig-built self-extracting executable. It does **not** consume `gleam export erlang-shipment` output (Gleam's native release format).

Two paths for combining Gleam-as-source-language with Burrito-as-distribution-tool:

**Path A — Pure Gleam project, no Mix.**
Source in `src/*.gleam`, build via `gleam build`. To produce a Burrito-style binary, would need to either: (1) write a custom Zig wrapper that consumes Gleam's `erlang-shipment` output (reinventing what Burrito already does); (2) fork Burrito to teach it Gleam shipments (commitment to maintain a fork); (3) use Bakeware (Burrito's predecessor, also Mix-flavored, same blocker); (4) skip single-binary distribution and ship Docker images or shipment tarballs (worse UX). All of these involve real extra work for no meaningful gain.

**Path B — Mix project with `mix_gleam` compiler plugin.**
Source still 100% Gleam in `src/*.gleam`. `mix.exs` is configuration only — declares the Gleam compiler in the compilation chain, lists Hex deps (both Elixir and Gleam packages work), wires up the Burrito release step. `mix_gleam` (active, ~206 stars, last updated 2026-04) handles compiling Gleam files and placing the resulting `.beam` artifacts where Mix expects them. Standard `mix release` then works as documented; standard Burrito wrap follows.

End users see no difference between the two paths — both produce a single Burrito binary. Only developer experience and build pipeline differ.

The user wants to write Gleam, not Elixir. Path B preserves that fully — the only Elixir code in the codebase is the small `mix.exs` configuration file, which is not application logic.

## Decision

Use **Path B**: Mix project with `mix_gleam` archive providing the Gleam compiler step. All application code lives in `src/*.gleam`; `mix.exs` is build configuration only.

`mix.exs` declares:
- `archives: [mix_gleam: "~> 0.6"]`
- `compilers: [:gleam | Mix.compilers()]`
- `erlc_paths: ["build/dev/erlang/#{@app}/_gleam_artefacts"]`
- `prune_code_paths: false`
- An OTP application module: `mod: {:pharos@application, []}` (the Gleam module `pharos/application.gleam` becomes Erlang module `pharos@application`)
- Burrito as a `runtime: false` dep
- Mix release with `steps: [:assemble, &Burrito.wrap/1]` and per-platform target list

Hex deps include Gleam packages (`gleam_stdlib`, `gleam_otp`, `pollux`, `gleeunit`) — `mix_gleam` resolves both ecosystems via `mix gleam.deps.get`.

Build commands:
- `mix archive.install hex mix_gleam` (one-time setup, documented in README)
- `mix deps.get && mix gleam.deps.get`
- `mix compile`
- `mix gleam.test`
- `mix release` (produces Burrito binary in `burrito_out/`)

CI uses these standard commands; no custom scripting beyond Burrito's documented per-target setup (Zig 0.15.2, xz, 7z for Windows targets).

## Consequences

**Easier:**
- Burrito works as documented — no custom Zig wrapper, no fork, no shipment-translation glue
- All BEAM ecosystem deps available — Hex packages from both Elixir and Gleam communities
- Standard Mix release tooling: runtime configuration via `config/runtime.exs`, env variable handling, application start hooks
- CI templates for Mix + Burrito exist (the user can adapt examples from `burrito-elixir/burrito` repo)
- Application code stays 100% Gleam — type safety preserved everywhere it matters

**Harder:**
- Build chain now requires Erlang + Elixir + Gleam + Mix (vs. just Erlang + Gleam in Path A). One more thing to install in CI and dev environments.
- `mix.exs` is Elixir syntax — contributors writing Gleam must understand a small amount of Elixir to modify build config. Mitigated by mix.exs being short and stable.
- Two compiler steps in CI (`:gleam` then `Mix.compilers()`) — slightly slower than pure `gleam build`, in practice ~seconds difference.

**Living with:**
- `mix_gleam` is a community-maintained archive; it's not part of Gleam core or Mix core. If the maintainer steps away, we'd vendor it or move to Path A. Acceptable risk given current activity (last commit < 1 month ago at decision time).
- Future Elixir or Mix major version bumps may temporarily break `mix_gleam` until it catches up. Pin OTP/Elixir/Mix in `.tool-versions` to avoid surprises.

## Alternatives considered

- **Path A (pure Gleam, custom wrapper)** — multiplies effort for no end-user difference. Rejected: distribution work should not be the project's main effort.
- **Path A with Bakeware instead of Burrito** — Bakeware is also Mix-flavored; same blocker. Same outcome as Path A.
- **Drop Gleam, use Elixir** — invalidates ADR-001. Out of scope for this decision.
- **Drop Burrito, ship `gleam export erlang-shipment` tarballs** — users would need Erlang installed locally. Hostile UX vs single binary. Rejected.
