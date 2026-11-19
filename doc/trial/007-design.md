# The pharos trial (#7): design, draft for review

**Status:** revised 2026-11-19 after the dry run (section 4). The maintainer sized the trial
at **90 runs** (6 tasks × 3 arms × 5). They don't start until the maintainer gives a separate
go, once everything below is fixed, verified and re-pinned.
**Contract:** geex's [`doc/stack-trial-hooks.md`](https://github.com/LoganBresnahan/geex/blob/main/doc/stack-trial-hooks.md)
(v13 draft at the time of writing). Where this design and the contract disagree, the contract
wins.

## 0. One thing to decide before the tasks

The contract gives the arms different **reach**. Arm 2 (the compiler hook) checks the whole
project after every write. Arm 3 (pharos) checks only the files the agent touched this turn.
So:

- A refactor that breaks callers in files the agent **didn't** touch is seen by arm 2 and
  missed by arm 3, at PostToolUse and at Stop. Arm 3 can only win those turns if the agent
  finds the callers itself, from the compiler, tests or grep.
- What arm 3 should win is **cost per check**. On a big project a whole-project `tsc` takes
  tens of seconds, while tsserver answers about a few files in milliseconds. That shows up in
  wall time, and in the budget kills or silence arm 2 gets when a check outlasts the budget.

That's what the trial measures, by design. But the tasks decide which side of it dominates. A
task set of only cross-file refactors measures reach and favours arm 2. A set of only local
edits measures cost and favours arm 3. **The mix is fixed at three of each** (the maintainer,
2026-11-19), reported per kind and pooled.

**The verdict is exactly the contract's "clearly beats",** with at least 5 runs per arm per
task. Arm 3 wins only if both of these hold:

- its broken-turn rate, pooled over all tasks, is no higher than arm 2's;
- for wall time or for tokens, the median over tasks of (arm 3's median ÷ arm 2's median) is
  0.8 or below.

Otherwise the compiler hook wins. The results per task kind and the "done" rate are
descriptive only and never enter the verdict.

**Fixed before the dry run (2026-11-19):** the 3 + 3 mix; two user turns per run; web tools
off in every arm; and the contract's thresholds, unchanged: a pooled broken-turn rate no higher
than arm 2's, and a median-of-medians ratio of 0.8 or below for wall time or for tokens.

**Fixed after it (the maintainer, 2026-11-19):**

- **An agent without subagents.** Claude Code 2.1.328 runs a subagent asynchronously: the
  parent's turn ends (Stop) before the subagent starts, and its result re-enters as a new
  prompt (UserPromptSubmit), which resets both hooks' turn. So the `Agent` tool is off in every
  arm (section 3), and the write-up says the trial is about an agent without subagents.
- **Arm 2 is the plain compiler hook:** one `tsc --incremental` per write, as the contract
  describes it. The write-up states that the trial doesn't test a resident compiler such as
  `tsc --watch`.
- **90 runs**, 5 per arm per task.

## 1. The project

**outline/outline at `9839ad8182cdd533845d7005efdcf0e995af9c0a`** (2026-09-18, "fix: Send
analytics events through gtag…"). It is outline's last commit on TypeScript 6.0.3: its
`yarn.lock` resolves `typescript@^6.0.3` to exactly 6.0.3, and the next commit (`3a446d1`)
moves to `^7.0.2`.

Why outline:

- **One tsconfig.** A single root `tsconfig.json` covers `app/`, `server/`, `shared/` and
  `plugins/`, with no nested tsconfig. That's rare among large TypeScript repos: excalidraw,
  typeorm, immich and date-fns all have 9 to 21 tsconfigs. So the contract's "no nested tsconfig
  owning program files" holds by construction, and the setup check below confirms it.
- **Large, with cross-file types.** 2,196 `.ts`/`.tsx` files: a React app (MobX stores,
  components), a Koa server (Sequelize models, commands, presenters) and shared types, linked
  through path aliases (`@server/*`, `@shared/*`, `~/*`). A rename or a signature change ripples
  across directories. That's where a language server ought to help, and where a whole-project
  `tsc` is slow.
- **Tests that run offline.** vitest, with projects `app` and `shared-node`/`shared-jsdom`
  that need no database. The `server` project needs Postgres and Redis, so no task depends on
  server behaviour (see "Server tests" below).
- **Clean path.** It's cloned under `/tmp/trial/...`: no space, `#`, `%` or non-ASCII
  characters (#16).

**Setup checks, before any task is final (no model tokens):**

1. **Toolchain:** node 22 (latest 22.x), installed with mise for the trial and recorded.
   outline's `engines` at this commit is `>=20.12 <21 || 22 || 24 <24.17.0 || 26 <26.3.1`; this
   machine has node 25.4.0 and 24.21.0, both outside it. yarn 4.11.0, the commit's
   `packageManager`, through corepack, also recorded. Then `yarn install`. The repo's
   `.yarnrc.yml` sets `nodeLinker: node-modules` and `enableScripts: false`. It writes to the
   yarn cache, so it runs under the trial's own HOME.
2. **Complete and syntax-clean:** `tsc -p tsconfig.json --noEmit --pretty false` with 6.0.3.
   Every error it reports is in a program file, with no TS5xxx. The tsconfig sets
   `"ignoreDeprecations": "5.0"`. If 6.0.3 rejects that, or reports a TS5101/TS5107, set
   `"6.0"` in the trial's copy and record it.
3. **Timings and the budget:** arm 2's exact checker
   (`tsc --noEmit --incremental --tsBuildInfoFile … -p …`), one cold run, then three warm runs
   after each of two edits:
   - a **leaf edit**: one line in a file nothing imports;
   - a **shared-type edit**: a field added to a type in `shared/` that `app/` and `server/` use.
     That's the worst case the cross-file tasks hit, since tsc re-checks every dependent.

   The budget is at least twice the larger warm time. Both times and the budget are recorded,
   and Claude Code's hook timeout goes above the budget. If the leaf edit's warm check is under
   about 2 s, outline doesn't separate the arms on cost, and a bigger project is needed.

   **Re-measured after the dry run (2026-11-19, 05:18–05:34 UTC, load ≈ 1.2 on 8 cores, the
   other chats holding heavy jobs),** on the tasks' own widest edits, three times each, every
   edit followed by its revert (`/tmp/trial/time-wide-edits.sh`):

   | Edit | Checks | Errors |
   |---|---|---|
   | T1: `bytesToHumanReadable` renamed at its definition | 46.9–47.4 s | 12 |
   | T2: `slugify` gains a required parameter | 46.6–47.0 s | 12 |
   | T3: `DateFilter` a string enum | 47.0–47.2 s | 6 |
   | a comment-only edit to `shared/types.ts` | 4.3 s | 0 |
   | T6: `Folder` gains a required prop | 5.4 s | 5 |
   | each revert | 46.6–48.4 s (4.3–5.5 s for the last two) | 0 |

   Any edit that changes an export's shape costs about 47 s, whatever its reach: tsc re-checks
   the dependents. But arm 2's checks in the dry run took up to 116 s on the same kind of edit
   (T2), 2.4× the quiet time, with other chats working on the machine. So **the budget is
   240 s** (twice the largest seen anywhere) and **Claude Code's hook timeout 270 s**. The
   full runs need the machine kept quiet: other heavy jobs during a run would slow arm 2's
   checks, and only arm 2's.
4. **Scope (contract amendment, draft c4318f44):** list the program with
   `tsc --listFilesOnly`, keeping only **the project's own TypeScript program files**: under
   the project root, not under `node_modules/`, not TypeScript's `lib.*.d.ts`, and with a
   TypeScript extension (`.ts`, `.tsx`, `.mts`, `.cts`). The program's JSON files
   (`resolveJsonModule`) are out of arm 3's scope (contract amendment 7fa13b5e), and the hook
   skips any touched non-TypeScript file silently. Setup found 2,237 own program files: 2,211
   TypeScript, all `ok` with the root tsconfig, and 26 JSON. Then run `pharos diagnostics --json`
   on all of them. Every answer's `project` must be the root tsconfig. Another named project
   fails the setup at once. Any non-ok status (`unsure` for `project_unknown`, `no_publish` or
   `carried_over`, or `failed`) is retried up to three times, a few seconds apart, for that
   file, since a projectInfo timeout under load is transient (verifier-two); if it still isn't
   ok, the setup fails. It runs in `run.py --prepare`, once per start state, with its versions
   recorded, and a run refuses a start without a passing one. **On pharos 0.3.4
   (2026-11-19):** every start state passes, 2,211 files (2,213 for T4) `ok` with the root
   tsconfig, 78–95 s each.
   - It runs once per task start state. Every run of a task starts from an identical tree.
   - It uses the same pharos, typescript-language-server and TypeScript as the runs, and is
     redone if any of them changes. The runner records their versions with the result, and
     refuses to start a run on a mismatch.
   - After each run, the runner flags the run if its tree gained a `tsconfig*.json`, since
     that run's arm 3 scope may have shifted.
5. **One TypeScript:** arm 3's typescript-language-server must use outline's own
   `node_modules/typescript` (6.0.3). The lockfile also carries 5.9.3, as a dependency of a
   dependency, and typescript-language-server bundles a copy of its own. The run HOME's
   `~/.config/pharos/pharos.toml` (not a file in outline's tree, and `HOME` passes captAInHook's
   stripped environment) sets the server's initialization options:
   `[languages.typescript]` `initialization_options_json =
   {"hostInfo": "pharos", "tsserver": {"path": "<proj>/node_modules/typescript/lib"}}`.
   The setup check is the tsserver that the trial daemon's typescript-language-server actually
   runs: its command line must be `<proj>/node_modules/typescript/lib/tsserver.js`, and that
   package must be 6.0.3. pharos's daemon log doesn't carry typescript-language-server's version
   line. Arm 2 already runs `<proj>/node_modules/.bin/tsc`, which `tsc --version` confirms.
   - JSON files in the program (`resolveJsonModule`) go to pharos's JSON server, not tsserver,
     so arm 3 doesn't ask about them (setup check 4).
6. **Tests at the start:** the task's vitest projects pass, and the measuring check is
   complete, at each task's start state.

**Server tests (was open point 5): closed, no databases.** The `server` vitest project needs
Postgres and Redis. Providing them per run is possible, but it adds two services to every
run's isolation and start-up, and nothing in the question needs server behaviour. So no task
depends on server behaviour, and no task's test set includes the `server` project.

**If outline fails a setup check:** the fallback is a single-tsconfig package from a monorepo
(say `typeorm/packages/typeorm`), copied out with its own tsconfig. That's more work, and its
tests need a database. I haven't verified a fallback.

## 2. The tasks

**Six tasks**, two kinds, each a JSON file in `bench/trial/tasks/` with its start commit, its
two prompts, and a hidden acceptance test per turn (the runner writes it after the turn, runs
it, and removes it). Chosen from outline's code at `9839ad8`:

| # | Kind | Turn 1 | Turn 2 | Reach |
|---|---|---|---|---|
| T1 | cross-file | rename `bytesToHumanReadable` to `formatBytes`, no alias | an optional `decimals` parameter, default 2 | 14 files: app, server, plugins, shared |
| T2 | cross-file | `slugify` takes a required `separator` | make it optional, default `"-"`, and drop the explicit `"-"` again | 11 calls in 10 files; three files import npm's `slugify` under the same name |
| T3 | cross-file | `DateFilter` (in `shared/types.ts`) from a string union to a string enum | add `Quarter` (three months) everywhere a date filter is used | app, server (a zod literal union), shared; the widest edit |
| T4 | local | implement `formatDuration` to the spec in its doc comment, with the tests it ships with | an option for spelled-out, pluralized units | one new file |
| T5 | local | fix find-and-replace highlighting after an emoji in decomposing text (a seeded bug, a failing test) | `toOriginalIndex` clamps out-of-range indices | one file |
| T6 | local | the sidebar's `Folder` gets a required `label` and wraps its children in a labelled group | make `label` optional, unwrapped without it | 5 uses, one directory |

**Start states are history-free commits**, each in a standalone repo: one parentless commit of
`9839ad8`'s tree for T1, T2, T3 and T6, and one each for T4 (the stub and its tests) and T5 (the
seeded bug and its failing test), all with fixed author and dates and the subject "Initial
commit", which doesn't name the upstream commit. Without a parent, `git
log -p` can't show an agent the seeded bug or the shipped tests being added.

**Each task:**

- **Start:** a branch at `9839ad8` plus the task's prepared state (a seeded bug, a failing
  test, or none). The start state passes setup checks 2, 4, 5 and 6, and its measuring-check
  error set is recorded as the baseline.
- **Its test set, written down per task:** the vitest projects it runs (only `app`,
  `shared-node` and `shared-jsdom`, never `server`), and its own acceptance test files.
  "Every test that passed at the start" means every test in that set.
- **The prompt:** fixed text, the same for every arm. It names the goal, not the files. It
  doesn't mention hooks or pharos.
- **Turns: two user turns per run** (the maintainer, 2026-11-19): the task, then one scripted
  follow-up (for example "also make it work for X"). That gives the contract's per-turn measure
  two turns to judge, and exercises UserPromptSubmit resetting the turn.
- **Success**, judged by the runner after each turn's final Stop:
  - **not broken:** the measuring check finds no key more often than at the task's start, and
    every test that passed at the start still passes (the contract's "broken turn");
  - **done:** the task's own acceptance tests pass (written in setup, committed in the start
    state, named in the prompt only where a developer would have them).
- **Reported per task kind and pooled:** broken turns, done or not, wall time, tokens.

## 3. The runner

Two Python scripts beside pharos's existing `bench/`: `bench/trial/run.py` does one run (one
task under one arm) and appends one JSONL record; `bench/trial/rounds.py` schedules the rounds.
`run.py --prepare` builds each task's start state once. The runner's own files (records, turn
transcripts, vitest reports) live in `/tmp/trial/private` and `/tmp/trial/results`, never inside
a run's reach.

**Isolation, per run:**

- **Run directory:** `/tmp/trXXXXXX/`, holding the run's `home/`, Claude Code's config dir,
  the project at `proj/`, and the build info files.
  - **The project's repository holds the start commit alone.** Each start state lives in a
    standalone bare repo (`/tmp/trial/starts/<sha12>.git`: one commit, one ref, no remote, no
    promisor), and each run clones it fresh, removes the remote and expires the reflog. The
    runner refuses a project whose repository has anything else (pre-flight finding: a
    worktree of the shared clone exposed every task's start, the seeded bug included, and
    upstream through a promisor fetch). The upstream clone is deleted; its install moved to
    `/tmp/trial/install`.
  - `node_modules` comes from that one prepared install, hard-linked, with yarn's install
    state copied in, so a run doesn't reinstall.
  - Each run gets its own writable `node_modules/.cache` and `node_modules/.vite`. outline's
    tsconfig writes its build info to `node_modules/.cache/tsc/`, so an agent's own `yarn tsc`
    would otherwise share state across runs.
  - The runner resolves `<proj>` with `realpath` before using it anywhere: the hooks' `--root`,
    arm 2's `-p`, and the events' working directory. Then no symlink in the run's path can make
    the hooks' keys disagree (the linked-root bug: fixed in pharos, in review for arm 2).
- **HOME:** `HOME=<run>/home`.
- **The sandbox: what the agent can reach.** Claude Code, and so its tools and the hooks it
  starts, runs under bubblewrap in its own mount and pid namespaces, with its own `/proc`:
  `/home`, `/tmp`, `/mnt`, `/run/user` and WSL's `/run/WSL` (the interop sockets) are empty, with the run dir, its runtime dir, the trial's tools (read-only),
  the node install (read-only) and `resolv.conf` bound back at the same paths. Every run
  checks from inside that the task files (the hidden tests), the start repos, the runner's
  records and cache, `~/.claude`, the pharos repo and other sessions' sockets are invisible,
  and that `/tmp` shows only its own two dirs and the tools. The measure runs the agent's code
  (its vitest config, setup files, tests) while the hidden test is present, so it runs in the
  same sandbox, with only a fresh report-only dir added for vitest's reports (not the runner's
  whole private dir, which holds the turns' logs). **What remains:
  the network is open** (the model is remote), so `curl` could reach upstream outline on GitHub;
  **WSL interop stays enabled on the host,** though from inside the sandbox its sockets
  (`/run/WSL`) and the Windows drives (`/mnt`) are hidden. Tool calls that
  touch GitHub, `curl`, `wget`, git remotes or paths outside the run are flagged per run, and
  **flagged runs are reviewed by hand before the verdict;** the write-up says how many there
  were.
- **Processes:** Claude Code starts each Bash command and each hook in a session of its own,
  which a process-group kill doesn't reach (verifier's re-check: captAInHook's daemon, with cwd
  `/`, outlived every arm 2 and 3 run). So the sandbox has its own pid namespace, and
  everything started inside dies with it at the end of each turn: **each turn's captAInHook
  daemon dies at turn end, in every arm,** and the next turn's first hook starts a fresh one.
  The runner-started pharos daemon runs outside and stays for the run. Anything still working
  under the run dir after a turn is killed; if anything survives, the run is invalid and the
  scheduler retries it. The measure never runs beside a leftover process.
- **Runtime directory:** `XDG_RUNTIME_DIR=$(mktemp -d /tmp/rtXXXXXX)`, mode 0700, 15
  characters. The runner checks that `captainHook version` reports it, and refuses to run if it
  reports the shared fallback.
- **captAInHook:** the run's own `handlers.json` registers the arm's hook. Arm 1: none.
  - **Arm 2:** `compiler-hook.sh` with the contract's checker:
    `<proj>/node_modules/.bin/tsc --noEmit --incremental --pretty false --tsBuildInfoFile <run>/hook.tsbuildinfo -p <proj>/tsconfig.json`.
  - **Arm 3:** `pharos-hook.sh --root <proj>`, with `passEnv: ["XDG_RUNTIME_DIR"]`.
  - **Both:** events UserPromptSubmit, PreToolUse, PostToolUse and Stop; `mode` oneshot,
    `failMode` open, one `budgetMs` for both arms (from setup check 3).
- **Claude Code:** its own config directory (`CLAUDE_CONFIG_DIR=<run>/claude`), with
  captAInHook's Claude Code integration as the hook source, and the hook timeout above the
  budget. It runs `claude -p` with `--strict-mcp-config` and an empty MCP config, and
  `--output-format stream-json --verbose`.
  - **Environment:** `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic` and
    `ANTHROPIC_AUTH_TOKEN` from `DEEPSEEK_API_KEY`, which is read from the environment and never
    logged.
  - **Model names:** all six pinned to `deepseek-v4-pro` (`ANTHROPIC_MODEL`,
    `ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_`, `_HAIKU_`, `ANTHROPIC_SMALL_FAST_MODEL`,
    `CLAUDE_CODE_SUBAGENT_MODEL`). DeepSeek's guide uses names like `deepseek-flash[1m]`; the
    dry run confirms the exact spelling is accepted (its docs also say names not starting with
    `claude` return a 400, which the guide's own example contradicts).
  - **Effort:** `CLAUDE_CODE_EFFORT_LEVEL` fixed, recorded in the write-up. DeepSeek ignores
    `budget_tokens` and honours only `effort`.
- **Web tools and subagents off** in every arm: `--disallowedTools WebSearch WebFetch Agent`
  (the maintainer, 2026-11-19), recorded in every run's record. DeepSeek serves Claude Code's
  web search, so without it an agent could look up outline's code online; that costs tokens and
  isn't part of the question. For subagents, see section 0.

**Warm start**, before the first turn:

- **Arm 2:** one checker run (prime the incremental state).
- **Arm 3:** `pharos diagnostics --json <one program file>` under exactly the hook's
  environment (stripped, plus `XDG_RUNTIME_DIR`), repeated until it answers `ok` with the trial
  tsconfig as its project. Before the projectInfo fix (section 4) a cold daemon's first answer
  was `unsure`/`no_project`, because projectInfo ran out its 2 s while tsserver loaded the
  project; with the fix the first answer is `ok` with the project (verifier-two, on a real
  tsserver, 4 of 4 cold rounds). The loop stays as a guard. The runner then checks that the daemon socket it reached is the run's own.
- **Arm 1:** nothing to prime. It runs on the same machine and under the same isolation.

**Measuring check**, after each turn's final Stop (its time isn't counted):

- **Compiler:** `tsc --noEmit --incremental --pretty false --tsBuildInfoFile <run>/measure.tsbuildinfo -p tsconfig.json`,
  parsed to keys and counted against the task's start, including errors with no file (keyed
  with an empty path).
- **Tests:** the task's vitest projects, compared test by test with the start: a test (by file
  and name, counted once per project that runs it) that passed at the start and doesn't pass
  now makes the turn broken. A test that failed at the start (T4's shipped tests, T5's bug
  test) doesn't.
- **The start** (the measuring check's keys, the passing tests, the scope check) is the same for
  every run of a task, so `run.py --prepare` computes it once per task and caches it, with the
  measuring check's tsbuildinfo, which makes each run's first measure incremental.
- **Nothing the measure does stays visible to the agent:** vitest's cache (which would name
  the hidden tests it ran) is set aside before and restored after, its reports go to a
  fresh report-only dir outside the project, the hidden test is removed, and any path the measure leaves changed is
  flagged.

**Order:** rounds (`rounds.py`). Each round runs every task once under each arm, in a random
order seeded per round (`pharos-trial-007/<round>`), the whole plan written before the first
run and every record carrying its slot. Strictly one run at a time: the scheduler holds a lock,
every run holds a machine-wide one, and before each run the scheduler waits for the 1-minute
load to drop under 2.0. It resumes after an interruption (a slot with a valid record is done;
an invalid run is retried once), stops on a `STOP` file, and spends tokens only with `--go`.
Only records of the same kind fill a slot: a smoke record, or a run at another effort, never
counts as a real run done. Start and end times are recorded, because
DeepSeek's peak hours double the price and its latency drifts.

**Recorded per run:**

- **Broken turns, and "done":** from the measuring check and the task's tests.
- **The agent's own build and test runs:** Bash tool calls matching `tsc`, `yarn tsc`,
  `vitest`, `yarn test…`, `yarn lint`, `oxlint`, counted from the stream.
- **Tokens:**
  - input: `input_tokens + cache_read_input_tokens`, with cached input also reported on its own;
  - output: thinking included.

  Summed over every assistant message, subagents included.
- **Wall time:** of each turn, and of the run.
- **Each arm's `trial.unsure` lines and budget kills,** from the run's captAInHook trail.
- **Each hook call's time,** per event, from the trail's dispatch records.
- **A scope flag:** the run's tree gained a `tsconfig*.json` (setup check 4).
- **Versions,** recorded in every run's record: node 22.23.5 and yarn 4.11.0 (setup check 1);
  pharos **0.3.4** (the published linux-x64 tarball, sha256 `213ffb20…`, installed by its
  `install.sh`; it carries the projectInfo fix of 0.3.3 and the `.tsx` fix below); typescript-language-server
  5.1.3; captAInHook 0.1.6; Claude Code 2.1.328; TypeScript 6.0.3 (the project's own, which the
  runner checks tsserver runs); and the DeepSeek model (`DeepSeek-V4-Pro-0813` per its pricing
  page).
- **The hooks, pinned by content** (the runner refuses to start if either changes): arm 2,
  captAInHook 833f082's `examples/payloads/compiler-hook.sh`, sha256 `d3d5c29c…`; arm 3, the
  0.3.4 release's `integrations/captainhook/pharos-hook.sh`, sha256 `1a2a772f…` (byte-identical
  to 0.3.3's). Both match `Bash|Agent|Task`.
- **Anomalies,** flagged in the record: an arm 3 run without exactly one pharos socket (or an
  arm 1 or 2 run with any), a tsserver that isn't the project's own, a measure that left a
  path changed, a tool call reaching outside the run.

## 4. The dry run

**One task (T2, a cross-file refactor), each arm once: 3 runs, plus one separate tiny run.**
Before it, the setup checks above. It confirms:

- **Hooks fire:** captAInHook's trail shows all four events dispatched for arms 2 and 3, and the
  hooks' answers (inject and decide) reach the agent. With arm 3, `pharos daemon status`
  under the run's environment shows the hook's sessions on the warm daemon, not a second one.
- **Subagents carry the parent's session id** (a contract assumption). This is checked in
  the separate tiny run, not in T2, so T2's numbers stay clean. Arm 3, a one-file project, and a
  prompt that asks for a Task subagent to make one edit. The runner checks that the hook events
  from the subagent's tool calls carry the parent's `sessionId`. If they don't, the per-session
  lock and turn state don't hold, and the contract needs a change before the real runs. The
  tiny run's cost is listed on its own below.
- **Model, thinking and effort:** every request is answered by `deepseek-v4-pro`, with no 400
  on the model names. Thinking blocks appear, and the effort level is applied.
- **Usage fields:** `cache_read_input_tokens` is present, and token totals add up per message.
- **The measuring check and the recording** produce a complete JSONL line per run.
- **Timings:** per-turn wall time and tokens, for the cost estimate below.

**Results (2026-11-19, 03:37–04:31 UTC, effort `high`, pharos 0.3.2, budget 150 s):**

- **The probe** found subagents asynchronous (section 0). Every hook event did carry the
  parent's session id.
- **T2 × 3 arms** (order 3, 1, 2): every turn of every arm done and not broken.

  | Arm | Wall, turn 1 + 2 | Input (uncached) | Cache reads | Output (thinking) | Hook calls |
  |---|---|---|---|---|---|
  | 1 | 163 + 90 s | 24.5k | 410k | 9.5k (3.3k) | none |
  | 2 | 541 + 708 s | 22.9k | 248k | 7.8k (2.2k) | PostToolUse median 6.4 s, max 116 s; Stop 8.0 s |
  | 3 | 272 + 186 s | 35.8k | 807k | 9.0k (2.9k) | PostToolUse median 0.33 s, max 12 s; Stop 0.13 s |

- **Found and fixed before the full runs:** arm 3 read 11 checks as unsure because pharos asked
  tsserver for the file's project first under a 2 s cap (fixed in pharos 0.3.3); pharos opened
  every TypeScript-family file as `typescript`, so a `.tsx` file tsserver hadn't loaded with
  the project (arm 3's warm-start file, a new file) was parsed without JSX, with bogus syntax
  errors (#17, fixed in pharos 0.3.4; on T6's start `Folder.tsx` went from 2 errors to 0
  through the hook); the hooks
  matched the subagent tool's old name (fixed in both); the runner registered only Stop at
  first, took output tokens from the stream (DeepSeek reports them only in each turn's result),
  and counted captAInHook's teardown kill as a budget kill (all fixed). Arm 2's 116 s check set
  the budget (setup check 3).

## 5. Cost

**Prices** (DeepSeek's own pricing page, read 2026-11-18): `deepseek-v4-pro`, per million
tokens.

| | Off-peak | Peak |
|---|---|---|
| Input, cache hit | $0.022 | $0.044 |
| Input, cache miss | $0.66 | $1.32 |
| Output | $1.98 | $3.96 |

Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday to Friday. The page doesn't say how
thinking tokens are billed; they're assumed to be output.

**Measured in the dry run** (T2, one run per arm): $0.072–0.118 a run at peak prices, a mean of
$0.093 (about $0.046 off-peak). Cache reads are 75–95% of input, so output and uncached input
dominate. T2 is a mid-sized task; the others may run longer, hence the margin.

| Size | Runs | At the dry run's mean | With a ×3 margin |
|---|---|---|---|
| 6 tasks × 3 arms × 5 runs | 90 | ≈ $4.20 off-peak, ≈ $8.40 peak | ≤ ≈ $25 |
| 6 tasks × 3 arms × 10 runs | 180 | ≈ $8.40 off-peak, ≈ $17 peak | ≤ ≈ $50 |
| Dry run and two probes | 5 | ≈ $0.25 actual | |

**Wall time is the bigger cost.** Runs can't overlap (the contract, and parallel runs would
slow arm 2's CPU-bound checks). The dry run's runs took 8.5 (arm 1), 12.1 (arm 3) and 28.0
(arm 2) minutes, a mean of 16 minutes, about 1.25 minutes of which (the 75 s start check)
the cached start now saves: **90 runs ≈ 22 hours**. Arm 2's share grows on tasks with many shape-changing edits
(about 47 s per check on a quiet machine). The machine must stay quiet throughout (setup
check 3).

**Sized by the maintainer (2026-11-19): 90 runs.**

## 6. Open points for review

Decided by the maintainer (2026-11-19):

1. The task mix: three cross-file, three local; reported per kind and pooled; the verdict by
   the contract's rule.
2. Two user turns per run.
3. Web tools off in every arm.
4. The setup checks start now (no tokens).
5. The dry run (with the subagent probe) after verifier-two passes this design, **then a
   pause**: no further runs until the maintainer decides the size from the dry run's numbers.

Decided after the dry run (2026-11-19): no subagents (`Agent` off in every arm); the
projectInfo fix (pharos 0.3.3), the `.tsx` languageId fix (pharos 0.3.4, #17) and the `Agent`
name in both hooks, re-pinned; verifier's pre-flight fixes (standalone start repos, the
bubblewrap sandbox, the vitest cache restored, the scheduler, process-group kills, versions and
anomalies per run, the scope check per start state), with flagged runs reviewed by hand; arm 2's budget
re-measured on the tasks' own edits (240 s, hook timeout 270 s); 90 runs; arm 2 is the plain
compiler hook, with no claim about `tsc --watch`. **The 90 runs wait for the maintainer's
separate go.**

Still open: the contract amendments for the scope check (draft c4318f44) and TypeScript-only
scope (7fa13b5e), built to meanwhile.

Settled in review (2026-11-19):

- The verdict is the contract's "clearly beats" exactly; per-kind results and "done" are
  descriptive (section 0).
- The scope check runs once per task start state, over the project's own files, with the same
  tools as the runs, and a flag for runs that add a tsconfig (setup check 4).
- The budget comes from the larger of a leaf edit's and a shared-type edit's warm check (setup
  check 3).
- No databases: no task depends on server behaviour (section 1).
