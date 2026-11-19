#!/usr/bin/env python3
"""#6 dogfood: the captAInHook payload (integrations/captainhook/pharos-hook.sh)
driving this checkout's release `pharos diagnostics` against a real
typescript-language-server, through one agent turn and the next.

    mix release.dev
    python3 -I bin/dogfood-pharos-hook.py <new-scratch-dir>

It writes a small TypeScript project under <scratch-dir> (tsconfig includes
src/ only, so scratch/x.ts sits in an inferred project: out of scope), warms
pharos, then feeds the payload captAInHook event envelopes and prints each
answer and its time. It runs pharos with a private PHAROS_RUNTIME_DIR (short,
under /tmp) and XDG_STATE_HOME, and stops only that daemon. Exit 0 when every
step answers as the contract (geex's doc/stack-trial-hooks.md) says.
"""
import json, os, shutil, subprocess, sys, tempfile, time
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIM = REPO + "/_build/prod/rel/pharos/bin/pharos"
HOOK = REPO + "/integrations/captainhook/pharos-hook.sh"
work = sys.argv[1]; shutil.rmtree(work, ignore_errors=True)
proj = os.path.join(work, "proj"); os.makedirs(proj + "/src"); os.makedirs(proj + "/scratch")
rt = tempfile.mkdtemp(prefix="rt", dir="/tmp")
json.dump({"compilerOptions": {"strict": True, "noEmit": True, "target": "es2020", "module": "commonjs"}, "include": ["src"]}, open(proj + "/tsconfig.json", "w"))
open(proj + "/package.json", "w").write('{"name":"x","version":"0.0.0","private":true}\n')
open(proj + "/src/a.ts", "w").write("export const a: number = 1;\n")
open(proj + "/src/b.ts", "w").write("export const b: number = 2;\n")
open(proj + "/scratch/x.ts", "w").write("export const x = 1;\n")
env = {k: v for k, v in os.environ.items() if not k.startswith("PHAROS_")}
env.update({"PHAROS_RUNTIME_DIR": rt, "XDG_STATE_HOME": work + "/state", "PHAROS_HOOK_STATE": work + "/hookstate", "PHAROS_DAEMON_SYSTEMD": "0"})
t0 = time.time()
w = subprocess.run([SHIM, "diagnostics", "--json", "src/b.ts"], cwd=proj, env=env, capture_output=True, text=True, timeout=180)
print("warm start %.1fs exit=%d %s" % (time.time() - t0, w.returncode, w.stdout.strip()[:300]))
n = [0]
def ev(etype, tool=None, f=None, **p):
    n[0] += 1
    if tool:
        p["tool_name"] = tool; p.setdefault("tool_input", {})
        if f: p["tool_input"]["file_path"] = os.path.join(proj, f)
    e = {"dispatchId": "d%d" % n[0], "event": {"type": etype, "sessionId": "e2e", "cwd": proj, "payload": p}}
    t = time.time()
    r = subprocess.run(["sh", HOOK, "--root", proj, "--pharos", SHIM, "--budget-ms", "20000"], input=json.dumps(e) + "\n", capture_output=True, text=True, env=env, timeout=60)
    a = json.loads(r.stdout.strip())
    err = [l for l in r.stderr.splitlines() if "trial.unsure" in l]
    print("  %-17s %-5s %-12s %.2fs %s %s" % (etype, tool or "", f or "", time.time() - t, json.dumps({k: v for k, v in a.items() if k != "dispatchId"})[:260], err))
    return a
def edit(f, text, tool="Edit"):
    ev("PreToolUse", tool, f); open(os.path.join(proj, f), "w").write(text); return ev("PostToolUse", tool, f)
ev("UserPromptSubmit")
a1 = edit("src/a.ts", "export const a: number = 'one';\n")
a2 = edit("src/a.ts", "export const a: number = 'one';\nexport const c: string = missing;\n")
a3 = edit("scratch/x.ts", "export const x: number = 'nope';\n")
a4 = ev("Stop")
a5 = ev("Stop", stop_hook_active=True)
ev("UserPromptSubmit")
a6 = edit("src/a.ts", "export const a: number = 1;\n")
a7 = ev("Stop")
ok = (a1.get("effect") == "inject" and "src/a.ts:1:14 TS2322" in a1.get("text", "")
      and a2.get("effect") == "inject" and "TS2304" in a2.get("text", "") and "TS2322" not in a2.get("text", "")
      and a3.get("effect") == "noop" and a4.get("effect") == "decide" and a5.get("effect") == "noop"
      and a6.get("effect") == "noop" and a7.get("effect") == "noop")
print("E2E", "PASS" if ok else "FAIL")
subprocess.run([SHIM, "daemon", "stop"], env=env, capture_output=True, timeout=30)
shutil.rmtree(rt, ignore_errors=True)
sys.exit(0 if ok else 1)
