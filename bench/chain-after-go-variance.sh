#!/usr/bin/env bash
# Chain: wait for Phase 5 Go variance to finish, score it, then run
# Phase 3 Rust on tokio-rs/bytes (standalone crate cloned into
# tmp/fixtures-bench/rust). Replaces last night's overnight chain
# which hung on the full cargo corpus.
#
# tokio-rs/bytes is small (34 .rs files), self-contained (single
# Cargo.toml, no workspace inheritance), and exposes Buf / BufMut
# traits with multiple implementations — exactly the shape that
# made Go's `implementations` kind hit +80 pp. If pharos's lift
# on Rust impls matches Go's, the static-typed-language story is
# locked across two language families.
set -e

ROOT="/home/oof/pharos-mcp"
cd "$ROOT"

LOG_DIR="bench/results"
mkdir -p "$LOG_DIR"

CHAIN_LOG="$LOG_DIR/chain-after-go-variance.log"
echo "[chain] $(date -Iseconds) starting" | tee "$CHAIN_LOG"

# Stage 1: wait for Phase 5 Go variance to finish.
# 70 questions * 2 arms * 3 trials = 420 cells. Poll the results
# jsonl line count.
echo "[chain] $(date -Iseconds) waiting for go-variance to reach 420 cells..." \
  | tee -a "$CHAIN_LOG"
while true; do
  if [ -f bench/results/go-variance.jsonl ]; then
    LINES=$(wc -l < bench/results/go-variance.jsonl)
    if [ "$LINES" -ge 420 ]; then
      echo "[chain] $(date -Iseconds) Go variance complete ($LINES cells)" \
        | tee -a "$CHAIN_LOG"
      break
    fi
  fi
  sleep 60
done

# Stage 2: score Go variance.
echo "[chain] $(date -Iseconds) Stage 2: scoring Go variance" \
  | tee -a "$CHAIN_LOG"
python3 bench/score.py --results bench/results/go-variance.jsonl \
  > "$LOG_DIR/go-variance.score.txt" 2>&1

# Stage 3: generate Rust bank against tokio-rs/bytes.
echo "[chain] $(date -Iseconds) Stage 3: Rust oracle on bytes" \
  | tee -a "$CHAIN_LOG"
python3 bench/oracle.py \
  --workspace tmp/fixtures-bench/rust \
  --out bench/data/rust-bytes-phase3.jsonl \
  --per-kind 10 \
  --kinds references_count,definition_path,call_hierarchy_in,collision_resolve,containing_symbol,implementations,symbol_kind \
  --extensions .rs \
  --seed 47 \
  --prewarm \
  > "$LOG_DIR/rust-bytes.oracle.log" 2>&1

echo "[chain] $(date -Iseconds) Rust oracle done" | tee -a "$CHAIN_LOG"

# Stage 4: Rust bench.
echo "[chain] $(date -Iseconds) Stage 4: Rust bench" | tee -a "$CHAIN_LOG"
python3 bench/harness_deepseek.py \
  --questions bench/data/rust-bytes-phase3.jsonl \
  --workspace tmp/fixtures-bench/rust \
  --out bench/results/rust-bytes-phase3.jsonl \
  --variant pro-thinking \
  --arms control,treatment \
  > "$LOG_DIR/rust-bytes.harness.log" 2>&1

echo "[chain] $(date -Iseconds) Rust bench complete" | tee -a "$CHAIN_LOG"

# Stage 5: score Rust.
python3 bench/score.py --results bench/results/rust-bytes-phase3.jsonl \
  > "$LOG_DIR/rust-bytes-phase3.score.txt" 2>&1

echo "[chain] $(date -Iseconds) all stages complete" | tee -a "$CHAIN_LOG"
