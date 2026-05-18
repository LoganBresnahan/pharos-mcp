"""DeepSeek-backed harness with manual tool-use loop.

Mirrors `bench/harness.py`'s contract (reads an oracle JSONL bank,
runs each question in two arms, writes one JSONL row per
(question, arm, trial)) but routes through DeepSeek V4 instead of
the Claude Agent SDK.

Why a parallel harness: `claude_agent_sdk` spawns Claude Code CLI
under the hood, which is Anthropic-only. To exercise non-Anthropic
models we drive the OpenAI-compatible endpoint directly and
implement the tool-use loop ourselves. Control-arm tools (Bash,
Read, Grep, Glob) run locally as Python callables; treatment-arm
adds pharos's MCP tools by bridging through the `McpStdio` client
already used by `bench/oracle.py`.

Models supported (DeepSeek V4 lineup):

    flash         deepseek-v4-flash, thinking disabled
    flash-thinking deepseek-v4-flash, thinking enabled
    pro           deepseek-v4-pro,   thinking disabled
    pro-thinking  deepseek-v4-pro,   thinking enabled

Pricing is computed locally from token counts and cross-checked
against the DeepSeek `/user/balance` endpoint (called pre + post
run; delta is the authoritative spend).

Usage:
    export DEEPSEEK_API_KEY=sk-...
    python3 bench/harness_deepseek.py \\
        --questions bench/data/gleam.jsonl \\
        --workspace tmp/fixtures/gleam \\
        --out bench/results/ds-flash.jsonl \\
        --variant flash --limit 2 --trials 1
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from typing import Any

import urllib.request

# Reuse the proven MCP/stdio client from oracle.py.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from oracle import McpStdio  # noqa: E402

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# Model variants + pricing
# ---------------------------------------------------------------------------

VARIANTS: dict[str, dict[str, Any]] = {
    "flash": {
        "model": "deepseek-v4-flash",
        "thinking": False,
        "price_in_miss": 0.14 / 1_000_000,
        "price_in_hit": 0.0028 / 1_000_000,
        "price_out": 0.28 / 1_000_000,
    },
    "flash-thinking": {
        "model": "deepseek-v4-flash",
        "thinking": True,
        "price_in_miss": 0.14 / 1_000_000,
        "price_in_hit": 0.0028 / 1_000_000,
        "price_out": 0.28 / 1_000_000,
    },
    "pro": {
        "model": "deepseek-v4-pro",
        "thinking": False,
        # Promo pricing — 75 % discount through 2026-05-31. Re-cost
        # after that with the un-discounted rate (input miss 1.74,
        # output 3.48) when comparing across time.
        "price_in_miss": 0.435 / 1_000_000,
        "price_in_hit": 0.003625 / 1_000_000,
        "price_out": 0.87 / 1_000_000,
    },
    "pro-thinking": {
        "model": "deepseek-v4-pro",
        "thinking": True,
        "price_in_miss": 0.435 / 1_000_000,
        "price_in_hit": 0.003625 / 1_000_000,
        "price_out": 0.87 / 1_000_000,
    },
}


SYSTEM_PROMPT = """\
You are answering navigation questions about a codebase located at \
the current working directory. Use whichever tools are available to \
find the answer. Be efficient — read only what you need. When you \
have the answer, emit it on a single line between <answer> and \
</answer> tags and then stop. Do not add commentary inside the tags.
"""

ANSWER_RE = re.compile(r"<answer>\s*(.*?)\s*</answer>", re.DOTALL)


# ---------------------------------------------------------------------------
# Local tool implementations (control arm)
# ---------------------------------------------------------------------------

# Hard caps so a runaway tool call can't drain budget.
TOOL_CALL_TIMEOUT_S = 30
MAX_OUTPUT_BYTES = 64_000


def _truncate(s: str) -> str:
    if len(s) <= MAX_OUTPUT_BYTES:
        return s
    return s[:MAX_OUTPUT_BYTES] + f"\n... [truncated {len(s) - MAX_OUTPUT_BYTES} bytes]"


def tool_bash(workspace: str, command: str) -> str:
    """Run a shell command inside the workspace cwd. Used by the
    control arm to grep, walk directories, etc. Edits are not in the
    advertised tool list, but a creative model could still
    `bash -c "echo > foo"` — the workspace is a test fixture so the
    blast radius is bounded; restore via `git checkout` if needed."""
    try:
        out = subprocess.run(
            ["bash", "-c", command],
            cwd=workspace,
            capture_output=True,
            text=True,
            timeout=TOOL_CALL_TIMEOUT_S,
        )
        body = out.stdout + (("\nSTDERR:\n" + out.stderr) if out.stderr else "")
        if out.returncode != 0:
            body = f"exit {out.returncode}\n" + body
        return _truncate(body)
    except subprocess.TimeoutExpired:
        return f"ERROR: bash command timed out after {TOOL_CALL_TIMEOUT_S}s"


def tool_read(workspace: str, file_path: str,
              offset: int = 0, limit: int | None = None) -> str:
    """Read a file relative to the workspace, optional line slice."""
    path = os.path.join(workspace, file_path) if not os.path.isabs(file_path) else file_path
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        return f"ERROR: file not found: {file_path}"
    except IsADirectoryError:
        return f"ERROR: is a directory: {file_path}"
    if limit is None:
        end = len(lines)
    else:
        end = min(len(lines), offset + limit)
    sliced = lines[offset:end]
    return _truncate("".join(sliced))


def tool_grep(workspace: str, pattern: str, path: str = ".",
              output_mode: str = "files_with_matches") -> str:
    """Wrap ripgrep (or fall back to grep -R) over the workspace."""
    rg = shutil_which("rg")
    if rg:
        flags = []
        if output_mode == "files_with_matches":
            flags.append("--files-with-matches")
        elif output_mode == "count":
            flags.append("--count")
        cmd = [rg, *flags, "-n", pattern, path]
    else:
        cmd = ["grep", "-Rn", pattern, path]
    try:
        out = subprocess.run(
            cmd, cwd=workspace, capture_output=True, text=True,
            timeout=TOOL_CALL_TIMEOUT_S,
        )
        return _truncate(out.stdout + (("\nSTDERR:\n" + out.stderr) if out.stderr else ""))
    except subprocess.TimeoutExpired:
        return "ERROR: grep timed out"


def tool_glob(workspace: str, pattern: str) -> str:
    """Glob expansion via Python's glob.glob with workspace cwd."""
    import glob as _glob
    full_pattern = pattern if os.path.isabs(pattern) else os.path.join(workspace, pattern)
    matches = sorted(_glob.glob(full_pattern, recursive=True))
    rel = [os.path.relpath(m, workspace) for m in matches]
    return _truncate("\n".join(rel) if rel else "(no matches)")


def shutil_which(cmd: str) -> str | None:
    import shutil
    return shutil.which(cmd)


# Function schemas advertised to the model (OpenAI tool spec).
def _control_tool_specs() -> list[dict[str, Any]]:
    return [
        {
            "type": "function",
            "function": {
                "name": "Bash",
                "description": "Run a shell command in the workspace.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": {"type": "string", "description": "Shell command to run."},
                    },
                    "required": ["command"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "Read",
                "description": "Read a file (full or sliced).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "file_path": {"type": "string"},
                        "offset": {"type": "integer", "description": "0-based line offset"},
                        "limit": {"type": "integer", "description": "max lines to read"},
                    },
                    "required": ["file_path"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "Grep",
                "description": "Search files for a regex pattern.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": {"type": "string"},
                        "path": {"type": "string", "description": "Subdirectory to search (default '.')"},
                        "output_mode": {
                            "type": "string",
                            "enum": ["content", "files_with_matches", "count"],
                        },
                    },
                    "required": ["pattern"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "Glob",
                "description": "List files matching a glob pattern.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": {"type": "string", "description": "Glob with ** allowed"},
                    },
                    "required": ["pattern"],
                },
            },
        },
    ]


# ---------------------------------------------------------------------------
# Pharos bridge — exposes MCP tools as OpenAI function specs
# ---------------------------------------------------------------------------


def fetch_pharos_tool_specs(mcp: McpStdio) -> list[dict[str, Any]]:
    """Ask pharos for its `tools/list` and translate to OpenAI shape.
    Tool name is prefixed `pharos__` so the dispatcher can route
    back through MCP."""
    resp = mcp._send("tools/list", {})
    if "error" in resp:
        raise RuntimeError(f"tools/list failed: {resp['error']}")
    out = []
    for t in resp.get("result", {}).get("tools", []):
        name = t.get("name")
        if not name:
            continue
        out.append({
            "type": "function",
            "function": {
                "name": "pharos__" + name,
                "description": t.get("description", ""),
                "parameters": t.get("inputSchema", {"type": "object"}),
            },
        })
    return out


def call_pharos_tool(mcp: McpStdio, tool_name: str, args: dict[str, Any]) -> str:
    """Route an OpenAI-shaped tool call back to pharos. Returns the
    flattened text payload pharos emits in its `content[0].text`."""
    # Strip the `pharos__` prefix to recover the MCP-side name.
    raw = tool_name[len("pharos__"):] if tool_name.startswith("pharos__") else tool_name
    resp = mcp._send("tools/call", {"name": raw, "arguments": args})
    if "error" in resp:
        return f"ERROR: {resp['error']}"
    result = resp.get("result", {})
    text = "".join(
        c.get("text", "")
        for c in result.get("content", [])
        if c.get("type") == "text"
    )
    if result.get("isError"):
        text = "isError=true; " + text
    return _truncate(text)


# ---------------------------------------------------------------------------
# Tool dispatch
# ---------------------------------------------------------------------------


def dispatch_tool(name: str, args: dict[str, Any], workspace: str,
                  mcp: McpStdio | None) -> str:
    if name == "Bash":
        return tool_bash(workspace, args.get("command", ""))
    if name == "Read":
        return tool_read(workspace, args.get("file_path", ""),
                         offset=int(args.get("offset", 0) or 0),
                         limit=args.get("limit"))
    if name == "Grep":
        return tool_grep(workspace, args.get("pattern", ""),
                         path=args.get("path", "."),
                         output_mode=args.get("output_mode", "files_with_matches"))
    if name == "Glob":
        return tool_glob(workspace, args.get("pattern", ""))
    if name.startswith("pharos__") and mcp is not None:
        return call_pharos_tool(mcp, name, args)
    return f"ERROR: unknown tool {name}"


# ---------------------------------------------------------------------------
# DeepSeek balance probe
# ---------------------------------------------------------------------------


def deepseek_balance_usd(api_key: str) -> float | None:
    req = urllib.request.Request(
        "https://api.deepseek.com/user/balance",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = json.loads(r.read())
    except Exception as e:
        print(f"[harness] balance probe failed: {e}", file=sys.stderr)
        return None
    for b in body.get("balance_infos", []):
        if b.get("currency") == "USD":
            try:
                return float(b.get("total_balance", "0"))
            except ValueError:
                return None
    return None


# ---------------------------------------------------------------------------
# Main agent loop — one question, one arm
# ---------------------------------------------------------------------------


def build_user_prompt(q: dict[str, Any], workspace: str) -> str:
    return (
        f"Workspace root: {workspace}\n\n"
        f"Question: {q['q']}\n\n"
        f"Return your final answer wrapped in <answer></answer> tags. "
        f"For numeric questions, the answer is a single integer. For "
        f"path questions, the answer is one absolute filesystem path "
        f"with no scheme prefix."
    )


def run_one(client, q: dict[str, Any], arm: str, trial: int,
            workspace: str, variant_label: str, variant_cfg: dict[str, Any],
            mcp: McpStdio | None, max_turns: int = 30) -> dict[str, Any]:
    """One (question, arm, trial). Returns the result row."""
    tools = list(_control_tool_specs())
    if arm == "treatment":
        if mcp is None:
            raise RuntimeError("treatment arm requires --workspace with pharos")
        tools.extend(fetch_pharos_tool_specs(mcp))

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": build_user_prompt(q, workspace)},
    ]

    tool_calls_log: list[dict[str, Any]] = []
    turns = 0
    prompt_tokens = 0
    cached_tokens = 0
    completion_tokens = 0
    reasoning_tokens = 0
    final_text = ""
    error: str | None = None

    extra_body: dict[str, Any] = {}
    if variant_cfg["thinking"]:
        extra_body["thinking"] = {"type": "enabled"}
    else:
        extra_body["thinking"] = {"type": "disabled"}

    t0 = time.monotonic()
    try:
        for _ in range(max_turns):
            turns += 1
            kwargs: dict[str, Any] = {
                "model": variant_cfg["model"],
                "messages": messages,
                "tools": tools,
                "tool_choice": "auto",
                "extra_body": extra_body,
            }
            # Thinking mode forbids these sampling knobs per DeepSeek
            # docs; leave defaults.
            resp = client.chat.completions.create(**kwargs)
            usage = getattr(resp, "usage", None)
            if usage is not None:
                prompt_tokens += usage.prompt_tokens or 0
                completion_tokens += usage.completion_tokens or 0
                ptd = getattr(usage, "prompt_tokens_details", None)
                if ptd is not None:
                    cached_tokens += getattr(ptd, "cached_tokens", 0) or 0
                ctd = getattr(usage, "completion_tokens_details", None)
                if ctd is not None:
                    reasoning_tokens += getattr(ctd, "reasoning_tokens", 0) or 0

            choice = resp.choices[0]
            msg = choice.message
            # Append assistant message verbatim so subsequent turns
            # carry tool-call ids and any reasoning_content.
            assistant_msg: dict[str, Any] = {"role": "assistant"}
            if msg.content is not None:
                assistant_msg["content"] = msg.content
                final_text += msg.content
            else:
                assistant_msg["content"] = None
            # DeepSeek's thinking-mode requires reasoning_content to
            # be echoed back in multi-turn tool flows.
            reasoning = getattr(msg, "reasoning_content", None)
            if reasoning:
                assistant_msg["reasoning_content"] = reasoning
            if msg.tool_calls:
                assistant_msg["tool_calls"] = [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in msg.tool_calls
                ]
            messages.append(assistant_msg)

            if not msg.tool_calls:
                # Final answer turn.
                break

            for tc in msg.tool_calls:
                try:
                    args = json.loads(tc.function.arguments or "{}")
                except json.JSONDecodeError:
                    args = {}
                tool_calls_log.append({
                    "name": tc.function.name,
                    "args_keys": sorted(args.keys()) if isinstance(args, dict) else [],
                })
                result_text = dispatch_tool(tc.function.name, args, workspace, mcp)
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": result_text,
                })
    except Exception as e:
        error = f"{type(e).__name__}: {e}"
    wall = time.monotonic() - t0

    # Local cost estimate: assume all input tokens are cache misses
    # except `cached_tokens` reported by the API.
    miss_in = max(0, prompt_tokens - cached_tokens)
    cost_local = (
        miss_in * variant_cfg["price_in_miss"]
        + cached_tokens * variant_cfg["price_in_hit"]
        + completion_tokens * variant_cfg["price_out"]
    )

    m = ANSWER_RE.search(final_text)
    answer_raw = m.group(1).strip() if m else None
    # Last 400 chars of the model's content stream — surfaces what
    # the model said when it forgot to emit <answer> tags. Without
    # this debugging is guesswork. Truncated to keep JSONL rows
    # bounded.
    final_text_tail = final_text[-400:] if final_text else ""
    return {
        "qid": q["id"],
        "kind": q["kind"],
        "arm": arm,
        "trial": trial,
        "variant": variant_label,
        "model": variant_cfg["model"],
        "thinking": variant_cfg["thinking"],
        "answer_raw": answer_raw,
        "answer_missing_tag": answer_raw is None,
        "final_text_tail": final_text_tail,
        "tool_calls": tool_calls_log,
        "tool_call_count": len(tool_calls_log),
        "turns": turns,
        "tokens_in": prompt_tokens,
        "tokens_in_cached": cached_tokens,
        "tokens_out": completion_tokens,
        "tokens_reasoning": reasoning_tokens,
        "cost_usd": round(cost_local, 6),
        "wall_time_s": round(wall, 3),
        "error": error,
        "ground_truth": q["ground_truth"],
    }


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--questions", required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--trials", type=int, default=1)
    ap.add_argument("--arms", default="control,treatment")
    ap.add_argument("--variant", choices=list(VARIANTS.keys()), required=True)
    ap.add_argument("--max-turns", type=int, default=30)
    args = ap.parse_args()

    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        print("[harness] FATAL: set DEEPSEEK_API_KEY", file=sys.stderr)
        return 2

    from openai import OpenAI
    client = OpenAI(api_key=api_key, base_url="https://api.deepseek.com/v1")

    variant_cfg = VARIANTS[args.variant]
    workspace = os.path.abspath(args.workspace)
    arms = [a.strip() for a in args.arms.split(",") if a.strip()]

    questions: list[dict[str, Any]] = []
    with open(args.questions) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            questions.append(json.loads(line))
    if args.limit:
        questions = questions[: args.limit]

    bal_before = deepseek_balance_usd(api_key)
    print(f"[harness] variant={args.variant} model={variant_cfg['model']} "
          f"thinking={variant_cfg['thinking']} balance_before=${bal_before}",
          file=sys.stderr)

    # One MCP session per pass (reused across questions). Treatment
    # only — control never opens pharos.
    mcp: McpStdio | None = None
    if "treatment" in arms:
        mcp = McpStdio(workspace)
        mcp.initialize()

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    out_fh = open(args.out, "w")
    total_cost_local = 0.0
    n_runs = 0
    try:
        for trial in range(args.trials):
            for q in questions:
                for arm in arms:
                    label = f"[{q['id']} {args.variant} {arm} trial={trial}]"
                    print(f"{label} running...", file=sys.stderr, flush=True)
                    row = run_one(
                        client, q, arm, trial, workspace,
                        args.variant, variant_cfg, mcp,
                        max_turns=args.max_turns,
                    )
                    out_fh.write(json.dumps(row) + "\n")
                    out_fh.flush()
                    total_cost_local += row["cost_usd"]
                    n_runs += 1
                    if row["error"]:
                        print(f"{label} ERROR: {row['error'][:120]}",
                              file=sys.stderr)
                    else:
                        print(
                            f"{label} answer={row['answer_raw']!r} "
                            f"tools={row['tool_call_count']} "
                            f"turns={row['turns']} "
                            f"tok_in={row['tokens_in']} "
                            f"tok_out={row['tokens_out']} "
                            f"reasoning={row['tokens_reasoning']} "
                            f"t={row['wall_time_s']:.1f}s "
                            f"cost~${row['cost_usd']:.4f}",
                            file=sys.stderr,
                        )
    finally:
        if mcp is not None:
            mcp.close()
        out_fh.close()

    bal_after = deepseek_balance_usd(api_key)
    print(f"[harness] balance_after=${bal_after} "
          f"runs={n_runs} cost_local_sum=${total_cost_local:.4f}",
          file=sys.stderr)
    if bal_before is not None and bal_after is not None:
        delta = bal_before - bal_after
        print(f"[harness] balance_delta=${delta:.4f} "
              f"(local_est ${total_cost_local:.4f}, "
              f"diff ${delta - total_cost_local:+.4f})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
