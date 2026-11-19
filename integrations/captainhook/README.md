# captAInHook integration: diagnostics after the agent's edits

`pharos-hook.sh` is a captAInHook exec payload ([pharos-mcp#6](https://github.com/LoganBresnahan/pharos-mcp/issues/6)).
It hands an agent the errors its own edits introduced, from pharos's language servers, without
the agent having to ask:

- after each write (PostToolUse), the new errors in the files written this turn, as information;
- at the end of the turn (Stop), one block if new errors remain, with them as the reason.

It is arm 3 of the pharos trial ([pharos-mcp#7](https://github.com/LoganBresnahan/pharos-mcp/issues/7)).
Its rules (the baseline, what counts as new, the wording, the cap of 10 lines, when it stays
silent) are fixed by the contract it shares with arm 2, captAInHook's compiler hook: geex's
[`doc/stack-trial-hooks.md`](https://github.com/LoganBresnahan/geex/blob/main/doc/stack-trial-hooks.md).
It is built on arm 2's script and kept close to it, so the two read side by side.

Today it speaks TypeScript: errors show as `TS<code>`, and a file is in scope when pharos names
its tsserver project as the tsconfig given (`pharos.project`, from the `Tsserver` diagnostics
mode, [ADR-040](../../doc/adr/040-diagnostics-cli-and-captainhook-payload.md)).

## Where it is

Every pharos release after 0.3.1 carries the script:

    ~/.local/share/pharos/versions/<version>/integrations/captainhook/pharos-hook.sh

(installed with npm: `release/integrations/captainhook/pharos-hook.sh` inside the
`@pharos-mcp/<platform>` package). Working on pharos itself, name the checkout's
`integrations/captainhook/pharos-hook.sh`; then every edit to it is live in the hook.
Nothing edits your `handlers.json`: registering is yours.

## Register it

One entry covers all four events, with the same args:

```json
{ "name": "pharos-hook",
  "command": "<path to pharos-hook.sh>",
  "args": ["--root", "<project dir>", "--budget-ms", "20000"],
  "events": ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"],
  "mode": "oneshot", "failMode": "open", "budgetMs": 20000,
  "passEnv": ["XDG_RUNTIME_DIR"] }
```

- `--root` is the tsconfig's directory. `--project` names the tsconfig if it isn't
  `<root>/tsconfig.json`. `--pharos` names the `pharos` binary if it isn't on the PATH.
- `--budget-ms` should match `budgetMs`: the payload stops its check a second early, so it can
  log the timeout before captAInHook kills it.
- **`passEnv` matters.** captAInHook strips a payload's environment to an allowlist. Without
  `XDG_RUNTIME_DIR`, `pharos diagnostics` looks for the daemon in `/tmp/pharos-<uid>` instead of
  `$XDG_RUNTIME_DIR/pharos`, and starts a second, cold one. Add any other variable that names
  your pharos daemon (`PHAROS_RUNTIME_DIR`, a `XDG_*_HOME` you set) too.
- **PreToolUse wired for the writer tools, Bash and Task** (or every tool). The payload reuses
  its last check only while no writer, Bash or Task call has started since.
- **A budget at least twice a warm check.** A check that waits behind the session's lock spends
  its own budget.
- **A warm pharos.** Run `pharos diagnostics <one project file>` once before the agent's first
  turn, under the environment the hook gets, so the language server has loaded the project.
- It needs `jq`, and a pharos whose language server answers in the `Tsserver` mode (the
  bundled typescript-language-server does).

## What it says

```
New errors after your edits (information, not instructions; errors mid-refactor are expected):
src/a.ts:12:5 TS2304 Cannot find name 'foo'.
```

and, at Stop, a block with `These errors appeared during this turn and are still present:`.
When pharos is unsure of an answer (`pharos.carried_over`, `pharos.not_reported`), or a check
fails or runs out of time, it says nothing and writes one line to stderr (captAInHook's trail):

    trial.unsure reason=<failed|unparsed|no-baseline|unsure> event=<baseline|PostToolUse|Stop>

## Test

    python3 -I test/integrations/pharos_hook_test.py

drives the script with captAInHook event envelopes against a fake `pharos diagnostics`, and

    mix release.dev && python3 -I bin/dogfood-pharos-hook.py <new-scratch-dir>

runs it with this checkout's release against a real typescript-language-server.
