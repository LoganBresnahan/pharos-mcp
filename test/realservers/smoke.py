#!/usr/bin/env python3
"""pharos against real language servers, one small project per language.

    python3 -I test/realservers/smoke.py --release _build/prod/rel/pharos \\
        --shim _build/prod/rel/pharos/bin/pharos [--only ts,go,py,rs]

For each language a fixture project holds a helper in one file and, in the
file that uses it, a planted type error. Through a private daemon (its
own runtime, state and HOME-independent dirs) it checks:

- get_diagnostics, cold: the planted error, within the budget;
- `pharos diagnostics` (the CLI) reports it too;
- hover on the helper's use answers, and goto_definition lands in the
  helper's file;
- find_symbol on a cold session finds the helper (#21);
- after the error is fixed on disk, get_diagnostics comes back without it
  (ADR-038's re-sync).

Needs the servers on PATH: typescript-language-server (with typescript),
gopls, pyright-langserver, rust-analyzer (and cargo). A missing server is
reported and fails that language, unless --skip-missing.
"""
import argparse
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time

LANGS = {
    "ts": {
        "server": "typescript-language-server",
        "files": {
            "tsconfig.json": '{"compilerOptions": {"strict": true, "noEmit": true}, "include": ["*.ts"]}\n',
            "package.json": '{"name": "rs-ts", "private": true}\n',
            "util.ts": "export function helper(): number {\n  return 1;\n}\n",
            "main.ts": 'import { helper } from "./util";\nconst n: number = "s";\nexport const v = helper() + n;\n',
        },
        "main": "main.ts", "util": "util.ts",
        "fixed": 'import { helper } from "./util";\nconst n: number = 1;\nexport const v = helper() + n;\n',
        "expect": "not assignable",
    },
    "go": {
        "server": "gopls",
        "files": {
            "go.mod": "module example.com/rsgo\n\ngo 1.21\n",
            "util.go": "package main\n\nfunc helper() int {\n\treturn 1\n}\n",
            "main.go": 'package main\n\nfunc main() {\n\tvar x int = "s"\n\t_ = x + helper()\n}\n',
        },
        "main": "main.go", "util": "util.go",
        "fixed": "package main\n\nfunc main() {\n\tvar x int = 1\n\t_ = x + helper()\n}\n",
        "expect": "cannot use",
    },
    "py": {
        "server": "pyright-langserver",
        "files": {
            "pyproject.toml": '[project]\nname = "rspy"\nversion = "0"\n',
            "util.py": "def helper() -> int:\n    return 1\n",
            "main.py": 'from util import helper\n\nx: int = "s"\nprint(x + helper())\n',
        },
        "main": "main.py", "util": "util.py",
        "fixed": "from util import helper\n\nx: int = 1\nprint(x + helper())\n",
        "expect": "not assignable",
    },
    "rs": {
        "server": "rust-analyzer",
        "files": {
            "Cargo.toml": '[package]\nname = "rsrs"\nversion = "0.1.0"\nedition = "2021"\n',
            "src/util.rs": "pub fn helper() -> i32 {\n    1\n}\n",
            "src/main.rs": 'mod util;\nuse util::helper;\n\nfn main() {\n    let x: i32 = "s";\n    println!("{}", x + helper());\n}\n',
        },
        "main": "src/main.rs", "util": "src/util.rs",
        "fixed": 'mod util;\nuse util::helper;\n\nfn main() {\n    let x: i32 = 1;\n    println!("{}", x + helper());\n}\n',
        "expect": "mismatched types",
    },
}


class Session:
    def __init__(self, shim, env, cwd):
        self.p = subprocess.Popen([shim], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=env, cwd=cwd)
        self.buf = b""
        self.next_id = 0

    def call(self, method, params, timeout):
        self.next_id += 1
        i = self.next_id
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode())
        self.p.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if line.strip():
                    msg = json.loads(line)
                    if msg.get("id") == i:
                        return msg
            r, _, _ = select.select([self.p.stdout], [], [], 1)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("pharos closed stdout")
                self.buf += chunk
        raise RuntimeError("no reply to %s within %ds" % (method, timeout))

    def tool(self, name, args, timeout=120):
        r = self.call("tools/call", {"name": name, "arguments": args}, timeout)
        res = r.get("result") or {}
        text = "".join(c.get("text", "") for c in res.get("content", []))
        return text, bool(res.get("isError"))

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=20)
        except Exception:  # noqa: BLE001
            self.p.kill()


def position(text, needle, occurrence=1):
    idx = -1
    for _ in range(occurrence):
        idx = text.index(needle, idx + 1)
    line = text.count("\n", 0, idx)
    char = idx - (text.rfind("\n", 0, idx) + 1)
    return line, char


def check_lang(key, args, results):
    spec = LANGS[key]
    if shutil.which(spec["server"]) is None:
        results.append((key, "server", not args.skip_missing, "%s not on PATH" % spec["server"]))
        return
    root = tempfile.mkdtemp(prefix="rs-%s-" % key, dir="/tmp")
    proj = os.path.join(root, "proj")
    for rel, text in spec["files"].items():
        path = os.path.join(proj, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
    rt = os.path.join(root, "rt")
    os.makedirs(rt, mode=0o700)
    env = dict(os.environ, PHAROS_MODE="daemon", PHAROS_RUNTIME_DIR=rt, XDG_RUNTIME_DIR=rt,
               XDG_STATE_HOME=os.path.join(root, "state"), PHAROS_RELEASE_ROOT=args.release)
    main_path = os.path.join(proj, spec["main"])
    util_path = os.path.join(proj, spec["util"])
    main_uri, util_uri = "file://" + main_path, "file://" + util_path
    main_text = spec["files"][spec["main"]]

    def record(check, ok, detail):
        results.append((key, check, ok, detail))
        print("%s %-3s %-18s %s" % ("ok  " if ok else "FAIL", key, check, detail), flush=True)

    s = Session(args.shim, env, proj)
    try:
        s.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "realservers", "version": "0"}}, 60)
        s.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        s.p.stdin.flush()
        # find_symbol first, on the cold session (#21).
        t0 = time.time()
        text, err = s.tool("find_symbol", {"name_path": "helper", "scope_uri": util_uri})
        record("find_symbol cold", not err and '"name":"helper"' in text, "%.1fs %s" % (time.time() - t0, text[:100]))
        t0 = time.time()
        text, err = s.tool("get_diagnostics", {"uri": main_uri, "timeout_ms": args.budget_ms})
        took = time.time() - t0
        record("diagnostics cold", not err and spec["expect"] in text and took * 1000 < args.budget_ms,
               "%.1fs %s" % (took, text[:140].replace("\n", " ")))
        line, char = position(main_text, "helper", main_text.count("helper"))
        text, err = s.tool("hover", {"uri": main_uri, "line": line, "character": char + 1})
        record("hover", not err and len(text) > 10 and "null" != text.strip(), text[:100].replace("\n", " "))
        text, err = s.tool("goto_definition", {"uri": main_uri, "line": line, "character": char + 1})
        record("definition", not err and os.path.basename(spec["util"]) in text, text[:120])
        with open(main_path, "w") as f:
            f.write(spec["fixed"])
        t0 = time.time()
        text, err = s.tool("get_diagnostics", {"uri": main_uri, "timeout_ms": args.budget_ms})
        record("diagnostics fixed", not err and spec["expect"] not in text,
               "%.1fs %s" % (time.time() - t0, text[:140].replace("\n", " ")))
        if args.verbose:
            print("   full answer after the fix: " + text[-400:].replace("\n", " "), flush=True)
        with open(main_path, "w") as f:
            f.write(main_text)
    except Exception as e:  # noqa: BLE001
        record("session", False, repr(e))
    finally:
        s.close()
    cli = subprocess.run([args.shim, "diagnostics", "--json", "--timeout-ms", str(args.budget_ms), spec["main"]],
                         env=env, cwd=proj, capture_output=True, text=True, timeout=args.budget_ms / 1000 + 60)
    try:
        f = json.loads(cli.stdout)["files"][0]
        found = any(spec["expect"] in d.get("message", "") for d in f["diagnostics"])
        record("cli", cli.returncode == 0 and found, "%s %s" % (f["status"], f.get("reason", "")))
    except Exception:  # noqa: BLE001
        record("cli", False, (cli.stdout or cli.stderr)[-200:])
    subprocess.run([args.shim, "daemon", "stop"], env=env, cwd=proj, capture_output=True, timeout=60)
    shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--release", required=True)
    ap.add_argument("--shim", required=True)
    ap.add_argument("--only", default="ts,go,py,rs")
    ap.add_argument("--budget-ms", type=int, default=60000)
    ap.add_argument("--skip-missing", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    args.release = os.path.abspath(args.release)
    args.shim = os.path.abspath(args.shim)
    results = []
    for key in args.only.split(","):
        check_lang(key, args, results)
    failed = [r for r in results if not r[2]]
    print("%d checks, %d failed" % (len(results), len(failed)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
