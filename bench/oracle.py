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
    where `find_references` / `goto_definition` expect the cursor).

    Also captures `range.start` / `range.end` — the full extent of the
    symbol body — used by `containing_symbol` questions."""
    if not isinstance(nodes, list):
        return
    for n in nodes:
        if not isinstance(n, dict):
            continue
        sel = n.get("selectionRange") or n.get("range") or {}
        sel_start = (sel.get("start") if isinstance(sel, dict) else {}) or {}
        rng = n.get("range") or {}
        rng_start = (rng.get("start") if isinstance(rng, dict) else {}) or {}
        rng_end = (rng.get("end") if isinstance(rng, dict) else {}) or {}
        name = n.get("name", "")
        if name:
            acc.append({
                "uri": uri,
                "name": name,
                "kind": n.get("kind", 0),
                "line": sel_start.get("line", 0),
                "character": sel_start.get("character", 0),
                "range_start_line": rng_start.get("line", 0),
                "range_end_line": rng_end.get("line", 0),
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
                         workspace_label: str, qid: str,
                         ctx: dict[str, Any]) -> dict[str, Any] | None:
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
                       workspace_label: str, qid: str,
                       ctx: dict[str, Any]) -> dict[str, Any] | None:
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


# ---------------------------------------------------------------------------
# Phase 2 generators
# ---------------------------------------------------------------------------


# LSP SymbolKind enum → human label. Restricted to kinds where the
# answer is unambiguous to a human reading the source. "Module" and
# "Field" appear in gleam-stdlib but aren't asked because their human
# label varies by lang.
SYMBOL_KIND_LABELS: dict[int, str] = {
    5: "class",
    6: "method",
    8: "field",
    9: "constructor",
    10: "enum",
    11: "interface",
    12: "function",
    13: "variable",
    14: "constant",
    22: "enum member",
    23: "struct",
    26: "type parameter",
}


def precompute_collisions(
    symbols: list[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    """Map name → list of defining symbols, restricted to names defined
    in 2+ distinct files. Drives `gen_collision_resolve`."""
    by_name: dict[str, list[dict[str, Any]]] = {}
    for s in symbols:
        by_name.setdefault(s["name"], []).append(s)
    out: dict[str, list[dict[str, Any]]] = {}
    for name, defs in by_name.items():
        uris = {d["uri"] for d in defs}
        if len(uris) >= 2:
            out[name] = defs
    return out


def precompute_diagnostics(
    mcp: McpStdio, workspace: str, extensions: tuple[str, ...]
) -> list[dict[str, Any]]:
    """For every source file, ask `get_diagnostics` and record the
    count. Drives `gen_diagnostics_count`. Files with zero diagnostics
    are kept too — we filter at question-emit time so the test can
    decide whether to include 0-count Qs.

    Pharos's `get_diagnostics` returns either the raw LSP shape
    `{"uri": ..., "diagnostics": [...]}` or a `Diagnostic[]` array
    directly. Handle both."""
    records: list[dict[str, Any]] = []
    files = list(walk_files(workspace, extensions))
    print(f"[oracle] diagnostics pre-pass: {len(files)} files...",
          file=sys.stderr)
    for path in files:
        uri = path_to_uri(path)
        try:
            result = mcp.call_tool("get_diagnostics", {"uri": uri})
        except RuntimeError:
            continue
        diags: Any = []
        if isinstance(result, dict):
            diags = result.get("diagnostics") or []
        elif isinstance(result, list):
            diags = result
        if isinstance(diags, list):
            records.append({"uri": uri, "count": len(diags)})
    nonzero = sum(1 for r in records if r["count"] > 0)
    print(f"[oracle]   diagnostics: {nonzero}/{len(records)} files with >=1",
          file=sys.stderr)
    return records


def gen_call_hierarchy_in(mcp: McpStdio, sym: dict[str, Any],
                          workspace_label: str, qid: str,
                          ctx: dict[str, Any]) -> dict[str, Any] | None:
    """How many distinct function-callers does this symbol have, via
    the LSP's incoming-calls graph? Filter requires >= 2 callers.

    Two-step protocol: prepare (returns CallHierarchyItem[]) then
    incomingCalls on item[0]. We count distinct `from.uri+name` keys
    across the returned list — multiple call sites from the same caller
    function collapse to one.

    LSP servers (tsserver, observed) emit module-level top-level call
    sites as `from.kind = File/Module` with the file's basename as the
    "name". A reasonable agent (correctly) treats a file as not a
    function. Mirror that by filtering to callers whose kind looks
    like a function-ish entity: Function=12, Method=6, Constructor=9.
    Other kinds (File=1, Module=2, Namespace=3) are dropped so the
    ground truth matches what an agent would naturally count."""
    CALLER_KINDS_FUNCTION_ISH = {6, 9, 12}
    try:
        items = mcp.call_tool("call_hierarchy_prepare", {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        })
    except RuntimeError:
        return None
    if not isinstance(items, list) or not items:
        return None
    item = items[0]
    if not isinstance(item, dict):
        return None
    try:
        calls = mcp.call_tool("call_hierarchy_incoming_calls", {"item": item})
    except RuntimeError:
        return None
    if not isinstance(calls, list):
        return None
    callers: set[str] = set()
    for c in calls:
        if not isinstance(c, dict):
            continue
        frm = c.get("from") or {}
        if not isinstance(frm, dict):
            continue
        if frm.get("kind") not in CALLER_KINDS_FUNCTION_ISH:
            continue
        key = f"{frm.get('uri', '')}:{frm.get('name', '')}"
        callers.add(key)
    if len(callers) < 2:
        return None
    return {
        "id": qid,
        "kind": "call_hierarchy_in",
        "symbol": sym["name"],
        "anchor": {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        },
        "q": (
            f"In the {workspace_label} workspace, how many distinct "
            f"function or method callers does `{sym['name']}` (defined "
            f"at line {sym['line'] + 1} of "
            f"{os.path.basename(uri_to_path(sym['uri']))}) have? Use "
            f"the LSP's incoming-call hierarchy. Count each caller "
            f"function once even if it calls `{sym['name']}` multiple "
            f"times. Exclude file-level / module-level entries that "
            f"are not themselves functions or methods. Exclude "
            f"`{sym['name']}` itself if it is self-recursive."
        ),
        "ground_truth": len(callers),
    }


def gen_collision_resolve(mcp: McpStdio, sym: dict[str, Any],
                          workspace_label: str, qid: str,
                          ctx: dict[str, Any]) -> dict[str, Any] | None:
    """For a symbol whose NAME has multiple definitions across files,
    anchor at a use-site and ask "which file defines THIS one?". Forces
    the agent to disambiguate by scope rather than grep.

    Approach:
      1. Skip if `sym["name"]` isn't in the precomputed collisions map.
      2. Get refs to this specific symbol via find_references.
      3. Drop ref locations that overlap any of the colliding defs.
      4. Pick the first remaining use site.
      5. goto_definition from there → answer file path.
    """
    collisions: dict[str, list[dict[str, Any]]] = ctx.get("collisions", {})
    if sym["name"] not in collisions:
        return None
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
    def_lines = {
        (d["uri"], d["line"]) for d in collisions[sym["name"]]
    }
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
        if (ref_uri, ref_line) in def_lines:
            continue
        use_sites.append({"uri": ref_uri, "line": ref_line, "character": ref_char})
    if not use_sites:
        return None
    use = use_sites[0]
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
        "kind": "collision_resolve",
        "symbol": sym["name"],
        "anchor": {
            "uri": use["uri"],
            "line": use["line"],
            "character": use["character"],
        },
        "q": (
            f"In the {workspace_label} workspace, the name `{sym['name']}` "
            f"is defined in multiple files. At line {use['line'] + 1} of "
            f"{os.path.basename(uri_to_path(use['uri']))}, which `{sym['name']}` "
            f"is being used? Return the absolute path of the file that "
            f"defines the specific `{sym['name']}` referenced at that site."
        ),
        "ground_truth": uri_to_path(target_uri),
    }


def gen_diagnostics_count(mcp: McpStdio, sym: dict[str, Any],
                          workspace_label: str, qid: str,
                          ctx: dict[str, Any]) -> dict[str, Any] | None:
    """How many diagnostics in file Z, per the LSP's published-diagnostics
    set. Sampling burns one slot per call regardless of whether a file
    is available — we pop a non-zero-count file from the precomputed
    pool each call. Returns None once the pool empties."""
    pool: list[dict[str, Any]] = ctx.setdefault("_diag_pool", [])
    if not pool:
        all_recs = ctx.get("diagnostics", [])
        pool.extend(r for r in all_recs if r["count"] > 0)
        if not pool:
            return None
    rec = pool.pop(0)
    file_uri = rec["uri"]
    count = rec["count"]
    return {
        "id": qid,
        "kind": "diagnostics_count",
        "symbol": os.path.basename(uri_to_path(file_uri)),
        "anchor": {"uri": file_uri, "line": 0, "character": 0},
        "q": (
            f"In the {workspace_label} workspace, how many diagnostics "
            f"does the LSP report for file "
            f"{os.path.basename(uri_to_path(file_uri))}? Count every "
            f"published diagnostic regardless of severity."
        ),
        "ground_truth": count,
    }


def gen_containing_symbol(mcp: McpStdio, sym: dict[str, Any],
                          workspace_label: str, qid: str,
                          ctx: dict[str, Any]) -> dict[str, Any] | None:
    """Pick a line inside the symbol's body (not the declaration line)
    and ask which named symbol contains it.

    The ground truth is `sym["name"]` itself — we sampled the symbol,
    so we know it's the innermost named container for any line inside
    its range. To avoid ambiguity from nested symbols, we pick a line
    just past the declaration where nested children are unlikely to
    have begun yet."""
    rs = sym["range_start_line"]
    re_ = sym["range_end_line"]
    if re_ <= rs + 1:
        return None
    # Pick line right after the declaration (0-indexed body line 1).
    probe_line = rs + 1
    # Reject if any other symbol in the same file has its range start
    # at or before probe_line and range end at or after probe_line, AND
    # is strictly inside this symbol's range — that would be a nested
    # symbol that's the real innermost container.
    file_symbols: list[dict[str, Any]] = ctx.get("file_symbols", {}).get(
        sym["uri"], []
    )
    for other in file_symbols:
        if other is sym:
            continue
        if other["range_start_line"] <= probe_line <= other["range_end_line"]:
            # Inner candidate exists — bail to keep ground truth clean.
            if (other["range_start_line"] >= rs
                    and other["range_end_line"] <= re_):
                return None
    return {
        "id": qid,
        "kind": "containing_symbol",
        "symbol": sym["name"],
        "anchor": {"uri": sym["uri"], "line": probe_line, "character": 0},
        "q": (
            f"In the {workspace_label} workspace, which named symbol "
            f"contains line {probe_line + 1} of "
            f"{os.path.basename(uri_to_path(sym['uri']))}? Return only "
            f"the symbol's name."
        ),
        "ground_truth": sym["name"],
    }


def gen_implementations(mcp: McpStdio, sym: dict[str, Any],
                        workspace_label: str, qid: str,
                        ctx: dict[str, Any]) -> dict[str, Any] | None:
    """How many implementations does this trait/interface/abstract method
    have? Filter requires >= 2 impls — single-impl is uninformative.

    Sparse on gleam (no trait system); intended to fire on rust/go/python
    corpora in Phase 3."""
    try:
        impls = mcp.call_tool("goto_implementation", {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        })
    except RuntimeError:
        return None
    if not isinstance(impls, list) or len(impls) < 2:
        return None
    return {
        "id": qid,
        "kind": "implementations",
        "symbol": sym["name"],
        "anchor": {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        },
        "q": (
            f"In the {workspace_label} workspace, how many implementations "
            f"does the LSP report for `{sym['name']}` (defined at line "
            f"{sym['line'] + 1} of "
            f"{os.path.basename(uri_to_path(sym['uri']))})?"
        ),
        "ground_truth": len(impls),
    }


def gen_symbol_kind(mcp: McpStdio, sym: dict[str, Any],
                    workspace_label: str, qid: str,
                    ctx: dict[str, Any]) -> dict[str, Any] | None:
    """What kind of symbol is X (function / class / variable / etc.)?
    Only emits for kinds whose human label is unambiguous."""
    label = SYMBOL_KIND_LABELS.get(sym["kind"])
    if label is None:
        return None
    return {
        "id": qid,
        "kind": "symbol_kind",
        "symbol": sym["name"],
        "anchor": {
            "uri": sym["uri"],
            "line": sym["line"],
            "character": sym["character"],
        },
        "q": (
            f"In the {workspace_label} workspace, what kind of symbol is "
            f"`{sym['name']}` (defined at line {sym['line'] + 1} of "
            f"{os.path.basename(uri_to_path(sym['uri']))})? Answer with "
            f"one of: function, method, class, struct, enum, interface, "
            f"variable, constant, constructor, field, enum member, "
            f"type parameter."
        ),
        "ground_truth": label,
    }


GENERATORS = [
    ("references_count", gen_references_count),
    ("definition_path", gen_definition_uri),
    ("call_hierarchy_in", gen_call_hierarchy_in),
    ("collision_resolve", gen_collision_resolve),
    ("diagnostics_count", gen_diagnostics_count),
    ("containing_symbol", gen_containing_symbol),
    ("implementations", gen_implementations),
    ("symbol_kind", gen_symbol_kind),
]

GENERATORS_BY_NAME = dict(GENERATORS)


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
                    help="target number of questions in round-robin mode "
                         "(ignored when --per-kind is set)")
    ap.add_argument("--per-kind", type=int, default=0,
                    help="target questions per generator kind. When >0, "
                         "switches to per-kind sampling — each kind gets "
                         "its own pass over the symbol pool until N hit "
                         "or pool exhausted. Use for balanced Phase 2 "
                         "banks where per-kind metrics matter.")
    ap.add_argument("--kinds", default=None,
                    help="comma-separated subset of kinds to enable "
                         "(default = all). Names: references_count, "
                         "definition_path, call_hierarchy_in, "
                         "collision_resolve, diagnostics_count, "
                         "containing_symbol, implementations, symbol_kind.")
    ap.add_argument("--seed", type=int, default=1,
                    help="RNG seed for reproducibility")
    ap.add_argument("--label", default=None,
                    help="human label for the workspace, used in question "
                         "wording. Defaults to basename of --workspace.")
    ap.add_argument("--extensions", default=".gleam",
                    help="comma-separated source extensions to walk "
                         "(default `.gleam`)")
    ap.add_argument("--prewarm", action="store_true",
                    help="fire a throwaway document_symbols call on the "
                         "first source file before sampling, so the LSP's "
                         "cold-start cost doesn't contaminate generator "
                         "timing or the downstream harness wall metric.")
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

        if args.prewarm:
            files = list(walk_files(workspace, extensions))
            if files:
                t_warm = time.time()
                try:
                    mcp.call_tool("document_symbols",
                                  {"uri": path_to_uri(files[0])})
                    print(f"[oracle] prewarm in {time.time() - t_warm:.1f}s",
                          file=sys.stderr)
                except RuntimeError as e:
                    print(f"[oracle] prewarm failed (continuing): {e}",
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

        # Build per-kind context used by some generators.
        collisions = precompute_collisions(symbols)
        print(f"[oracle] {len(collisions)} colliding names "
              f"(name in 2+ files)", file=sys.stderr)
        file_symbols: dict[str, list[dict[str, Any]]] = {}
        for s in symbols:
            file_symbols.setdefault(s["uri"], []).append(s)
        diagnostics_recs = precompute_diagnostics(mcp, workspace, extensions)
        ctx: dict[str, Any] = {
            "collisions": collisions,
            "file_symbols": file_symbols,
            "diagnostics": diagnostics_recs,
        }

        enabled_kinds = set(GENERATORS_BY_NAME.keys())
        if args.kinds:
            requested = {k.strip() for k in args.kinds.split(",")}
            unknown = requested - enabled_kinds
            if unknown:
                sys.exit(f"unknown kinds: {sorted(unknown)}")
            enabled_kinds = requested
        active_gens = [(name, gen) for name, gen in GENERATORS
                       if name in enabled_kinds]

        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        emitted = 0
        per_kind_counts: dict[str, int] = {n: 0 for n, _ in active_gens}
        with open(args.out, "w") as fh:
            if args.per_kind > 0:
                target = args.per_kind
                # Each kind walks the (shuffled) symbol pool independently.
                # Diagnostics_count ignores the symbol arg and pulls from
                # its own precomputed pool, so a single pass over `symbols`
                # is still the right driver loop.
                for kind_name, gen in active_gens:
                    count = 0
                    for sym in symbols:
                        if count >= target:
                            break
                        qid = f"q{emitted + 1:04d}"
                        row = gen(mcp, sym, label, qid, ctx)
                        if row is None:
                            continue
                        fh.write(json.dumps(row) + "\n")
                        fh.flush()
                        emitted += 1
                        count += 1
                    per_kind_counts[kind_name] = count
                    print(f"[oracle]   {kind_name}: {count}/{target}",
                          file=sys.stderr)
            else:
                attempted = 0
                for sym in symbols:
                    if emitted >= args.n:
                        break
                    attempted += 1
                    kind_name, gen = active_gens[attempted % len(active_gens)]
                    qid = f"q{emitted + 1:04d}"
                    row = gen(mcp, sym, label, qid, ctx)
                    if row is None:
                        continue
                    fh.write(json.dumps(row) + "\n")
                    fh.flush()
                    emitted += 1
                    per_kind_counts[kind_name] = (
                        per_kind_counts.get(kind_name, 0) + 1
                    )
                    if emitted % 5 == 0:
                        print(f"[oracle] emitted {emitted}/{args.n}...",
                              file=sys.stderr)
        print(f"[oracle] done — {emitted} questions written to {args.out}",
              file=sys.stderr)
        print(f"[oracle] per-kind: {per_kind_counts}", file=sys.stderr)
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
