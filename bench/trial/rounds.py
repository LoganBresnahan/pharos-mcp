#!/usr/bin/env python3
"""The pharos trial's scheduler (#7): rounds of every task under every arm.

    python3 -I bench/trial/rounds.py --out /tmp/trial/results/trial.jsonl --plan-only
    python3 -I bench/trial/rounds.py --out /tmp/trial/results/trial.jsonl --go
    python3 -I bench/trial/rounds.py --out /tmp/trial/results/smoke.jsonl --smoke --limit 3

- Each round runs every (task, arm) once, in a random order seeded per round
  ("<seed>/<round>"). The whole plan is written next to --out
  (<out>.plan.json) before the first run, and every record carries its slot
  ("r<round>/p<position>/a<attempt>").
- Strictly one run at a time: this scheduler holds /tmp/trial/rounds.lock,
  and every run.py holds /tmp/trial/run.lock, so nothing else can start a
  run meanwhile. Before each run it waits for the machine to be quiet
  (1-minute load under --max-load), since other heavy work slows arm 2's
  checks only; the load is recorded in each record.
- Resumable: a slot with a valid record in --out is done. A run recorded
  as invalid (it couldn't be measured fairly) is retried, up to --attempts
  times. Restart the same command after an interruption.
- `touch /tmp/trial/STOP` stops it before the next run (the file is
  removed when the scheduler next starts).
- Real runs spend API credit: they need --go, given only on the
  maintainer's word. --smoke runs everything but the model.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import random
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRIAL = Path("/tmp/trial")
TASK_IDS = ["T1", "T2", "T3", "T4", "T5", "T6"]
ARMS = [1, 2, 3]


def plan(seed: str, rounds: int) -> list[list[dict]]:
    out = []
    for n in range(1, rounds + 1):
        slots = [{"task": t, "arm": a} for t in TASK_IDS for a in ARMS]
        random.Random("%s/%d" % (seed, n)).shuffle(slots)
        out.append([dict(s, round=n, position=i + 1) for i, s in enumerate(slots)])
    return out


def records(out: Path) -> list[dict]:
    if not out.exists():
        return []
    recs = []
    for line in out.read_text().splitlines():
        try:
            recs.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return recs


def wait_quiet(max_load: float, max_wait_s: int) -> float:
    t0 = time.time()
    while True:
        load = float(open("/proc/loadavg").read().split()[0])
        if load < max_load:
            return load
        if time.time() - t0 > max_wait_s:
            raise SystemExit("the machine stayed busy (load %.1f) for %d s; stopping" % (load, max_wait_s))
        print("[rounds] waiting for a quiet machine: load %.1f" % load, file=sys.stderr, flush=True)
        time.sleep(30)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--seed", default="pharos-trial-007")
    ap.add_argument("--effort", default="high")
    ap.add_argument("--attempts", type=int, default=2)
    ap.add_argument("--max-load", type=float, default=2.0)
    ap.add_argument("--max-wait-s", type=int, default=3600)
    ap.add_argument("--limit", type=int, default=0, help="stop after this many runs (0: no limit)")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--go", action="store_true", help="spend API credit (the maintainer's word only)")
    ap.add_argument("--plan-only", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    full = plan(a.seed, a.rounds)
    plan_file = out.with_suffix(out.suffix + ".plan.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    meta = {"seed": a.seed, "rounds": a.rounds, "effort": a.effort, "smoke": a.smoke, "plan": full}
    if plan_file.exists():
        old = json.loads(plan_file.read_text())
        if old["plan"] != full or old.get("smoke") != a.smoke or old.get("effort") != a.effort:
            raise SystemExit("%s holds a different plan, smoke flag or effort; use another --out" % plan_file)
    plan_file.write_text(json.dumps(meta, indent=1))
    if a.plan_only:
        for rnd in full:
            print("round %d: %s" % (rnd[0]["round"], " ".join("%s/%d" % (s["task"], s["arm"]) for s in rnd)))
        return
    if not a.smoke and not a.go:
        raise SystemExit("real runs spend API credit: pass --go (on the maintainer's word), or --smoke")
    if not a.smoke and not os.environ.get("DEEPSEEK_API_KEY"):
        raise SystemExit("DEEPSEEK_API_KEY isn't set")
    TRIAL.joinpath("rounds.lock").touch()
    lock = open(TRIAL / "rounds.lock")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("another scheduler holds /tmp/trial/rounds.lock")
    (TRIAL / "STOP").unlink(missing_ok=True)
    # Every task's start state, prepared once (its scope check included).
    for t in TASK_IDS:
        task = json.loads((HERE / "tasks" / (t + ".json")).read_text())
        if not (TRIAL / "cache" / ("%s-%s.json" % (t, task["start"][:12]))).exists():
            print("[rounds] preparing %s" % t, file=sys.stderr, flush=True)
            subprocess.run([sys.executable, "-I", str(HERE / "run.py"), "--prepare", "--task", t], check=True)
    ran = 0
    for rnd in full:
        for s in rnd:
            # Only records of this kind count: a smoke record never fills a
            # real slot, nor a run at another effort (verifier's re-check).
            recs = [r for r in records(out) if (r.get("slot") or "").startswith("r%d/p%d/" % (s["round"], s["position"]))
                    and bool(r.get("smoke")) == a.smoke and r.get("effort") == a.effort
                    and r.get("task") == s["task"] and r.get("arm") == s["arm"]]
            if any(not r.get("invalid") for r in recs):
                continue
            if len(recs) >= a.attempts:
                print("[rounds] r%d/p%d %s arm %d: %d invalid attempts, skipped" % (
                    s["round"], s["position"], s["task"], s["arm"], len(recs)), file=sys.stderr, flush=True)
                continue
            if (TRIAL / "STOP").exists():
                print("[rounds] STOP file found; stopping", file=sys.stderr)
                return
            if a.limit and ran >= a.limit:
                return
            load = wait_quiet(a.max_load, a.max_wait_s)
            slot = "r%d/p%d/a%d" % (s["round"], s["position"], len(recs) + 1)
            print("[rounds] %s %s arm %d (load %.1f) %s" % (slot, s["task"], s["arm"], load,
                                                            time.strftime("%H:%M:%S", time.gmtime())),
                  file=sys.stderr, flush=True)
            cmd = [sys.executable, "-I", str(HERE / "run.py"), "--task", s["task"], "--arm", str(s["arm"]),
                   "--effort", a.effort, "--out", str(out), "--slot", slot]
            if a.smoke:
                cmd.append("--smoke")
            p = subprocess.run(cmd)
            if p.returncode != 0:
                raise SystemExit("run.py failed (exit %d) at %s; fix and restart to resume" % (p.returncode, slot))
            ran += 1
    print("[rounds] every slot of the plan has a record", file=sys.stderr)


if __name__ == "__main__":
    main()
