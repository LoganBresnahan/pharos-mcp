#!/usr/bin/env bash
#
# ADR-030 T1-T5: crash-repro suite.
#
# Each test exercises one failure mode the ADR-030 layers fix and
# asserts the post-condition. Tests are sequential, stop-on-fail by
# default; pass --keep-going to run them all regardless.
#
# Requires: a freshly-built burrito binary at
# `burrito_out/pharos_linux_x64`. Run `MIX_ENV=prod mix release
# --overwrite` if you have edited source.
#
# Exits 0 when every gating test passes; non-zero when any fails.

set -u

PHAROS_BIN="${PHAROS_BIN:-$(dirname "$0")/../../burrito_out/pharos_linux_x64}"
KEEP_GOING="${KEEP_GOING:-0}"

if [[ ! -x "$PHAROS_BIN" ]]; then
    echo "fatal: pharos binary not found at $PHAROS_BIN" >&2
    echo "       run: MIX_ENV=prod mix release --overwrite" >&2
    exit 1
fi

# Ensure a clean burrito extract for each run so cached old code
# does not silently mask a regression.
BURRITO_CACHE="$HOME/.local/share/.burrito"
rm -rf "$BURRITO_CACHE"/pharos_erts-* 2>/dev/null || true

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"crash-repro","version":"1.0"}}}'

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

run_test() {
    local name="$1"
    local fn="$2"
    echo "=== $name ==="
    if $fn; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$name")
        if [[ "$KEEP_GOING" != "1" ]]; then
            echo
            echo "stopping (set KEEP_GOING=1 to continue past failures)" >&2
            exit 1
        fi
    fi
    echo
}

# ----------------------------------------------------------------------
# T1: closed stderr (2>&-) must not produce a crash dump, and pharos
#     must still answer the initialize request on stdout.
#
# Tests: ADR-030 B1 (pharos_logger_h + sys.config disable of dangerous
#        default handlers + Elixir Logger disable).
# ----------------------------------------------------------------------
test_t1_closed_stderr() {
    local repo_root
    repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
    rm -f "$repo_root/erl_crash.dump"

    local stdout_file
    stdout_file="$(mktemp)"
    echo "$INIT" | timeout 8 "$PHAROS_BIN" 2>&- > "$stdout_file"

    local hit
    hit=$(grep -c '"jsonrpc":"2.0"' "$stdout_file")

    if [[ -e "$repo_root/erl_crash.dump" ]]; then
        echo "    erl_crash.dump created in cwd — boot panicked"
        rm -f "$repo_root/erl_crash.dump"
        rm -f "$stdout_file"
        return 1
    fi
    if [[ "$hit" -lt 1 ]]; then
        echo "    pharos did not return a JSON-RPC initialize result on stdout"
        rm -f "$stdout_file"
        return 1
    fi
    if grep -v '^{' "$stdout_file" | grep -q '\[.*\]\|EROR\|NTCE\|=ERROR REPORT'; then
        echo "    stdout polluted by non-JSON log lines (B1 regression):"
        grep -v '^{' "$stdout_file" | head -3 | sed 's/^/      /'
        rm -f "$stdout_file"
        return 1
    fi
    rm -f "$stdout_file"
    return 0
}

# ----------------------------------------------------------------------
# T2: SIGTERM during normal operation must end with no instance dir
#     left behind (graceful shutdown ran clear_instance_dir).
#
# Tests: ADR-030 S1+S2+S3 (OTP-default signal handling + per-LSP PID
#        tracking + app stop callback clears the dir).
# ----------------------------------------------------------------------
test_t2_sigterm_clean() {
    rm -rf "$HOME/.local/share/pharos/instances/" 2>/dev/null
    echo "$INIT" | "$PHAROS_BIN" 2>/dev/null > /dev/null &
    local pharos_pid=$!
    sleep 2
    if [[ ! -d "$HOME/.local/share/pharos/instances/$pharos_pid" ]]; then
        echo "    pharos did not create its instance dir (S3 regression)"
        kill "$pharos_pid" 2>/dev/null
        return 1
    fi
    kill -TERM "$pharos_pid" 2>/dev/null
    sleep 6
    if [[ -d "$HOME/.local/share/pharos/instances/$pharos_pid" ]]; then
        echo "    instance dir remained after graceful SIGTERM (S1/S2 regression)"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------
# T3: a simulated orphan dir is detected by --cleanup and reaped by
#     --cleanup --yes; the instance dir disappears.
#
# Tests: ADR-030 Layer 3 cleanup CLI + dispatch_meta_or_continue hook.
# ----------------------------------------------------------------------
test_t3_cleanup_cli() {
    rm -rf "$HOME/.local/share/pharos/instances/" 2>/dev/null
    mkdir -p "$HOME/.local/share/pharos/instances/77777"
    cat > "$HOME/.local/share/pharos/instances/77777/55555.pid" <<EOF
pharos_pid=77777
lsp_pid=55555
lsp_binary=/usr/bin/rust-analyzer
server_id=rust-analyzer
workspace=/tmp/crash-repro-fixture
started_at=2026-05-22T00:00:00Z
EOF

    local dry
    dry="$("$PHAROS_BIN" --cleanup 2>/dev/null)"
    if ! grep -q "PID 77777 (dead)" <<< "$dry"; then
        echo "    --cleanup dry-run did not list the orphan:"
        echo "$dry" | sed 's/^/      /'
        return 1
    fi
    if [[ ! -d "$HOME/.local/share/pharos/instances/77777" ]]; then
        echo "    --cleanup deleted the orphan dir without --yes (safety regression)"
        return 1
    fi

    "$PHAROS_BIN" --cleanup --yes >/dev/null 2>&1
    if [[ -d "$HOME/.local/share/pharos/instances/77777" ]]; then
        echo "    --cleanup --yes did not remove the orphan dir"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------
# T4: multiple sequential pharos runs leave per-PID timestamped
#     session logs that LRU-trim to (keep + 1) under the cache dir.
#
# Tests: ADR-030 C2 (default PHAROS_LOG_FILE + rotate_sessions).
# ----------------------------------------------------------------------
test_t4_session_log_rotation() {
    local log_dir="$HOME/.cache/pharos/log"
    mkdir -p "$log_dir"
    rm -f "$log_dir"/session-*.log

    # Fast heartbeat keeps each run short.
    for i in $(seq 1 12); do
        echo "$INIT" | PHAROS_HEARTBEAT_INTERVAL_MS=500 timeout 2 \
            "$PHAROS_BIN" 2>/dev/null >/dev/null
        sleep 0.1
    done

    local n
    n=$(ls "$log_dir"/session-*.log 2>/dev/null | wc -l)
    # Steady state is keep + 1 because LRU runs before the active
    # session creates its file. Acceptable per ADR-030.
    if [[ "$n" -lt 10 ]] || [[ "$n" -gt 12 ]]; then
        echo "    expected 10-12 session-*.log files (LRU keep=10), found $n"
        ls "$log_dir"/session-*.log 2>/dev/null | sed 's/^/      /'
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------
# T5: idle survival.
#
# Spawn pharos, send initialize, sleep 10 seconds (no further calls),
# then send tools/list — should still succeed. The ADR's full-bore
# test sleeps 600 seconds with three LSP sessions; we keep the smoke
# test at 10 seconds to fit a CI pass. The parallel-x5 form is an
# investigative driver, not gating.
#
# Tests: ADR-030 failure mode 3 (silent idle death). I1 heartbeat
#        emits log lines during the idle period; if pharos dies the
#        log gap pinpoints the failure window.
# ----------------------------------------------------------------------
test_t5_idle_smoke() {
    local pipe
    pipe="$(mktemp -u)"
    mkfifo "$pipe"
    "$PHAROS_BIN" < "$pipe" > /tmp/t5-stdout.log 2>/tmp/t5-stderr.log &
    local pharos_pid=$!
    exec 9>"$pipe"
    echo "$INIT" >&9
    sleep 10
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >&9
    sleep 2
    exec 9>&-
    rm -f "$pipe"
    sleep 2
    kill "$pharos_pid" 2>/dev/null
    wait "$pharos_pid" 2>/dev/null

    local results
    results=$(grep -c '"jsonrpc":"2.0"' /tmp/t5-stdout.log)
    if [[ "$results" -lt 2 ]]; then
        echo "    expected 2 JSON-RPC responses (initialize + tools/list), got $results"
        tail -3 /tmp/t5-stderr.log | sed 's/^/      stderr: /'
        return 1
    fi
    # Confirm heartbeat fired at least once during the idle window.
    if ! grep -q "pharos/heartbeat" /tmp/t5-stderr.log; then
        echo "    no heartbeat lines in stderr (I1 regression — log timeline missing)"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# T6: stdin-EOF graceful exit. When the parent closes its end of the
#     stdio pipe (the way MCP clients and our benchmark harness end
#     a session), pharos's stdio_worker drains in-flight requests
#     and then init:stop()s the runtime so app stop callbacks fire.
#     The per-PID instance dir must be gone after pharos exits, and
#     pharos must exit with code 0.
#
# Tests: ADR-030 graceful-exit fix (`init_stop()` in
#        `stdio_worker.handle_eof/1` + `step_inflight/1`). Without
#        this fix the parent harness has to SIGKILL pharos after 5s
#        timeout and the instance dir leaks.
# ----------------------------------------------------------------------
test_t6_stdin_eof_clean() {
    rm -rf "$HOME/.local/share/pharos/instances/" 2>/dev/null
    echo "$INIT" | "$PHAROS_BIN" 2>/dev/null > /dev/null &
    local pharos_pid=$!
    sleep 2
    if [[ ! -d "$HOME/.local/share/pharos/instances/$pharos_pid" ]]; then
        echo "    pharos did not create its instance dir"
        kill "$pharos_pid" 2>/dev/null
        wait "$pharos_pid" 2>/dev/null
        return 1
    fi
    # `echo` finished and closed the pipe. Wait for pharos to exit
    # naturally — bash's `wait` for a backgrounded child returns the
    # actual exit code. If the fix is in place pharos exits within
    # ~1s; cap at 10s.
    local waited=0
    while [[ $waited -lt 10 ]] && kill -0 "$pharos_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pharos_pid" 2>/dev/null; then
        echo "    pharos did not exit within 10s of stdin EOF (fix regression)"
        kill "$pharos_pid" 2>/dev/null
        wait "$pharos_pid" 2>/dev/null
        return 1
    fi
    local exit_code
    wait "$pharos_pid"
    exit_code=$?
    if [[ "$exit_code" != "0" ]]; then
        echo "    pharos exited with code $exit_code (expected 0)"
        return 1
    fi
    if [[ -d "$HOME/.local/share/pharos/instances/$pharos_pid" ]]; then
        echo "    instance dir remained after stdin-EOF exit (fix regression)"
        return 1
    fi
    return 0
}

run_test "T1 closed-stderr"          test_t1_closed_stderr
run_test "T2 sigterm-clean"          test_t2_sigterm_clean
run_test "T3 cleanup-cli"            test_t3_cleanup_cli
run_test "T4 session-log-rotation"   test_t4_session_log_rotation
run_test "T5 idle-smoke"             test_t5_idle_smoke
run_test "T6 stdin-eof-clean"        test_t6_stdin_eof_clean

echo "=============================="
echo "passed: $PASS_COUNT"
echo "failed: $FAIL_COUNT"
if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    printf "  - %s\n" "${FAILED_TESTS[@]}"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
