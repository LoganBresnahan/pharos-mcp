#!/usr/bin/env bash
# Phase 4 stress runner — fires the DeepSeek harness against each
# adversarial fixture in turn. Treatment-arm only (no control)
# because Phase 4 measures pharos's graceful-degrade, not a vs-baseline
# delta. Total ~29 Q across 3 fixtures = ~30-60 min wall.
#
# Outputs land under `bench/results/v1.0-final/stress/` so they don't
# collide with Phase 5 results.
#
# Prereqs:
#   * fresh burrito binary at `burrito_out/pharos_linux_x64` (Phase 5
#     also requires this, so build once for both)
#   * `DEEPSEEK_API_KEY` exported
#   * `bench/data/stress-{ts-broken,py-binary,polyglot}.jsonl` present
#     (built by `bench/oracle.py` against fixtures under
#     `bench/fixtures/stress/`)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

OUT_DIR="${OUT_DIR:-bench/results/v1.0-final/stress}"
mkdir -p "$OUT_DIR"

BIN="${PHAROS_TEST_BIN:-$REPO/burrito_out/pharos_linux_x64}"
if [ ! -x "$BIN" ]; then
  echo "FATAL: pharos binary not found / not executable at $BIN" >&2
  echo "Build with: MIX_ENV=prod mix release --overwrite" >&2
  exit 1
fi

if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "FATAL: DEEPSEEK_API_KEY not set" >&2
  exit 1
fi

VARIANT="${VARIANT:-pro-thinking}"

run_fixture() {
  local label="$1"
  local workspace="$2"
  local bank="$3"

  echo "=================================================================="
  echo "Phase 4 — fixture: $label"
  echo "  workspace: $workspace"
  echo "  bank:      $bank"
  echo "  out:       $OUT_DIR/$label.jsonl"
  echo "=================================================================="

  PHAROS_TEST_BIN="$BIN" \
    python3 bench/harness_deepseek.py \
      --workspace "$workspace" \
      --questions "$bank" \
      --arms treatment \
      --variant "$VARIANT" \
      --trials 1 \
      --out "$OUT_DIR/$label.jsonl" \
      2>&1 | tee "$OUT_DIR/$label.log"
}

run_fixture "ts-broken"   "bench/fixtures/stress/ts-broken"   "bench/data/stress-ts-broken.jsonl"
run_fixture "py-binary"   "bench/fixtures/stress/py-binary"   "bench/data/stress-py-binary.jsonl"
run_fixture "polyglot"    "bench/fixtures/stress/polyglot"    "bench/data/stress-polyglot.jsonl"

echo ""
echo "Phase 4 done. Per-fixture scoring (via bench/score.py):"
echo ""
for r in "$OUT_DIR"/*.jsonl; do
  label=$(basename "$r" .jsonl)
  echo "================ fixture: $label ================"
  python3 bench/score.py --results "$r" 2>&1 | sed -n '/^## Overall/,/^$/p' | head -5
  echo ""
done
