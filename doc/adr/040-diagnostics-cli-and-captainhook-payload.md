# 040. `pharos diagnostics` and the captAInHook payload

**Status:** Accepted (2026-11-18)
**Date:** 2026-11-18
**Issue:** [#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6)

## Context

Agents rarely call `get_diagnostics` on their own. A hook that runs after every edit, and hands
back the errors that edit introduced, gets pharos's language servers used where they matter
most. Whether that beats the project's own compiler in the same hook is what the trial (#7)
measures: arm 2 is captAInHook's compiler hook (captAInHook#4), arm 3 is this. Both follow one
contract, geex's `doc/stack-trial-hooks.md`, which fixes the seams, baselines, wording, cap,
reuse rule and silence. Where this ADR and that file disagree, the file wins.

A hook isn't an MCP client: captAInHook runs a payload process per event, with a stripped
environment, and reads one answer line. So it needs a way to ask pharos without speaking MCP,
and that way runs twice per write (the baseline at PreToolUse, the check at PostToolUse). The
trial measures wall time.

## Decision

**A one-shot CLI in the shim:** `pharos diagnostics [--json] [--timeout-ms N] FILE...`.

- It joins (or starts) this build's daemon exactly as an MCP session does (`client::connect`:
  the same start-or-join, the same hello), sends MCP `initialize` and one `get_diagnostics` per
  file, prints, and exits.
- It lives in the Rust shim, not the runtime: a hook calls it on every edit, and booting the
  Erlang VM costs about a second each time. The end-to-end run answers in 0.02 to 0.26 s per hook
  call. The shim gained a small JSON parser and writer for the replies; the relay still copies
  MCP traffic as bytes.
- Each file gets a status:
  - `ok`: diagnostics about the file's current text (ADR-038, ADR-039);
  - `unsure`: pharos marked the answer (`pharos.carried_over`, `pharos.not_reported`), nothing
    was published in time, or pharos couldn't name the file's project
    (`pharos.project_unknown`). A hook stays silent;
  - `failed`: the tool call failed for that file.
- `--json` prints `{"files": [{file, path, uri, status, reason?, project?, diagnostics}]}`;
  without it, `FILE:LINE:COL SEVERITY CODE MESSAGE` lines (1-based) for the `ok` files, and a
  note on stderr for the rest.
- Exit 0 once the daemon answered, whatever the statuses; 1 when pharos itself failed (the
  daemon unreachable, the session broken); 2 on bad usage. There is no fallback to direct mode:
  a hook would pay a cold start on every call.

**The file's project, in the `Tsserver` mode** (amends ADR-039). A `get_diagnostics` answer from
tsserver also carries `pharos.project`: the `configFileName` of tsserver's `projectInfo` for the
file, one more `typescript.tsserverRequest`. It runs after the diagnostics, with what is left
of the call's budget; the diagnostics leave it a reserve (a quarter, at most 2 s). tsserver
answers in order and the first request after an edit waits for the program update, so the
diagnostics absorb that wait and projectInfo, on a current program, costs milliseconds.
(It first ran *before* them under a 2 s cap, which ran out whenever tsserver was busy: in
#7's dry run, 11 checks read as unsure.) When tsserver can't name the project in time
(an error, a timeout), the answer carries `pharos.project_unknown` instead, and
`pharos diagnostics` reports the file as `unsure` with that reason, `project_unknown` (it
was `no_project`, which read like a real absence). The diagnostics
themselves are still current, but a hook keeping to one program can't place the file, so it
stays silent: scope unknown is never "out of scope". The contract's scope rule uses the
project. A file is in scope when its project is the trial tsconfig. tsserver
puts a file outside the program in an inferred project (`/dev/null/inferredProject…`), which
matches tsc's program exactly, new files included, with nothing for a runner to keep in sync.

**The payload, shipped in pharos:** `integrations/captainhook/pharos-hook.sh`, in every release
under `integrations/captainhook/` (the tarball and the npm platform package; `BUILD_ID` covers
it).

- It is `sh` plus `jq`, built on arm 2's script and kept close to it, so the two read side by
  side. The lock, the atomic writes, the generation and reuse rules, the key, the diff, the
  rendering and the Stop rule are arm 2's.
- What differs is the contract's difference between the arms:
  - the checker is `pharos diagnostics --json` on the files touched this turn (reach);
  - there's no turn-start snapshot, so UserPromptSubmit only forgets the turn;
  - there's no incomplete-check rule: pharos's markers govern arm 3;
  - a file pharos is unsure of is unknown for that check, and logs `trial.unsure reason=unsure`.
    So is an `ok` answer that names no project (`projectInfo` is best-effort): scope unknown
    is unsure, never out of scope. Only a project pharos names, and that isn't the trial
    tsconfig, is out. Otherwise a baseline taken without a project would make the next check
    report the file's old errors as new (review finding);
  - a reusable snapshot holds what each file's check knew, and reuse needs every file asked about.
- Its captAInHook entry passes `XDG_RUNTIME_DIR` (and any other daemon-key variable) through
  `passEnv`. Without it, the CLI would find no session directory, and would start a second, cold
  daemon.

## Consequences

- Any hook or script can ask the shared daemon for diagnostics, warm, without an MCP client.
- The shim now parses MCP replies, in one command. The parser is small and unit-tested. A broken
  reply fails that command, never the relay.
- `pharos.project` costs one more tsserver request per TypeScript answer, a few milliseconds.
- The payload speaks TypeScript only: `TS<code>`, and the scope rule rests on tsserver's
  projects. Another language needs its own code prefix and a scope rule, as the contract says
  for a Rust trial.
- Paths with a space, `#`, `%` or non-ASCII characters aren't handled (#16), and the payload
  splits the touched list on whitespace. The trial's project path avoids them.
- There's no stable install path for the script yet: it lives under the version's directory,
  and a registration names that path, or the checkout's. A link maintained by `install.sh`, as
  geex keeps one, is a follow-up if the hook outlives the trial.
- Tests:
  - `test/integrations/pharos_hook_test.py` drives the payload with captAInHook envelopes
    against a fake `pharos diagnostics`. It covers each contract rule: new versus baseline,
    reported counts, the cap, scope, unsure, a failed check, reuse, background Bash, Stop's one
    block, and a new turn.
  - The daemon integration suite's `diagnostics_cli` covers the CLI against the stub.
  - The shim's unit tests cover the arguments, the paths, the statuses and both output forms.
  - `bin/dogfood-pharos-hook.py` runs the payload with this checkout's release and a real
    typescript-language-server through two turns. Every step answered as the contract says, in
    0.02 to 0.26 s.

## Alternatives considered

- **The CLI in the runtime** (`pharos diagnostics` handed to the bundled ERTS like other
  commands): simplest, but about a second of VM boot per hook call, twice per write.
- **A payload in Python, or in the shim** (`pharos hook <event>`): either would be easier to
  write than `sh` + `jq`, but the two arms would then differ in more than their checker, and the
  trial compares them.
- **Scope from tsc's `--listFilesOnly`, passed by the runner:** it misses files created during
  a run, and matching tsconfig's `include`/`exclude` globs in `sh` is fragile.
- **A new MCP tool** for project info: a permanent description in every agent's context
  (ADR-006), for a field the existing answer can carry.
