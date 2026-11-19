#!/bin/sh
# pharos-hook — a ONESHOT captAInHook payload: pharos's diagnostics of the
# files the agent edits. It is arm 3 of the pharos trial (pharos-mcp#6), and
# follows the contract it shares with arm 2, captAInHook's compiler hook:
# geex's doc/stack-trial-hooks.md. Where this header and that file disagree,
# the file wins. It is built on arm 2's script (captAInHook's
# examples/payloads/compiler-hook.sh) and kept close to it, so the two can be
# read side by side: what differs is the checker, the reach and the scope.
#
# Register it on four events with the SAME args:
#
#   UserPromptSubmit  the turn starts: forget the last one. (Arm 3's reach is
#                     the files touched this turn, so there's no turn-start
#                     snapshot.)
#   PreToolUse        on a writer tool (Write, Edit, MultiEdit, NotebookEdit),
#                     Bash or Task: bump the generation (below), lock-free. On a
#                     writer, the first write to a file this turn then takes
#                     THAT FILE's baseline, its errors just before the write (a
#                     file that doesn't exist yet has an empty one), and resets
#                     its reported counts. Other tools: nothing.
#   PostToolUse       after a writer tool: the new errors not yet reported this
#                     turn, in the files touched this turn, as information
#                     (inject).
#   Stop              if new errors remain in the files touched this turn:
#                     block once with them as the reason. When stop_hook_active
#                     is set, the turn ends: at most one block per turn.
#
#   args: --root <tsconfig dir> [--project <tsconfig>] [--budget-ms N] [--pharos <path>]
#   the trial: ["--root", "<proj>", "--budget-ms", "<N>"]
#
# The checker is `pharos diagnostics --json` on the touched files, through
# the run's own pharos daemon (pass XDG_RUNTIME_DIR, and any pharos daemon-key
# variable the runner sets, in the entry's passEnv: captAInHook strips the
# environment). A file is in scope when pharos names its project as the
# trial tsconfig (--project, default <root>/tsconfig.json): tsserver puts a
# file outside the program in an inferred project, and arm 3 skips it.
# Errors only (LSP severity 1), shown as `<path>:<line>:<col> TS<code> <message>`
# with the LSP position plus 1. Its KEY is (path, code, message): line and
# column move with edits, so they're shown, never compared. An occurrence is
# new when its key occurs more often in the file than in the file's baseline;
# a key's new occurrences are its last ones in sort order (path bytewise,
# line, column, code, message).
#
# Fresh or reused: each PreToolUse on a writer, Bash or Task call appends to a
# generation file (an atomic append, never under the lock, so a read-only call
# never waits on a check). A check records the generation it started under,
# and a baseline or Stop's check reuses the latest result only while the
# generation hasn't moved (a writer's baseline discounts its own bump) and the
# result covers the files asked about. A check run at a writer's PreToolUse is
# never kept for reuse: that write is about to change the disk. A Bash call
# with run_in_background makes every check fresh until the turn ends. Reported
# counts are per key: only new occurrences beyond the ones already reported
# this turn are shown, and a file's counts reset at its first-write baseline.
#
# Unsure means silent. A check or baseline that fails, can't be read, runs
# past --budget-ms (match the entry's budgetMs; the checker is stopped a
# second early so the timeout can be logged), or that pharos marks unsure
# (pharos.carried_over, pharos.not_reported, nothing published in time) says
# nothing for that file, and a file whose baseline is unknown gets no reports
# that turn. Each case logs one stderr line (the trail's exec.stderr):
#   trial.unsure reason=<failed|unparsed|no-baseline|unsure> event=<baseline|PostToolUse|Stop>
# (any detail on a `pharos-hook detail=…` line of its own). Arm 2's
# incomplete-check rule doesn't apply: pharos's own markers govern arm 3.
# A check that ran logs `pharos-hook checked event=… errors=N new=M …`.
#
# Needs jq (without it: noop, logged). Turn state lives on disk per session
# under $PHAROS_HOOK_STATE (default ~/.captainHook/pharos-hook).

ME=pharos-hook
CAP=10
BUDGET_MS=30000
ROOT=""
PROJECT=""
PHAROS=pharos
WRITERS=" Write Edit MultiEdit NotebookEdit "

while [ $# -gt 0 ]; do
  case $1 in
    --budget-ms) BUDGET_MS=$2; shift 2 ;;
    --root)      ROOT=$2; shift 2 ;;
    --project)   PROJECT=$2; shift 2 ;;
    --pharos)    PHAROS=$2; shift 2 ;;
    --)          shift; break ;;
    *)           break ;;
  esac
done

IFS= read -r ENVELOPE || ENVELOPE=$ENVELOPE

if ! command -v jq >/dev/null 2>&1; then
  id=$(printf '%s' "$ENVELOPE" | sed -n 's/.*"dispatchId":"\([^"]*\)".*/\1/p')
  case $(printf '%s' "$ENVELOPE" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p') in
    PostToolUse) ev=PostToolUse ;; Stop) ev=Stop ;; *) ev=baseline ;;
  esac
  printf 'trial.unsure reason=failed event=%s\n%s detail=no-jq\n' "$ev" "$ME" >&2
  printf '{"effect":"noop","dispatchId":"%s"}\n' "$id"
  exit 0
fi

jget() { printf '%s' "$ENVELOPE" | jq -r "$1" 2>/dev/null; }
ID=$(jget '.dispatchId // ""')
EVENT=$(jget '.event.type // ""')
SID=$(jget '.event.sessionId // ""')
CWD=$(jget '.event.cwd // ""')
TOOL=$(jget '.event.payload.tool_name // ""')
TARGET=$(jget '.event.payload.tool_input.file_path // .event.payload.tool_input.notebook_path // ""')
STOP_ACTIVE=$(jget '.event.payload.stop_hook_active // false')

case $EVENT in PostToolUse|Stop) LOG_DEFAULT=$EVENT ;; *) LOG_DEFAULT=baseline ;; esac
LOG_EVENT=$LOG_DEFAULT
log()    { printf '%s %s\n' "$ME" "$*" >&2; }
# The contract's shared line, exactly; any detail goes on a line of its own.
unsure() {
  printf 'trial.unsure reason=%s event=%s\n' "$1" "$LOG_EVENT" >&2
  [ -z "${2:-}" ] || log "detail=$2 reason=$1 event=$LOG_EVENT"
}
answer() { # <effect-json>: the ONE stdout line
  printf '%s' "$1" | jq -c --arg id "$ID" '. + (if $id == "" then {} else {dispatchId: $id} end)'
}
noop()   { answer '{"effect":"noop"}'; }

[ -n "$ROOT" ] || ROOT=$CWD
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  unsure failed "no-root"; noop; exit 0
fi
ROOT=$(cd "$ROOT" && pwd -P)
[ -n "$PROJECT" ] || PROJECT=$ROOT/tsconfig.json
case $PROJECT in /*) ;; *) PROJECT=$ROOT/$PROJECT ;; esac

SAFE=$(printf '%s' "${SID:-unknown}" | tr -c 'A-Za-z0-9_-' '_')
DIR=${PHAROS_HOOK_STATE:-${HOME:-/tmp}/.captainHook/pharos-hook}/$SAFE
mkdir -p "$DIR" 2>/dev/null || { unsure failed "no-state-dir"; noop; exit 0; }

now() { date +%s; }
BUDGET_S=$(( (BUDGET_MS - 1000) / 1000 )); [ "$BUDGET_S" -ge 1 ] || BUDGET_S=1
DEADLINE=$(( $(now) + BUDGET_S ))
nap() { sleep 0.2 2>/dev/null || sleep 1; }

lock() {
  while ! mkdir "$DIR/lock" 2>/dev/null; do
    holder=$(cat "$DIR/lock/pid" 2>/dev/null)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # Steal by rename, then check what we took: another waiter may have
      # stolen the dead lock first and made its own, which goes back.
      if mv "$DIR/lock" "$DIR/lock.stale.$$" 2>/dev/null; then
        if [ "$(cat "$DIR/lock.stale.$$/pid" 2>/dev/null)" = "$holder" ]; then rm -rf "$DIR/lock.stale.$$"
        elif [ ! -e "$DIR/lock" ]; then mv "$DIR/lock.stale.$$" "$DIR/lock" 2>/dev/null || rm -rf "$DIR/lock.stale.$$"
        else rm -rf "$DIR/lock.stale.$$"; fi
      fi
      continue
    fi
    [ "$(now)" -lt "$DEADLINE" ] || return 1
    nap
  done
  echo $$ > "$DIR/lock/pid"
}
unlock() { rm -rf "$DIR/lock"; }

# Atomic write: a budget kill mid-write leaves the old file, never half a new one.
put() { printf '%s\n' "$2" > "$DIR/$1.tmp.$$" && mv -f "$DIR/$1.tmp.$$" "$DIR/$1"; }
get() { if [ -e "$DIR/$1" ]; then cat "$DIR/$1"; else printf '%s\n' "$2"; fi; }

is_writer() { case $WRITERS in *" $TOOL "*) return 0 ;; esac; return 1; }

# The written file's path relative to the root (../ when it's outside). The
# root is a real path (pwd -P), so the target is resolved the same way: its
# deepest directory that exists, then the rest. A write can create
# directories, and macOS's /var is a link to /private/var.
rel_target() {
  [ -n "$TARGET" ] || return 0
  d=$(dirname "$TARGET"); b=$(basename "$TARGET")
  while [ ! -d "$d" ] && [ "$d" != / ] && [ "$d" != . ]; do
    b=$(basename "$d")/$b; d=$(dirname "$d")
  done
  d=$(cd "$d" && pwd -P)
  to=${d%/}/$b; from=$ROOT; up=""
  while :; do
    case "$to" in "$from"/*) break ;; esac
    [ "$from" = / ] && break
    from=$(dirname "$from"); up="../$up"
  done
  if [ "$from" = / ]; then printf '%s%s' "$up" "${to#/}"; else printf '%s%s' "$up" "${to#"$from"/}"; fi
}

# `pharos diagnostics --json`, read into one entry per file, keyed by its
# path relative to the root: {known, scope: in|out, errors: [error objects]}.
# known=false is a file pharos was unsure of, or failed on, or whose project
# it couldn't name (projectInfo is best-effort): scope unknown is unsure, never
# out. scope=out is a file pharos names another project for: outside the
# trial tsconfig's program. Errors only (severity 1), the message
# on one line (every newline and the indentation after it: one space).
PARSE='
  def rel($p): $p | if startswith($root + "/") then .[($root | length) + 1:] else . end;
  [ .files[] | rel(.path) as $f
    | { key: $f,
        value: (if .status != "ok" then {known: false, why: (.reason // .status)}
                elif (.project // "") == "" then {known: false, why: "no-project"}
                elif .project != $project then {known: true, scope: "out", errors: []}
                else {known: true, scope: "in",
                      errors: [ .diagnostics[] | select(.severity == 1)
                                | { file: $f,
                                    line: (.range.start.line + 1), col: (.range.start.character + 1),
                                    code: ("TS" + (.code | tostring)),
                                    n: (if (.code | type) == "number" then .code else 0 end),
                                    msg: (.message | gsub("\\r?\\n\\s*"; " ") | sub("\\s+$"; "")) } ]}
                end) } ]
  | from_entries'

# run_checker <out-file> <rel file…>: pharos's answer for those files as a
# JSON object in $DIR/<out-file>. Returns 0 when pharos ran and could be
# read (files it was unsure of are known=false inside); else logs why and
# returns 1.
run_checker() {
  out=$1; shift
  raw=$DIR/raw.$$
  rm -f "$raw.timeout"
  left=$(( DEADLINE - $(now) )); [ "$left" -ge 1 ] || left=1
  ( cd "$ROOT" && exec "$PHAROS" diagnostics --json --timeout-ms "$(( left * 1000 ))" -- "$@" ) >"$raw" 2>"$raw.err" </dev/null &
  cpid=$!
  # The watchdog marks a timeout only while the checker still runs: cancelling
  # it (below) wakes it early, and it must not mistake that for the deadline.
  ( sleep "$left"; kill -0 "$cpid" 2>/dev/null || exit 0
    : > "$raw.timeout"; pkill -TERM -P "$cpid" 2>/dev/null; kill -TERM "$cpid" 2>/dev/null
    sleep 2; pkill -KILL -P "$cpid" 2>/dev/null; kill -KILL "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  wait "$cpid"; rc=$?
  pkill -P "$wpid" 2>/dev/null; kill "$wpid" 2>/dev/null
  if [ -e "$raw.timeout" ]; then rm -f "$raw" "$raw.err" "$raw.timeout"; unsure failed timeout; return 1; fi
  if [ "$rc" -ne 0 ]; then
    detail=$(head -c 300 "$raw.err" | tr '\n' ' ')
    rm -f "$raw" "$raw.err"; unsure failed "exit=$rc $detail"; return 1
  fi
  all=$(jq -c --arg root "$ROOT" --arg project "$PROJECT" "$PARSE" "$raw" 2>/dev/null) || { rm -f "$raw" "$raw.err"; unsure unparsed; return 1; }
  rm -f "$raw" "$raw.err"
  put "$out" "$all"
  # A file pharos was unsure of says nothing this time.
  printf '%s' "$all" | jq -r 'to_entries[] | select(.value.known | not) | "\(.key) \(.value.why)"' |
    while read -r f why; do unsure unsure "file=$f why=$why"; done
}

# The generation: one line per writer/Bash/Task call this turn.
gen()  { if [ -e "$DIR/gen" ]; then wc -l < "$DIR/gen" | tr -d ' '; else echo 0; fi; }
bump() { echo . >> "$DIR/gen"; }
# reusable <discount> <rel file…>: the latest check still shows the disk, and
# it knows each of those files.
reusable() {
  discount=$1; shift
  [ -e "$DIR/snap.json" ] && [ ! -e "$DIR/bg" ] &&
    [ "$(jq -r '.gen' "$DIR/snap.json")" = "$(( $(gen) - discount ))" ] &&
    [ "$(jq --args '[$ARGS.positional[] as $f | .files[$f].known == true] | all' "$@" < "$DIR/snap.json")" = true ]
}
# fresh_check <rel file…>: pharos's answer into current.json, kept for reuse
# under the generation it started with.
fresh_check() {
  g=$(gen)
  run_checker current.json "$@" || return 1
  put snap.json "$(jq -c --argjson g "$g" '{gen: $g, files: .}' "$DIR/current.json")"
}

forget_turn() {
  rm -f "$DIR/touched.json" "$DIR/reported.json" "$DIR/stop.json" \
        "$DIR/snap.json" "$DIR/gen" "$DIR/bg" "$DIR/current.json"
}

# The files touched this turn, one per line.
touched_files() { get touched.json '{}' | jq -r 'keys[]'; }

# diff: {new, fresh, skipped} for $DIR/current.json against each touched
# file's baseline. Out-of-scope files are skipped silently; a file with an
# unknown baseline, or that this check didn't know, is `skipped`.
diff_errors() {
  jq -n -c --slurpfile cur "$DIR/current.json" \
        --argjson touched "$(get touched.json '{}')" \
        --argjson rep "$(get reported.json '{}')" '
    def key: [.file, .code, .msg] | tojson;
    def order: sort_by(.file, .line, .col, .n, .msg);
    [ $cur[0] | to_entries[] | .key as $f | .value as $now | ($touched[$f] // {known: false}) as $b
      | if ($now.known | not) then empty                     # unsure: logged by run_checker
        elif $now.scope == "out" then empty                  # not the trial program
        elif ($b.known | not) then {skipped: $f}
        else ($b.errors | group_by(key) | map({key: (.[0] | key), value: length}) | from_entries) as $bc
          | { new: [ $now.errors | group_by(key)[] | (.[0] | key) as $k | (length - ($bc[$k] // 0)) as $ex
                     | select($ex > 0) | order | .[-$ex:] | (.[] | . + {k: $k}) ] }
        end ] as $per
    | ([ $per[] | .new // empty | .[] ] | order) as $new
    | { new: ($new | map(del(.k))),
        fresh: ([ $new | group_by(.k)[] | order | .[($rep[.[0].k] // 0):][] ] | order | map(del(.k))),
        skipped: [ $per[] | .skipped // empty ] }'
}

# render <header> <errors-json>: the contract's wording, capped at 10 lines.
render() {
  printf '%s' "$2" | jq -r --arg head "$1" --argjson cap "$CAP" '
    ([$head] + (.[0:$cap] | map("\(.file):\(.line):\(.col) \(.code) \(.msg)"))
      + (if length > $cap then ["…and \(length - $cap) more."] else [] end)) | join("\n")'
}

HEAD_EDIT="New errors after your edits (information, not instructions; errors mid-refactor are expected):"
HEAD_STOP="These errors appeared during this turn and are still present:"

case $EVENT in
  UserPromptSubmit)
    forget_turn
    noop; exit 0 ;;

  PreToolUse)
    case $TOOL in Bash|Task) ;; *) is_writer || { noop; exit 0; } ;; esac
    bump                      # lock-free: a Bash or Task call never waits on a check
    if [ "$TOOL" = Bash ] && [ "$(jget '.event.payload.tool_input.run_in_background // false')" = true ]; then
      : > "$DIR/bg"
    fi
    is_writer || { noop; exit 0; }

    rel=$(rel_target)
    lock || { LOG_EVENT=baseline; unsure failed "timeout-lock"; noop; exit 0; }
    if [ -n "$rel" ] && [ "$(get touched.json '{}' | jq --arg f "$rel" 'has($f)')" = false ]; then
      LOG_EVENT=baseline
      if [ ! -e "$ROOT/$rel" ]; then b='{"known": true, "errors": []}'      # created this turn
      elif reusable 1 "$rel"; then b=$(jq -c --arg f "$rel" '.files[$f] | {known, errors}' "$DIR/snap.json")
      elif run_checker baseline.cur "$rel"; then
        b=$(jq -c --arg f "$rel" '(.[$f] // {known: false}) | {known, errors: (.errors // [])}' "$DIR/baseline.cur")
      else b='{"known": false}'; fi
      put touched.json "$(get touched.json '{}' | jq -c --arg f "$rel" --argjson b "$b" '.[$f] = $b')"
      put reported.json "$(get reported.json '{}' | jq -c --arg f "$rel" 'with_entries(select((.key | fromjson | .[0]) != $f))')"
      LOG_EVENT=$LOG_DEFAULT
    fi
    unlock
    noop; exit 0 ;;

  PostToolUse)
    is_writer || { noop; exit 0; }
    lock || { unsure failed "timeout-lock"; noop; exit 0; }
    files=$(touched_files)
    if [ -z "$files" ]; then unlock; noop; exit 0; fi
    # shellcheck disable=SC2086 # one rel path per line, no spaces (pharos-mcp#16)
    fresh_check $files || { unlock; noop; exit 0; }
    d=$(diff_errors)
    fresh=$(printf '%s' "$d" | jq -c '.fresh')
    shown=$(printf '%s' "$fresh" | jq -c --argjson cap "$CAP" '.[0:$cap]')
    put reported.json "$(get reported.json '{}' |
      jq -c --argjson s "$shown" 'reduce ($s[] | [.file, .code, .msg] | tojson) as $k (.; .[$k] += 1)')"
    unlock
    [ "$(printf '%s' "$d" | jq '.skipped | length')" -eq 0 ] || unsure no-baseline "files=$(printf '%s' "$d" | jq -r '.skipped | join(",")')"
    log "checked event=PostToolUse errors=$(jq '[.[] | .errors // [] | length] | add // 0' "$DIR/current.json") new=$(printf '%s' "$d" | jq '.new | length') fresh=$(printf '%s' "$fresh" | jq length)"
    if [ "$(printf '%s' "$fresh" | jq length)" -eq 0 ]; then noop
    else answer "$(jq -cn --arg t "$(render "$HEAD_EDIT" "$fresh")" '{effect: "inject", text: $t}')"; fi
    exit 0 ;;

  Stop)
    # At most one block per turn: an agent already continuing from our block
    # (stop_hook_active) ends the turn, whatever the errors.
    if [ "$STOP_ACTIVE" = true ] || [ -e "$DIR/stop.json" ]; then
      forget_turn; noop; exit 0
    fi
    lock || { unsure failed "timeout-lock"; forget_turn; noop; exit 0; }
    files=$(touched_files)
    # Nothing touched this turn: nothing for arm 3 to check.
    if [ -z "$files" ]; then forget_turn; unlock; noop; exit 0; fi
    # shellcheck disable=SC2086
    if reusable 0 $files; then jq -c '.files' "$DIR/snap.json" > "$DIR/current.json"
    else fresh_check $files || { forget_turn; unlock; noop; exit 0; }; fi
    d=$(diff_errors)
    new=$(printf '%s' "$d" | jq -c '.new')
    [ "$(printf '%s' "$d" | jq '.skipped | length')" -eq 0 ] || unsure no-baseline "files=$(printf '%s' "$d" | jq -r '.skipped | join(",")')"
    log "checked event=Stop errors=$(jq '[.[] | .errors // [] | length] | add // 0' "$DIR/current.json") new=$(printf '%s' "$new" | jq length)"
    if [ "$(printf '%s' "$new" | jq length)" -eq 0 ]; then forget_turn; unlock; noop; exit 0; fi
    put stop.json '{"blocked":true}'
    unlock
    answer "$(jq -cn --arg r "$(render "$HEAD_STOP" "$new")" '{effect: "decide", verdict: "deny", reason: $r}')"
    exit 0 ;;

  *) noop; exit 0 ;;
esac
