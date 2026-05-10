#!/usr/bin/env bash
#
# Phase 8 — run the entire test matrix against the burrito-built
# binary, not bin/pharos-dev. Catches stdio-class bugs that only
# surface under -noshell -mode embedded -noinput release runtime.
#
# Steps:
#   1. Clear burrito's cache (M11 cache-key bug — same `app_version`
#      means stale beams persist across rebuilds; see ADR-020).
#   2. Build the release.
#   3. Pre-warm the extract via npm postinstall script (so the first
#      pharos invocation doesn't pay the ~50s xz extract during a
#      test).
#   4. Set PHAROS_TEST_BIN to the burrito binary; every drive() in
#      the harness scripts honors this and spawns the binary instead
#      of bin/pharos-dev.
#   5. Run every harness, exit non-zero on any failure.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Phase 8 — burrito dogfood ==="
echo

echo "[1/6] Clearing burrito cache..."
rm -rf ~/.local/share/.burrito/pharos_erts-*

echo "[2/6] Building release..."
MIX_ENV=prod mix release --overwrite 1>&2

# postinstall.js launches `npm/vendor/pharos_<target>` to warm the
# extract. If that binary is older than `burrito_out/`, the warmup
# unpacks STALE beams and every subsequent run targets dead code —
# observed silently dropping all `pharos@tools/*` modules added since
# the vendor was last refreshed. Copy the freshly-built binary in
# before warming.
echo "[3/6] Refreshing npm/vendor from burrito_out..."
mkdir -p "$PROJECT_ROOT/npm/vendor"
for bin_file in "$PROJECT_ROOT"/burrito_out/pharos_*; do
  [ -e "$bin_file" ] || continue
  cp "$bin_file" "$PROJECT_ROOT/npm/vendor/$(basename "$bin_file")"
done

echo "[4/6] Warming extract via npm postinstall..."
node "$PROJECT_ROOT/npm/scripts/postinstall.js" 1>&2 || true

BURRITO_BIN="$PROJECT_ROOT/burrito_out/pharos_linux_x64"
if [ ! -x "$BURRITO_BIN" ]; then
  echo "FAIL: burrito binary not found at $BURRITO_BIN" >&2
  exit 1
fi

echo "[5/6] Setting PHAROS_TEST_BIN=$BURRITO_BIN"
export PHAROS_TEST_BIN="$BURRITO_BIN"

echo
echo "[6/6] Running harnesses against burrito..."
echo

PYTHON="${PYTHON:-python3}"
FAILED=0

run() {
  local name="$1"; shift
  echo "--- $name ---"
  if "$PYTHON" "$@"; then
    echo "OK  $name"
  else
    echo "FAIL  $name"
    FAILED=$((FAILED + 1))
  fi
  echo
}

run "test-debug.py"               bin/test-debug.py
run "test-debug-http.py"          bin/test-debug-http.py
run "test-raw.py"                 bin/test-raw.py
run "test-raw-http.py"            bin/test-raw-http.py
run "test-edges.py"               bin/test-edges.py
run "test-missing-binary.py"      bin/test-missing-binary.py
run "test-config-override.py"     bin/test-config-override.py
run "test-subserver-override.py"  bin/test-subserver-override.py
run "test-init-options-override.py"     bin/test-init-options-override.py
run "test-workspace-config-override.py" bin/test-workspace-config-override.py
run "test-suite.py rust go python clojure" bin/test-suite.py rust go python clojure
run "test-suite-http.py rust go python clojure" bin/test-suite-http.py rust go python clojure
run "test-both-transports.py"     bin/test-both-transports.py

echo
echo "=== Phase 8 dogfood complete: $FAILED suite(s) failed ==="
exit $FAILED
