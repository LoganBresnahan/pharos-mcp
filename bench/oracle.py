"""Oracle — generate a benchmark question bank from a real codebase.

No LLM. Deterministic. Speaks MCP/stdio to a `pharos-dev` instance
pointed at the target workspace, samples symbols via
`get_symbols_overview` + `workspace_symbols`, and emits one JSONL row
per question with ground-truth pulled directly from the underlying
LSP.

Ground-truth shape:

    {"id": "q0001",
     "kind": "references_count",
     "symbol": "list.map",
     "anchor": {"uri": "file:///.../list.gleam",
                "line": 51, "character": 6},
     "q":    "Within the gleam-stdlib workspace, how many references
              does the symbol `list.map` have? (LSP find_references
              total, counting all locations including the declaration.)",
     "ground_truth": 142}

    {"id": "q0002",
     "kind": "definition_uri",
     "symbol": "PoolDiag",
     "anchor": {...some call-site...},
     "q":    "Within the gleam-stdlib workspace, what file defines
              the symbol `PoolDiag`? Return the absolute path.",
     "ground_truth": "/.../list.gleam"}

Usage:
    python3 bench/oracle.py \
        --workspace tmp/fixtures/gleam \
        --out bench/data/gleam.jsonl \
        --n 30 \
        --seed 1
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
from typing import Any, Iterator

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHAROS_BIN = os.path.join(PROJECT_ROOT, "bin", "pharos-dev")


# ---------------------------------------------------------------------------
# Minimal MCP/stdio client
# ---------------------------------------------------------------------------


class McpStdio:
    """One JSON-RPC-over-NDJSON pharos session. Synchronous send/recv
    keyed by request id. Pharos's stdio framing is line-delimited JSON,
    so no Content-Length parsing — one JSON object per line."""

    def __init__(self, workspace: str) -> None:
        env = os.environ.copy()
        # Quiet pharos's own logs so they don't interleave with NDJSON.
        env["PHAROS_LOG_LEVEL"] = "error"
        env["PHAROS_HTTP_ENABLED"] = "false"
        self.proc = subprocess.Popen(
            [PHAROS_BIN],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=workspace,
            env=env,
            text=True,
            bufsize=1,
        )
        self.next_id = 1

    def _send(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        rid = self.next_id
        self.next_id += 1
        req = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        # Drain lines until the matching response shows up. Notifications
        # (no `id`) are discarded.
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("pharos closed stdout unexpectedly")
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == rid:
                return obj

    def initialize(self) -> None:
        resp = self._send("initialize", {
            "protocolVersion": "2024-11-05",
            "clientInfo": {"name": "pharos-oracle", "version": "0"},
            "capabilities": {},
        })
        if "error" in resp:
            raise RuntimeError(f"initialize failed: {resp['error']}")

    def call_tool(self, name: str, args: dict[str, Any]) -> Any:
        resp = self._send("tools/call", {"name": name, "arguments": args})
        if "error" in resp:
            raise RuntimeError(f"tools/call {name} error: {resp['error']}")
        result = resp.get("result", {})
        if result.get("isError"):
            text = "".join(
                c.get("text", "")
                for c in result.get("content", [])
                if c.get("type") == "text"
            )
            raise RuntimeError(f"tool {name} returned isError: {text[:200]}")
        # All pharos tool results are a single text block holding JSON.
        text = "".join(
            c.get("text", "")
            for c in result.get("content", [])
            if c.get("type") == "text"
        )
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text

    def close(self) -> None:
        try:
            assert self.proc.stdin is not None
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ---------------------------------------------------------------------------
# Symbol enumeration + sampling
# ---------------------------------------------------------------------------


def walk_files(workspace: str, extensions: tuple[str, ...]) -> Iterator[str]:
    skip = {"build", "_build", "node_modules", ".git", "tmp", "target"}
    for root, dirs, files in os.walk(workspace):
        dirs[:] = [d for d in dirs if d not in skip and not d.startswith(".")]
        for f in files:
            if f.endswith(extensions):
                yield os.path.join(root, f)


def path_to_uri(p: str) -> str:
    return "file://" + os.path.abspath(p)


def uri_to_path(uri: str) -> str:
    if uri.startswith("file://"):
        return uri[len("file://"):]
    return uri


def flatten_document_symbols(nodes: Any, uri: str,
                             acc: list[dict[str, Any]]) -> None:
    """Walk an LSP DocumentSymbol tree, emitting one record per named
    symbol with its `selectionRange.start` as the anchor (which is
    where `find_references` / `goto_definition` expect the cursor)."""
    if not isinstance(nodes, list):
        return
    for n in nodes:
        if not isinstance(n, dict):
            continue
        # DocumentSymbol shape (hierarchical).
        sel = n.get("selectionRange") or n.get("range") or {}
        start = (sel.get("start") if isinstance(sel, dict) else {}) or {}
        name = n.get("name", "")
        if name:
            acc.append({
                "uri": uri,
                "name": name,
                "kind": n.get("kind", 0),
                "line": start.get("line", 0),
                "character": start.get("character", 0),
            })
        flatten_document_symbols(n.get("children", []), uri, acc)


def collect_symbols(mcp: McpStdio, workspace: str,
                    extensions: tuple[str, ...]) -> list[dict[str, Any]]:
    """Walk every source file, ask `document_symbols` for each, build
    one (uri, name, kind, line, character) record per named symbol.

    `document_symbols` returns the raw LSP DocumentSymbol[] tree — we
    flatten it recursively. The anchor is each node's
    `selectionRange.start`, which is where the LSP places the cursor
    for `find_references` / `goto_definition` requests."""
    symbols: list[dict[str, Any]] = []
    files = list(walk_files(workspace, extensions))
    print(f"[oracle] walking {len(files)} files...", file=sys.stderr)
    for i, path in enumerate(files):
        uri = path_to_uri(path)
        try:
            result = mcp.call_tool("document_symbols", {"uri": uri})
        except RuntimeError as e:
            print(f"[oracle] skip {path}: {e}", file=sys.stderr)
            continue
        # document_symbols returns either {"symbols": [...]} (with
        # hierarchical DocumentSymbol nodes underneath) or the raw
        # array — be defensive about both shapes.
        nodes: Any = []
        if isinstance(result, dict):
            nodes = result.get("symbols") or result.get("result") or []
        elif isinstance(result, list):
            nodes = result
        flatten_document_symbols(nodes, uri, symbols)
        if (i + 1) % 25 == 0:
            print(f"[oracle]   ...{i + 1}/{len(files)} files scanned, "
                  f"{len(symbols)} symbols so far", file=sys.stderr)
    print(f"[oracle] {len(symbols)} named symbols collected",
          file=sys.stderr)
    return symbols


# ---------------------------------------------------------------------------
# Question generators
# ---------------------------------------------------------------------------


MIN_REFS_FOR_COUNT_QUESTION = 2


def gen_references_count(mcp: McpStdio, sym: dict[str, Any],
                         workspace_label: str, qid: str
                         ) -> dict[str, Any] | None:
    """How many references does this symbol have, counted by LSP.

    Requires `len(refs) >= MIN_REFS_FOR_COUNT_QUESTION` — a count of 1
    means "declaration only, no callers," which is an uninformative
    question (every test function in the corpus would qualify and the
    benchmark would just be measuring whether the agent can find a
    symbol it was told about)."""
    try:
        refs = mcp.call_tool("find_references", {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        })
    except RuntimeError:
        return None
    if not isinstance(refs, list):
        return None
    if len(refs) < MIN_REFS_FOR_COUNT_QUESTION:
        return None
    return {
        "id": qid,
        "kind": "references_count",
        "symbol": sym["name"],
        "anchor": {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        },
        "q": (
            f"In the {workspace_label} workspace, count the total number "
            f"of references the LSP reports for the symbol `{sym['name']}` "
            f"defined at line {sym['line'] + 1} of "
            f"{os.path.basename(uri_to_path(sym['uri']))}. Include the "
            f"declaration site itself in the count."
        ),
        "ground_truth": len(refs),
    }


def gen_definition_uri(mcp: McpStdio, sym: dict[str, Any],
                       workspace_label: str, qid: str
                       ) -> dict[str, Any] | None:
    """What file defines this symbol? Anchored at a USE site (a
    non-declaration reference), not the declaration.

    Anchoring at the declaration makes the question trivial: the
    anchor file IS the answer. The interesting case is "given a
    call-site, find where the symbol is defined" — that's what
    `goto_definition` actually does in editor workflows.

    Implementation: ask `find_references` for the symbol's reference
    set, drop the location that overlaps the declaration line, pick a
    random remaining location as the anchor, then ask
    `goto_definition` from that anchor. The cross-file case is the
    one that exercises the LSP's index."""
    try:
        refs = mcp.call_tool("find_references", {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        })
    except RuntimeError:
        return None
    if not isinstance(refs, list):
        return None
    decl_uri = sym["uri"]
    decl_line = sym["line"]
    use_sites = []
    for ref in refs:
        if not isinstance(ref, dict):
            continue
        ref_uri = ref.get("uri")
        ref_range = ref.get("range") or {}
        ref_start = ref_range.get("start") or {}
        ref_line = ref_start.get("line")
        ref_char = ref_start.get("character")
        if ref_uri is None or ref_line is None or ref_char is None:
            continue
        # Drop the declaration itself.
        if ref_uri == decl_uri and ref_line == decl_line:
            continue
        use_sites.append({"uri": ref_uri, "line": ref_line, "character": ref_char})
    if not use_sites:
        return None
    use = use_sites[0]  # deterministic — refs already sorted by LSP
    try:
        defn = mcp.call_tool("goto_definition", {
            "uri": use["uri"],
            "line": use["line"],
            "character": use["character"],
        })
    except RuntimeError:
        return None
    if not defn:
        return None
    target_uri = None
    if isinstance(defn, list) and defn:
        target_uri = defn[0].get("uri") or defn[0].get("targetUri")
    elif isinstance(defn, dict):
        target_uri = defn.get("uri") or defn.get("targetUri")
    if not target_uri:
        return None
    return {
        "id": qid,
        "kind": "definition_path",
        "symbol": sym["name"],
        "anchor": {
            "uri": use["uri"],
            "line": use["line"],
            "character": use["character"],
        },
        "q": (
            f"In the {workspace_label} workspace, the symbol "
            f"`{sym['name']}` is used near line {use['line'] + 1} of "
            f"{os.path.basename(uri_to_path(use['uri']))}. What is the "
            f"absolute file path that *defines* `{sym['name']}`? Return "
            f"the path with no scheme prefix."
        ),
        "ground_truth": uri_to_path(target_uri),
    }


GENERATORS = [
    ("references_count", gen_references_count),
    ("definition_path", gen_definition_uri),
]


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True,
                    help="absolute or relative path to a fixture root")
    ap.add_argument("--out", required=True,
                    help="output JSONL path")
    ap.add_argument("--n", type=int, default=30,
                    help="target number of questions (sampling is "
                         "best-effort; some symbols yield no question)")
    ap.add_argument("--seed", type=int, default=1,
                    help="RNG seed for reproducibility")
    ap.add_argument("--label", default=None,
                    help="human label for the workspace, used in question "
                         "wording. Defaults to basename of --workspace.")
    ap.add_argument("--extensions", default=".gleam",
                    help="comma-separated source extensions to walk "
                         "(default `.gleam`)")
    args = ap.parse_args()

    workspace = os.path.abspath(args.workspace)
    if not os.path.isdir(workspace):
        sys.exit(f"workspace not a directory: {workspace}")
    extensions = tuple(e if e.startswith(".") else "." + e
                       for e in args.extensions.split(","))
    label = args.label or os.path.basename(workspace.rstrip("/"))

    print(f"[oracle] workspace={workspace} label={label} "
          f"ext={extensions} n={args.n} seed={args.seed}", file=sys.stderr)

    rng = random.Random(args.seed)
    mcp = McpStdio(workspace)
    try:
        t0 = time.time()
        mcp.initialize()
        print(f"[oracle] initialized in {time.time() - t0:.1f}s",
              file=sys.stderr)

        symbols = collect_symbols(mcp, workspace, extensions)
        if not symbols:
            sys.exit("no symbols collected — is the LSP healthy on this fixture?")

        # Drop test-only symbols and test files. Test functions tend to
        # have a single reference (the declaration itself) and dominate
        # naive random sampling, making the benchmark measure "can the
        # agent find a symbol it was told about" rather than "can the
        # agent navigate a real codebase." Both heuristics are coarse;
        # refine when corpus-specific conventions warrant.
        before = len(symbols)
        symbols = [
            s for s in symbols
            if not s["name"].endswith("_test")
            and not s["name"].startswith("test_")
            and "/test/" not in s["uri"]
            and "/tests/" not in s["uri"]
        ]
        print(f"[oracle] {before} → {len(symbols)} symbols after test-filter",
              file=sys.stderr)

        rng.shuffle(symbols)

        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        emitted = 0
        attempted = 0
        with open(args.out, "w") as fh:
            for sym in symbols:
                if emitted >= args.n:
                    break
                attempted += 1
                # Round-robin across question kinds for diversity.
                kind_name, gen = GENERATORS[attempted % len(GENERATORS)]
                qid = f"q{emitted + 1:04d}"
                row = gen(mcp, sym, label, qid)
                if row is None:
                    continue
                fh.write(json.dumps(row) + "\n")
                fh.flush()
                emitted += 1
                if emitted % 5 == 0:
                    print(f"[oracle] emitted {emitted}/{args.n}...",
                          file=sys.stderr)
        print(f"[oracle] done — {emitted} questions written to {args.out} "
              f"(attempted {attempted})", file=sys.stderr)
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
