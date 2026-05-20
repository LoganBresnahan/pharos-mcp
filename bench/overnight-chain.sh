#!/usr/bin/env bash
# Overnight chain: wait for Rust oracle to finish, then Rust bench,
# then Phase 5 variance trials=3 on the Go bank. All sequential;
# every step writes to its own log so a morning review can read
# them in order without untangling interleaved output.
#
# Why Go for Phase 5 instead of Rust: Phase 5's job is variance
# bounds on a known-passing corpus. Go cleared the gate at +17.1pp
# and exercises 7 of 7 kinds. Rust will land its single-trial
# baseline tonight; variance trials on Rust wait for human design
# review of the result.
set -e

ROOT="/home/oof/pharos-mcp"
cd "$ROOT"

LOG_DIR="bench/results"
mkdir -p "$LOG_DIR"

echo "[chain] $(date -Iseconds) starting" | tee "$LOG_DIR/overnight-chain.log"

# Stage 1: wait for Rust oracle to finish populating the bank.
echo "[chain] $(date -Iseconds) waiting for bench/data/rust-phase3.jsonl..." \
  | tee -a "$LOG_DIR/overnight-chain.log"
while true; do
  if [ -f bench/data/rust-phase3.jsonl ]; then
    LINES=$(wc -l < bench/data/rust-phase3.jsonl)
    if [ "$LINES" -ge 70 ]; then
      echo "[chain] $(date -Iseconds) Rust bank ready ($LINES lines)" \
        | tee -a "$LOG_DIR/overnight-chain.log"
      break
    fi
  fi
  sleep 60
done

# Stage 2: Rust bench (single trial, control + treatment, 7 kinds).
echo "[chain] $(date -Iseconds) Stage 2: Rust bench starting" \
  | tee -a "$LOG_DIR/overnight-chain.log"
python3 bench/harness_deepseek.py \
  --questions bench/data/rust-phase3.jsonl \
  --workspace tmp/fixtures/rust \
  --out bench/results/rust-phase3.jsonl \
  --variant pro-thinking \
  --arms control,treatment \
  > "$LOG_DIR/rust-phase3.harness.log" 2>&1

echo "[chain] $(date -Iseconds) Rust bench complete" \
  | tee -a "$LOG_DIR/overnight-chain.log"

# Stage 3: Score Rust.
python3 bench/score.py --results bench/results/rust-phase3.jsonl \
  > "$LOG_DIR/rust-phase3.score.txt" 2>&1

# Stage 4: Phase 5 variance on the Go bank.
# Same bank as Phase 3 Go run; --trials 3 fires every question
# three times per arm so per-cell variance can be bounded.
echo "[chain] $(date -Iseconds) Stage 4: Phase 5 Go variance (trials=3) starting" \
  | tee -a "$LOG_DIR/overnight-chain.log"
python3 bench/harness_deepseek.py \
  --questions bench/data/go-phase3.jsonl \
  --workspace tmp/fixtures/go \
  --out bench/results/go-variance.jsonl \
  --variant pro-thinking \
  --arms control,treatment \
  --trials 3 \
  > "$LOG_DIR/go-variance.harness.log" 2>&1

echo "[chain] $(date -Iseconds) Phase 5 Go variance complete" \
  | tee -a "$LOG_DIR/overnight-chain.log"

# Stage 5: Score variance.
python3 bench/score.py --results bench/results/go-variance.jsonl \
  > "$LOG_DIR/go-variance.score.txt" 2>&1

echo "[chain] $(date -Iseconds) all stages complete" \
  | tee -a "$LOG_DIR/overnight-chain.log"
