# 007. Two-repo split: binary and VSCode extension as independent repositories

**Status:** Accepted
**Date:** 2026-05-02

## Context

ADR-003 established that the project ships as two artifacts: a Gleam binary (`pharos`) that runs everywhere, and a thin VSCode extension (`pharos_ext`) that exposes unsaved-buffer state via local HTTP for the binary to consume. The two are coupled by a small bridge protocol (~5 HTTP endpoints) but otherwise share nothing — different language, different runtime, different distribution channel.

The natural question: monorepo or two repos?

**Monorepo arguments:**
- One commit can update both sides of a bridge protocol change atomically
- Cross-repo references (issues, PRs, docs) are local — no GitHub issue cross-linking
- Single CI configuration could orchestrate both builds
- One place to file an issue regardless of which artifact has the bug

**Two-repo arguments:**
- Independent release cadences — extension marketplace updates on a different cycle than binary releases
- Different ecosystems live cleanly — Gleam + Mix + Burrito + Hex on one side, TypeScript + esbuild + npm + vsce on the other; mixing tooling in one tree creates conflicts (lint configs, formatter configs, .gitignore noise)
- Different distribution channels are already separate — npm + GitHub Releases for binary, VSCode Marketplace + Open VSX for extension; nothing unifies on one publish step anyway
- Different audiences — agentic CLI / headless users care only about the binary; VSCode users add the extension on top
- Independent contributorship — someone (community or future you) could write a JetBrains plugin variant of the bridge without touching the binary repo, mirroring the same pattern naturally
- Smaller blast radius — extension bug doesn't trigger binary CI; binary release doesn't drag extension build through every commit

The bridge protocol couples the two, but only loosely: protocol changes are infrequent (after v1 stabilizes) and follow a versioning discipline. The cost of coordinating across two repos for the rare bridge protocol bump is small — a draft of the spec change PR'd to the binary repo (where the spec lives), then a corresponding PR in the extension repo bumping its supported version. That's the same level of coordination as monorepo except split across two PRs.

The user explicitly preferred two repos.

## Decision

Two independent repositories:

- **`pharos`** — this repo. Gleam binary. Distribution: GitHub Releases + npm. Contains the canonical bridge protocol specification at `doc/bridge-protocol.md`.
- **`pharos_ext`** — separate repo. VSCode extension. Distribution: VSCode Marketplace + Open VSX. References the bridge protocol spec by version (e.g., "implements bridge protocol v1.0") in its README and runtime handshake.

The bridge protocol spec lives in the binary repo because the binary is the spec's primary consumer and the protocol exists to serve the binary's needs. The extension is one implementation of the spec; future implementations (JetBrains plugin, Helix sidecar, etc.) would similarly consume the spec from the binary repo.

Coordinated changes follow a defined order:
1. Spec change is drafted as a PR in the binary repo, including version bump.
2. Extension repo is updated against the new spec version in a separate PR.
3. Binary repo merges the spec change first; extension repo then merges its update.
4. Releases proceed independently after both merges.

Issues are filed on the repo of the affected artifact. Cross-repo bugs (binary expects behavior the extension doesn't provide, or vice versa) get an issue on each side referencing the other.

Versioning is also independent: binary uses semver based on its own changes; extension uses semver based on its own changes. The bridge protocol has its own semver tracked in `doc/bridge-protocol.md`. Compatibility is via the protocol version handshake at runtime — extension and binary report which protocol versions they support, mismatches degrade to disk-only mode gracefully.

## Consequences

**Easier:**
- Each repo's CI is small and focused — no cross-language tooling friction
- Marketplace publish flow for the extension is unambiguous (one repo, one publish)
- Contributors comfortable in one ecosystem (TS or Gleam) can work without learning the other
- Independent issue tracking — clear ownership boundaries
- The pattern naturally extends to additional bridge implementations (JetBrains, Helix) without monorepo bloat

**Harder:**
- Cross-cutting bridge protocol changes require coordinating two PRs in order
- Users debugging integration issues (e.g., "extension isn't working with binary") may need to file issues in both repos and link them
- Documentation must clearly point users at the right repo for the right concern; README cross-links are essential
- Version compatibility matrix: not every binary version works with every extension version. Documented in both READMEs.

**Living with:**
- The bridge protocol is the only coupling. Keeping the spec stable post-v1 minimizes coordination cost. Major protocol changes (v2) are rare events.
- A minor risk: extension drifts behind the binary's protocol version and quietly stops providing buffer state. Mitigation: extension's startup logs warn if its protocol version is older than the binary expects (binary tells extension on probe; extension can log warning).

## Alternatives considered

- **Monorepo with separate top-level dirs** (`./binary/`, `./extension/`) — simpler issue tracking and atomic cross-cuts, but real cost in mixed CI, mixed lint/format configs, and contributor barrier (must understand both ecosystems to navigate). Wins are marginal; losses are constant friction.
- **Three repos: binary, extension, bridge spec** — the bridge spec is small enough that a third repo is bureaucratic overhead. Spec lives in the binary repo as documentation; promoted to its own repo only if a third client (JetBrains, etc.) appears and demands neutral ground.
- **Monorepo via git submodules** — adds submodule complexity; submodule UX is famously poor. Rejected.
