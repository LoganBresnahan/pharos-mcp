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
      --bank "$bank" \
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
echo "Phase 4 done. Aggregating..."
python3 - <<'PY'
import json, glob, os, collections
results = collections.defaultdict(lambda: {"pass": 0, "fail": 0, "err": 0})
for path in sorted(glob.glob("bench/results/v1.0-final/stress/*.jsonl")):
    label = os.path.basename(path).removesuffix(".jsonl")
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if r.get("score") == 1:
                results[label]["pass"] += 1
            elif r.get("error"):
                results[label]["err"] += 1
            else:
                results[label]["fail"] += 1
print("\nPhase 4 summary:")
print(f"{'fixture':<15} {'pass':>6} {'fail':>6} {'err':>6} {'total':>6}")
total = {"pass": 0, "fail": 0, "err": 0}
for label, counts in results.items():
    t = sum(counts.values())
    for k in counts: total[k] += counts[k]
    print(f"{label:<15} {counts['pass']:>6} {counts['fail']:>6} {counts['err']:>6} {t:>6}")
t = sum(total.values())
print(f"{'TOTAL':<15} {total['pass']:>6} {total['fail']:>6} {total['err']:>6} {t:>6}")
PY
