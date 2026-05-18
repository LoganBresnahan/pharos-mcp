"""Score harness output against oracle ground truth.

Reads the JSONL produced by `bench/harness.py` and emits per-arm
summary stats: accuracy, average tool-call count, average tokens,
average wall time, total cost. When `--per-question` is set, also
emits a CSV with one row per (qid, arm) for further drilling.

Usage:
    python3 bench/score.py --results bench/results/smoke.jsonl
    python3 bench/score.py --results bench/results/full.jsonl \\
        --per-question bench/results/full-per-question.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from typing import Any


INT_RE = re.compile(r"-?\d+")


def normalize_path(p: str) -> str:
    """Path comparison strips trailing slashes and resolves `..` /
    symlinks (the LSP often returns canonical paths)."""
    return os.path.normpath(p.strip())


def extract_int(text: str) -> int | None:
    """Some agents return `"7 references"` instead of `"7"`; grab the
    first integer in the answer."""
    m = INT_RE.search(text)
    if m is None:
        return None
    try:
        return int(m.group(0))
    except ValueError:
        return None


def score_one(row: dict[str, Any]) -> bool:
    """True iff the agent's raw answer matches ground truth."""
    if row.get("error"):
        return False
    answer = row.get("answer_raw")
    if answer is None:
        return False
    truth = row.get("ground_truth")
    kind = row.get("kind", "")
    if kind == "references_count":
        a = extract_int(answer)
        return a is not None and a == int(truth)
    if kind == "definition_path":
        return normalize_path(answer) == normalize_path(str(truth))
    # Unknown kind: exact string match fallback.
    return str(answer).strip() == str(truth).strip()


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    by_arm: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in rows:
        by_arm[r["arm"]].append(r)
    out: dict[str, Any] = {}
    for arm, rs in by_arm.items():
        correct = sum(1 for r in rs if score_one(r))
        n = len(rs)
        errors = sum(1 for r in rs if r.get("error"))
        missing_tag = sum(1 for r in rs if r.get("answer_missing_tag"))
        tool_counts = [r.get("tool_call_count", 0) for r in rs]
        turns = [r.get("turns", 0) for r in rs]
        wall = [r.get("wall_time_s", 0.0) for r in rs]
        cost = [r.get("cost_usd", 0.0) for r in rs]
        tokens_in = [r.get("tokens_in", 0) for r in rs]
        tokens_out = [r.get("tokens_out", 0) for r in rs]
        out[arm] = {
            "n": n,
            "correct": correct,
            "accuracy": correct / n if n else 0.0,
            "errors": errors,
            "missing_tag": missing_tag,
            "avg_tool_calls": round(statistics.mean(tool_counts), 2) if tool_counts else 0,
            "avg_turns": round(statistics.mean(turns), 2) if turns else 0,
            "avg_wall_s": round(statistics.mean(wall), 2) if wall else 0,
            "avg_tokens_in": round(statistics.mean(tokens_in), 0) if tokens_in else 0,
            "avg_tokens_out": round(statistics.mean(tokens_out), 0) if tokens_out else 0,
            "total_cost_usd": round(sum(cost), 4),
        }
    return out


def summarize_by_kind(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    kinds = sorted(set(r.get("kind", "") for r in rows))
    for k in kinds:
        rs_k = [r for r in rows if r.get("kind", "") == k]
        out[k] = summarize(rs_k)
    return out


def print_arm_table(title: str, arms: dict[str, Any]) -> None:
    print(f"\n## {title}")
    if not arms:
        print("  (no rows)")
        return
    headers = ["arm", "n", "correct", "acc", "tool", "turns",
               "wall_s", "tok_in", "tok_out", "cost_$"]
    print("  | " + " | ".join(f"{h:>10}" for h in headers) + " |")
    print("  |" + "|".join("-" * 12 for _ in headers) + "|")
    for arm in sorted(arms):
        s = arms[arm]
        row = [
            arm,
            s["n"],
            s["correct"],
            f"{s['accuracy']:.0%}",
            s["avg_tool_calls"],
            s["avg_turns"],
            s["avg_wall_s"],
            s["avg_tokens_in"],
            s["avg_tokens_out"],
            f"{s['total_cost_usd']:.4f}",
        ]
        print("  | " + " | ".join(f"{str(x):>10}" for x in row) + " |")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True, help="harness JSONL")
    ap.add_argument("--per-question", default=None,
                    help="optional CSV path for per-(qid, arm) drill-down")
    args = ap.parse_args()

    rows: list[dict[str, Any]] = []
    with open(args.results) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))

    print(f"# Benchmark results — {args.results}")
    print(f"\n{len(rows)} runs total")
    arms = summarize(rows)
    print_arm_table("Overall", arms)

    by_kind = summarize_by_kind(rows)
    for k, sub in by_kind.items():
        print_arm_table(f"Kind = {k}", sub)

    if "control" in arms and "treatment" in arms:
        c, t = arms["control"], arms["treatment"]
        delta_acc = (t["accuracy"] - c["accuracy"]) * 100
        delta_tools = t["avg_tool_calls"] - c["avg_tool_calls"]
        delta_turns = t["avg_turns"] - c["avg_turns"]
        delta_wall = t["avg_wall_s"] - c["avg_wall_s"]
        delta_cost = t["total_cost_usd"] - c["total_cost_usd"]
        print("\n## Treatment − Control")
        print(f"  accuracy:    {delta_acc:+.1f} pp")
        print(f"  tool calls:  {delta_tools:+.2f} per Q")
        print(f"  turns:       {delta_turns:+.2f} per Q")
        print(f"  wall time:   {delta_wall:+.2f} s per Q")
        print(f"  total cost:  ${delta_cost:+.4f}")

    if args.per_question:
        os.makedirs(os.path.dirname(args.per_question) or ".", exist_ok=True)
        # Build (qid, arm) → row map; one row per pair.
        with open(args.per_question, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["qid", "kind", "arm", "trial", "correct",
                        "answer_raw", "ground_truth", "tool_calls",
                        "turns", "wall_s", "tokens_in", "tokens_out",
                        "cost_usd", "error"])
            for r in rows:
                w.writerow([
                    r.get("qid"), r.get("kind"), r.get("arm"),
                    r.get("trial"),
                    "1" if score_one(r) else "0",
                    r.get("answer_raw"), r.get("ground_truth"),
                    r.get("tool_call_count", 0),
                    r.get("turns", 0),
                    r.get("wall_time_s", 0.0),
                    r.get("tokens_in", 0),
                    r.get("tokens_out", 0),
                    r.get("cost_usd", 0.0),
                    r.get("error") or "",
                ])
        print(f"\nper-question CSV → {args.per_question}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
