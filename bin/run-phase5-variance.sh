#!/usr/bin/env bash
# Phase 5 variance — fires the DeepSeek harness 5 ways in parallel,
# one pharos instance per language. Each lang gets its own bench
# bank, its own corpus workspace, its own results JSONL.
#
# Total ~1900 cells (5 langs × ~65 Q × 2 arms × 3 trials), ~9 hr
# wall in the parallel layout, ~$10 cost.
#
# Per-lang isolation rationale:
#
#  * Each pharos = its own BEAM VM + own LSP children. No shared
#    state inside pharos between langs.
#  * Each lang's workspace lives in a distinct corpus dir, so file
#    walks / find_symbol globs never cross lang boundaries.
#  * Each pharos extracts the same Burrito payload into the same
#    user-cache dir (`~/.local/share/.burrito/pharos_erts-...`) —
#    handled by pre-extracting once below so the 5 spawns don't race
#    on the metadata file.
#  * Each harness invocation pre-warms its LSP on its own clock.
#
# Outputs land under `bench/results/v1.0-final/phase5/<lang>.jsonl`
# alongside per-lang `<lang>.log`. Scoring runs at the end.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

OUT_DIR="${OUT_DIR:-bench/results/v1.0-final/phase5}"
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
TRIALS="${TRIALS:-3}"

# Pre-extract the Burrito payload once so the 5 lang spawns below
# don't race on writing `_metadata.json` into the user-cache dir.
# A single "tools/list" round-trip is enough.
echo "[phase5] pre-extracting Burrito payload..."
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"warmup","version":"0"}}}' \
  | timeout 30 "$BIN" >/dev/null 2>&1 || true
echo "[phase5] Burrito payload extracted"

# Per-lang: workspace path, bank path, label.
LANGS=(
  "python|tmp/fixtures/python|bench/data/py-phase3.jsonl"
  "rust|tmp/fixtures-bench/rust|bench/data/rust-bytes-phase3.jsonl"
  "typescript|tmp/fixtures-bench/typescript|bench/data/zod-phase2.jsonl"
  "go|tmp/fixtures/go|bench/data/go-phase3.jsonl"
  "java|tmp/fixtures/java-petclinic|bench/data/java-petclinic-phase3.jsonl"
)

PIDS=()

for spec in "${LANGS[@]}"; do
  IFS='|' read -r label workspace bank <<<"$spec"
  if [ ! -d "$workspace" ]; then
    echo "FATAL: workspace missing for $label: $workspace" >&2
    exit 1
  fi
  if [ ! -f "$bank" ]; then
    echo "FATAL: bank missing for $label: $bank" >&2
    exit 1
  fi

  echo "[phase5] starting $label (workspace=$workspace bank=$bank)"

  (
    PHAROS_TEST_BIN="$BIN" \
      python3 bench/harness_deepseek.py \
        --workspace "$workspace" \
        --questions "$bank" \
        --arms control,treatment \
        --variant "$VARIANT" \
        --trials "$TRIALS" \
        --out "$OUT_DIR/$label.jsonl" \
        >"$OUT_DIR/$label.log" 2>&1
    echo "[phase5] $label DONE — exit $?"
  ) &
  PIDS+=("$!")
done

echo "[phase5] all 5 langs running in parallel; pids: ${PIDS[*]}"
echo "[phase5] waiting..."
wait "${PIDS[@]}" || true
echo ""
echo "[phase5] all langs finished. Scoring..."

for spec in "${LANGS[@]}"; do
  IFS='|' read -r label _ _ <<<"$spec"
  echo "================ $label ================"
  python3 bench/score.py --results "$OUT_DIR/$label.jsonl" 2>&1 \
    | sed -n '/^## Overall/,/^## Kind/p' \
    | head -6
  echo ""
done
