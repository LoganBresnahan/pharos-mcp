#!/usr/bin/env bash
#
# Out-of-band dogfood harness for pharos.
#
# Runs the integration scenarios that need a fresh pharos boot with a
# controlled environment — things gleeunit cannot exercise because they
# touch process spawn, env vars, the filesystem, or signal handling.
#
# Usage:
#   test/dogfood/run-all.sh              # run every scenario
#   test/dogfood/run-all.sh override     # run one scenario by name
#
# Available scenarios:
#   override          ADR-018 BinaryNotFound + override-file dogfood
#   env_matrix        Every PHAROS_* env var honoured by --doctor
#   toml_precedence   global TOML < project TOML (walk-up) < env var
#   port_file         port_file lands a complete port number
#
# Runtime: each scenario boots pharos at least once (~5-15s per boot
# depending on whether mix has cached compile artefacts). Allow 1-3 min
# for the full suite. Run individual scenarios while iterating.
#
# Exit codes:
#   0 — every scenario passed
#   1 — at least one scenario failed
#
# Prerequisites:
#   - bin/pharos-dev compiles + boots pharos via stdin/stdout
#   - jq on PATH
#   - Erlang + mix + gleam on PATH (asdf shims work)

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHAROS_BIN="$PROJECT_ROOT/bin/pharos-dev"
TMP_ROOT="$(mktemp -d -t pharos-dogfood-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

# -----------------------------------------------------------------------
# Helpers

# Build NDJSON for a tools/call request. Initialize → initialized →
# tools/call. Pipe to stdin of pharos.
build_tools_call() {
  local tool="$1"
  local args_json="$2"
  cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"dogfood","version":"0"}}}
{"jsonrpc":"2.0","method":"initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"$tool","arguments":$args_json}}
EOF
}

# Extract the response body for the second request (tools/call) from
# an NDJSON pharos response stream. Returns empty string if absent.
second_response() {
  local stream="$1"
  printf '%s\n' "$stream" | jq -c 'select(.id == 2)' 2>/dev/null | head -n1
}

pass() {
  PASS=$((PASS + 1))
  printf '\033[32mPASS\033[0m  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '\033[31mFAIL\033[0m  %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '       %s\n' "$2"
  fi
}

# Run pharos --doctor with the supplied env (and optional cwd).
# Outputs the captured stdout. Stderr is discarded.
run_doctor() {
  local cwd="${1:-$PROJECT_ROOT}"
  shift
  ( cd "$PROJECT_ROOT" && env "$@" mix run -e ':pharos@cli.doctor()' --no-start 2>/dev/null )
}

# Run pharos --doctor with explicit cwd for the BEAM process. Trick:
# wrap erl invocation inside a script that cd's to the dir, then runs
# `pharos:cli:doctor()`.
run_doctor_in_dir() {
  local cwd="$1"
  shift
  # Build code-path glob — needs to be expanded inside the parent shell
  # since erl's -pa argument cannot be a glob.
  local pas=( $PROJECT_ROOT/build/dev/erlang/*/ebin )
  ( cd "$cwd" && env "$@" erl \
    "${pas[@]/#/-pa }" \
    -noshell \
    -eval 'pharos@cli:doctor(), halt(0).' 2>/dev/null )
}

# -----------------------------------------------------------------------
# Scenario 1+2 — Override-file dogfood (covers missing-binary path).
#
# Three sub-scenarios:
#   (a) Override `command` to a bare name that will NEVER be on PATH —
#       expect BinaryNotFound surfaced with that name.
#   (b) Override `command` to an absolute path that does not exist —
#       expect the absolute path quoted in the error.
#   (c) Negative control: confirm the message format is the typed
#       ADR-018 error, not some generic transport error.

scenario_override() {
  # Workspace-root marker required so pharos walks past the
  # workspace-not-found short-circuit before reaching LSP spawn.
  local ws_dir="$TMP_ROOT/override"
  local rs_file="$ws_dir/src/main.rs"
  mkdir -p "$(dirname "$rs_file")"
  printf 'fn main(){}\n' > "$rs_file"
  cat > "$ws_dir/Cargo.toml" <<'CARGO_EOF'
[package]
name = "dogfood"
version = "0.0.1"
edition = "2021"
CARGO_EOF

  # (a) bare-name override
  local toml_a="$TMP_ROOT/override-bare.toml"
  cat > "$toml_a" <<EOF
[languages.rust]
command = "definitely-not-installed-rust-9876"
EOF
  local input
  input=$(build_tools_call hover "{\"uri\":\"file://$rs_file\",\"line\":0,\"character\":3}")
  local stream
  stream=$(printf '%s\n' "$input" | PHAROS_CONFIG_FILE="$toml_a" "$PHAROS_BIN" 2>/dev/null)
  local content
  content=$(second_response "$stream" | jq -r '.result.content[0].text // empty' 2>/dev/null)

  if [[ "$content" == *"definitely-not-installed-rust-9876"* && "$content" == *"not found on PATH"* ]]; then
    pass "override (bare name → BinaryNotFound)"
  else
    fail "override (bare name → BinaryNotFound)" "got: $content"
  fi

  # (b) absolute-path override (file does not exist)
  local toml_b="$TMP_ROOT/override-abs.toml"
  cat > "$toml_b" <<EOF
[languages.rust]
command = "/nonexistent/custom-rust-analyzer-build"
EOF
  stream=$(printf '%s\n' "$input" | PHAROS_CONFIG_FILE="$toml_b" "$PHAROS_BIN" 2>/dev/null)
  content=$(second_response "$stream" | jq -r '.result.content[0].text // empty' 2>/dev/null)

  if [[ "$content" == *"/nonexistent/custom-rust-analyzer-build"* ]]; then
    pass "override (absolute path quoted in error)"
  else
    fail "override (absolute path quoted in error)" "got: $content"
  fi
}

# -----------------------------------------------------------------------
# Scenario 3 — Boot env var matrix.
#
# Set every env var to a sentinel value, run --doctor, verify the
# resolved Config reflects the values.

scenario_env_matrix() {
  local out
  out=$(run_doctor "" \
    PHAROS_TRANSPORT=http \
    PHAROS_HTTP_PORT=4242 \
    PHAROS_HTTP_BIND=0.0.0.0 \
    PHAROS_LOG=warn \
    PHAROS_LOG_RING=0 \
    PHAROS_LOG_STDERR=0 \
    PHAROS_TRACE_LSP=1 \
    PHAROS_RUNTIME_TRACE_ENABLED=1 \
    PHAROS_TOOLS=read \
    PHAROS_HTTP_PORT_FILE=/tmp/pharos-doctor.port)

  local errors=0
  check() {
    local pattern="$1"
    local label="$2"
    if printf '%s\n' "$out" | grep -qE "$pattern"; then
      :
    else
      errors=$((errors + 1))
      printf '       miss: %s (%s)\n' "$pattern" "$label"
    fi
  }

  check 'transport: +http'                          'PHAROS_TRANSPORT=http'
  check 'http\.bind:port: +0\.0\.0\.0:4242'         'PHAROS_HTTP_PORT + PHAROS_HTTP_BIND'
  check 'http\.port_file: +/tmp/pharos-doctor\.port' 'PHAROS_HTTP_PORT_FILE'
  check 'log\.filter: +warn'                        'PHAROS_LOG=warn'
  check 'log\.ring_enabled: +false'                 'PHAROS_LOG_RING=0'
  check 'log\.stderr_enabled: +false'               'PHAROS_LOG_STDERR=0'
  check 'lsp\.trace: +true'                         'PHAROS_TRACE_LSP=1'
  check 'runtime\.trace_calls: +true'               'PHAROS_RUNTIME_TRACE_ENABLED=1'
  check 'tools\.filter: +\[read\]'                  'PHAROS_TOOLS=read'

  if [ "$errors" -eq 0 ]; then
    pass "env-matrix (9 vars all honoured)"
  else
    fail "env-matrix" "$errors var(s) not reflected in --doctor"
  fi
}

# -----------------------------------------------------------------------
# Scenario 4 — TOML overlay precedence.
#
# Global TOML, project TOML, env override on top. Project beats global,
# env beats both. Verified via --doctor's resolved http.port.

scenario_toml_precedence() {
  local global="$TMP_ROOT/global.toml"
  local project_dir="$TMP_ROOT/proj"
  mkdir -p "$project_dir"
  local project="$project_dir/.pharos.toml"

  cat > "$global" <<EOF
[server.http]
port = 1111
EOF
  cat > "$project" <<EOF
[server.http]
port = 2222
EOF

  # Project beats global. cwd inside project_dir so .pharos.toml is
  # walked-up onto.
  local out_proj
  out_proj=$(run_doctor_in_dir "$project_dir" PHAROS_CONFIG_FILE="$global")
  if printf '%s\n' "$out_proj" | grep -qE 'http\.bind:port: +127\.0\.0\.1:2222'; then
    pass "precedence (project beats global)"
  else
    fail "precedence (project beats global)" \
      "expected port 2222; got: $(printf '%s\n' "$out_proj" | grep 'http.bind:port' || echo '<no line>')"
  fi

  # Env beats both.
  local out_env
  out_env=$(run_doctor_in_dir "$project_dir" \
    PHAROS_CONFIG_FILE="$global" \
    PHAROS_HTTP_PORT=3333)
  if printf '%s\n' "$out_env" | grep -qE 'http\.bind:port: +127\.0\.0\.1:3333'; then
    pass "precedence (env beats both)"
  else
    fail "precedence (env beats both)" \
      "expected port 3333; got: $(printf '%s\n' "$out_env" | grep 'http.bind:port' || echo '<no line>')"
  fi
}

# -----------------------------------------------------------------------
# Scenario 5 — port_file write happens (covers atomic-write integration).
#
# Boot pharos in HTTP mode with port=0 + port_file, wait for the file
# to appear, confirm it parses as a port. Kill -9 mid-write would test
# atomicity stronger but is timing-dependent; skipped here, manual
# recipe in init.md Testing-needed.

scenario_port_file() {
  local port_file="$TMP_ROOT/pharos.port"

  # Boot pharos HTTP listener in background; kill after window.
  PHAROS_TRANSPORT=http \
    PHAROS_HTTP_PORT=0 \
    PHAROS_HTTP_PORT_FILE="$port_file" \
    "$PHAROS_BIN" >/dev/null 2>&1 &
  local pid=$!

  # Wait up to 10s for the file to appear.
  local waited=0
  while [ $waited -lt 100 ] && [ ! -s "$port_file" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [ ! -s "$port_file" ]; then
    fail "port_file" "never written (waited 10s)"
    return
  fi

  local contents
  contents=$(cat "$port_file")
  if [[ "$contents" =~ ^[0-9]+$ ]] && [ "$contents" -gt 0 ] && [ "$contents" -lt 65536 ]; then
    pass "port_file (wrote port $contents)"
  else
    fail "port_file" "invalid port: '$contents'"
  fi
}

# -----------------------------------------------------------------------
# Driver

scenarios=(override env_matrix toml_precedence port_file)

run_scenario() {
  case "$1" in
    override)        scenario_override ;;
    env_matrix)      scenario_env_matrix ;;
    toml_precedence) scenario_toml_precedence ;;
    port_file)       scenario_port_file ;;
    *)
      printf 'unknown scenario: %s\n' "$1" >&2
      printf 'available: %s\n' "${scenarios[*]}" >&2
      return 2
      ;;
  esac
}

if [ $# -eq 0 ]; then
  for s in "${scenarios[@]}"; do
    run_scenario "$s"
  done
else
  run_scenario "$1"
fi

printf '\n--- summary ---\n'
printf '  passed: %d\n' "$PASS"
printf '  failed: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
