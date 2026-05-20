# Contributing to Pharos

Thanks for considering a contribution. Pharos is a one-maintainer
project today; clear PRs with focused scope land fastest. This
file documents the contribution flow, the CLA requirement, and
the conventions the codebase already follows.

## Scope

We welcome:

- Bug reports + reproducible test cases
- LSP integration fixes (rust-analyzer, gopls, jdtls, pyright,
  metals, etc. — pharos pools them all, edge cases per server
  are real)
- New MCP tools that wrap a clearly-named LSP capability
- Documentation improvements
- Benchmark contributions (corpora, question kinds, scorers)
- Editor bridge implementations for non-VSCode editors when the
  protocol stabilises (see [ADR-028](doc/adr/028-universal-editor-bridge.md))

We're more careful about:

- Large architectural rewrites — please open an issue first to
  align on intent before sinking time into code
- New runtime knobs / configuration surface — every new flag is
  cognitive overhead for every operator, so the bar is high
- Tool description changes — the Phase 1 prose A/B work
  ([benchmark-findings.md `Run 7`](../.private/benchmark-findings.md))
  showed counter-intuitive results; description changes are
  load-bearing for LLM behaviour and need data to back them

## Before you start

For anything bigger than a typo fix, please open a GitHub Issue
or Discussion first. A short note describing what you want to
build saves both sides the cost of a wrong-direction PR.

## Contributor License Agreement

**Every PR needs a signed CLA before it can be merged.** Pharos
is dual-licensed (AGPL-3.0 open-source + commercial), and the
CLA gives the project the rights it needs to offer both tracks.

We use the [Apache Individual Contributor License Agreement][icla]
template, signed via the [CLA Assistant][cla-assistant] GitHub
App. When you open your first PR, the bot leaves a comment with
a link; signing is a one-time action and applies to all future
PRs from the same GitHub account.

For corporate contributions (where your employer holds copyright
on the work you contribute on company time), we'll ask for the
Apache Corporate CLA instead. Reach out via the contact in
[COMMERCIAL.md](COMMERCIAL.md) if your company needs that.

We also use the [Developer Certificate of Origin][dco] alongside
the CLA — sign your commits with `git commit -s` so the
provenance chain is explicit. The CLA carries the relicensing
rights; the DCO carries the per-commit assertion.

[icla]: https://www.apache.org/licenses/contributor-agreements.html
[cla-assistant]: https://cla-assistant.io/
[dco]: https://developercertificate.org/

## Local development

Pharos is Gleam on the BEAM. You'll need:

- Erlang/OTP 27+ (28+ recommended)
- Gleam 1.0+
- Node (for the npm packaging tests; not needed for core
  development)
- Optional: one or more LSP servers locally (rust-analyzer,
  gopls, pyright, etc.) if you want to dogfood against real
  fixtures

We use [`asdf`](https://asdf-vm.com/) to pin toolchain versions.
A `.tool-versions` file at the repo root drives that.

```
asdf install                  # install pinned toolchains
gleam build                   # compile
gleam test                    # 178 tests at last count, ~10s
bin/pharos-dev --version      # smoke a dev binary
```

For dogfood passes (broader integration test across all 23
supported languages):

```
bin/dogfood-fixtures.sh       # clone pinned fixture repos
bin/dogfood-23lang.py --help  # see options
```

## Coding standards

- **Run `gleam fmt`** before submitting. CI enforces formatting.
- **No `git push --force`** to anything but your own branches.
- **Commit message format**: Conventional Commits style —
  `feat(scope):`, `fix(scope):`, `docs(scope):`, `chore(scope):`,
  `refactor(scope):`. The existing git log shows the pattern; a
  glance at recent commits is the fastest reference.
- **Comment discipline**: write comments that explain *why*, not
  *what*. The code already states what it does; comments should
  encode the constraint, invariant, or surprising behaviour that
  isn't obvious from the names. Don't write running commentary.
- **No `--no-verify` on commit hooks** unless you've raised it
  in the PR thread and got an OK first.

## Test expectations

- `gleam test` must pass — 178 tests today; new tests welcome.
- For changes that touch LSP-bound tools, dogfood the change
  against at least one language fixture before requesting review
  (`bin/dogfood-23lang.py --filter <lang>`).
- For changes that affect agentic behaviour (tool descriptions,
  new tools, response shapes), the maintainer will likely re-run
  the benchmark sweep before merging. Heads up: this can add
  days to review.

## PR checklist

When you open a PR, the template prompts for:

1. Linked issue / discussion number
2. Brief summary of the change (the "why", not the "what" — the
   diff carries the what)
3. Test plan
4. CLA signature confirmation (CLA Assistant bot will gate this)

A failed CLA check is the most common reason a PR isn't merged
quickly. Sign it once; the bot handles the rest.

## Reporting bugs

A good bug report includes:

- pharos version (`pharos --version` or commit SHA if from source)
- OS + architecture
- LSP server name + version
- Minimal reproduction (a small fixture or a short command
  sequence)
- Observed vs expected behaviour
- Any log output (`PHAROS_LOG_LEVEL=debug` is useful)

## Security

Don't open public issues for security findings. Email the
contact listed in [COMMERCIAL.md](COMMERCIAL.md) directly. We'll
acknowledge within 72 hours, fix in private, and credit you in
the release notes once the patch is public.
