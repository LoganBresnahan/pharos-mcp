"""Harness — drive Claude through the oracle's question bank in two arms.

Reads a JSONL question bank produced by `bench/oracle.py`, runs each
question through the Claude Agent SDK twice — once with only
`Bash` + `Read` available (control), once with the pharos MCP server
also mounted (treatment) — and records the agent's answer, tool
usage, token spend, and wall time.

System prompt is identical across arms and never mentions pharos /
LSPs. The agent is asked to emit its final answer inside
`<answer>...</answer>` tags so scoring can be regex-extracted without
relying on the model to follow a strict JSON schema.

Usage:
    export CLAUDE_API_KEY=sk-...
    python3 bench/harness.py \
        --questions bench/data/gleam.jsonl \
        --workspace tmp/fixtures/gleam \
        --out bench/results/smoke.jsonl \
        --limit 3 --trials 1 \
        --model claude-sonnet-4-6

Output: one JSONL row per (question, arm, trial), e.g.

    {"qid": "q0001", "arm": "treatment", "trial": 0,
     "model": "claude-sonnet-4-6",
     "answer_raw": "/home/oof/.../uri.gleam",
     "tool_calls": [{"name": "mcp__pharos__find_references", ...}, ...],
     "turns": 4,
     "tokens_in": 1234, "tokens_out": 56,
     "cost_usd": 0.0042,
     "wall_time_s": 8.3,
     "error": null}
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    query,
)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHAROS_BIN = os.path.join(PROJECT_ROOT, "bin", "pharos-dev")

SYSTEM_PROMPT = """\
You are answering navigation questions about a codebase located at the
current working directory. Use whichever tools are available to find
the answer. Be efficient — read only what you need. When you have the
answer, emit it on a single line between <answer> and </answer> tags
and then stop. Do not add commentary inside the tags.
"""

ANSWER_RE = re.compile(r"<answer>\s*(.*?)\s*</answer>", re.DOTALL)


def build_user_prompt(question: dict[str, Any], workspace: str) -> str:
    """Wrap the oracle's question with a per-trial preamble that
    pins the workspace path (since the agent's cwd matches but
    being explicit helps the LLM frame answers correctly).

    The question's `q` field already contains the natural-language
    prompt; we add only the workspace path and the answer tag
    reminder."""
    return (
        f"Workspace root: {workspace}\n\n"
        f"Question: {question['q']}\n\n"
        f"Return your final answer wrapped in <answer></answer> tags. "
        f"For numeric questions, the answer is a single integer. For "
        f"path questions, the answer is one absolute filesystem path "
        f"with no scheme prefix."
    )


def extract_answer(text: str) -> str | None:
    m = ANSWER_RE.search(text)
    if m is None:
        return None
    return m.group(1).strip()


def _common_options(workspace: str, model: str) -> dict[str, Any]:
    """Shared knobs that ensure the agent runs in a fully isolated
    sandbox — no user-level Claude Code settings leaking in, no
    parent MCP servers inherited, no Edit/Write."""
    return {
        "model": model,
        "system_prompt": SYSTEM_PROMPT,
        "cwd": workspace,
        "permission_mode": "bypassPermissions",
        "max_turns": 40,
        # Critical isolation: ignore user/project/local settings.
        # Default (None) picks up `~/.claude/settings.json`, which on
        # the dev box already has pharos mounted via MCP and would
        # bleed into the control arm.
        "setting_sources": [],
        # Critical isolation: only use MCP servers we declare. Without
        # this, the SDK merges user-level MCP config into ours.
        "strict_mcp_config": True,
        "disallowed_tools": ["Edit", "Write", "NotebookEdit"],
    }


def control_options(workspace: str, model: str) -> ClaudeAgentOptions:
    return ClaudeAgentOptions(
        **_common_options(workspace, model),
        allowed_tools=["Bash", "Read", "Grep", "Glob"],
        # No MCP servers configured — control arm has none.
    )


def treatment_options(workspace: str, model: str) -> ClaudeAgentOptions:
    return ClaudeAgentOptions(
        **_common_options(workspace, model),
        allowed_tools=[
            "Bash",
            "Read",
            "Grep",
            "Glob",
            # MCP tools live under the `mcp__pharos__*` namespace at the
            # SDK level. Listing the namespace prefix admits every
            # pharos-exposed tool without enumerating each by name.
            "mcp__pharos",
        ],
        mcp_servers={
            "pharos": {
                "type": "stdio",
                "command": PHAROS_BIN,
                "args": [],
                "env": {
                    "PHAROS_LOG_LEVEL": "error",
                    "PHAROS_HTTP_ENABLED": "false",
                },
            },
        },
    )


async def run_one(question: dict[str, Any], arm: str, trial: int,
                  workspace: str, model: str) -> dict[str, Any]:
    """Drive one (question, arm, trial). Returns the result row."""
    if arm == "control":
        options = control_options(workspace, model)
    elif arm == "treatment":
        options = treatment_options(workspace, model)
    else:
        raise ValueError(f"unknown arm: {arm}")

    user_prompt = build_user_prompt(question, workspace)

    tool_calls: list[dict[str, Any]] = []
    final_text_chunks: list[str] = []
    turns = 0
    tokens_in = 0
    tokens_out = 0
    cost_usd = 0.0
    error: str | None = None

    t0 = time.monotonic()
    try:
        async for msg in query(prompt=user_prompt, options=options):
            if isinstance(msg, AssistantMessage):
                turns += 1
                for block in msg.content:
                    if isinstance(block, TextBlock):
                        final_text_chunks.append(block.text)
                    elif isinstance(block, ToolUseBlock):
                        tool_calls.append({
                            "name": block.name,
                            # Keep args summary short — full args bloat
                            # the result JSONL. Just record keys so the
                            # post-hoc analysis can see what the agent
                            # asked for.
                            "args_keys": sorted(list(block.input.keys()))
                                if isinstance(block.input, dict) else [],
                        })
            elif isinstance(msg, ResultMessage):
                # ResultMessage carries final usage + cost. Some
                # builds expose `usage` as a dict; be defensive.
                usage = getattr(msg, "usage", None) or {}
                tokens_in = (usage.get("input_tokens") or 0) + (
                    usage.get("cache_read_input_tokens") or 0) + (
                    usage.get("cache_creation_input_tokens") or 0)
                tokens_out = usage.get("output_tokens") or 0
                cost_usd = float(getattr(msg, "total_cost_usd", 0.0) or 0.0)
                if getattr(msg, "is_error", False):
                    error = getattr(msg, "result", None) or "unknown error"
    except Exception as e:
        error = f"{type(e).__name__}: {e}"
    wall = time.monotonic() - t0

    full_text = "".join(final_text_chunks)
    answer_raw = extract_answer(full_text)
    return {
        "qid": question["id"],
        "kind": question["kind"],
        "arm": arm,
        "trial": trial,
        "model": model,
        "answer_raw": answer_raw,
        "answer_missing_tag": answer_raw is None,
        "tool_calls": tool_calls,
        "tool_call_count": len(tool_calls),
        "turns": turns,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cost_usd": cost_usd,
        "wall_time_s": round(wall, 3),
        "error": error,
    }


async def main_async(args: argparse.Namespace) -> int:
    if not os.environ.get("CLAUDE_API_KEY") and not os.environ.get(
            "ANTHROPIC_API_KEY"):
        print("[harness] FATAL: set CLAUDE_API_KEY or ANTHROPIC_API_KEY",
              file=sys.stderr)
        return 2

    # The SDK reads ANTHROPIC_API_KEY by convention; mirror from
    # CLAUDE_API_KEY if that's what's set.
    if (not os.environ.get("ANTHROPIC_API_KEY")
            and os.environ.get("CLAUDE_API_KEY")):
        os.environ["ANTHROPIC_API_KEY"] = os.environ["CLAUDE_API_KEY"]

    questions = []
    with open(args.questions) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            questions.append(json.loads(line))
    if args.limit:
        questions = questions[: args.limit]

    workspace = os.path.abspath(args.workspace)
    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    print(f"[harness] {len(questions)} questions × {len(arms)} arms × "
          f"{args.trials} trial(s) = "
          f"{len(questions) * len(arms) * args.trials} runs",
          file=sys.stderr)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    total_cost = 0.0
    pass_count = 0
    out_fh = open(args.out, "w")
    try:
        for trial in range(args.trials):
            for q in questions:
                for arm in arms:
                    label = f"[{q['id']} {arm} trial={trial}]"
                    print(f"{label} running...", file=sys.stderr, flush=True)
                    row = await run_one(q, arm, trial, workspace, args.model)
                    # Add ground_truth for downstream scoring.
                    row["ground_truth"] = q["ground_truth"]
                    out_fh.write(json.dumps(row) + "\n")
                    out_fh.flush()
                    total_cost += row["cost_usd"]
                    if row["error"]:
                        print(f"{label} ERROR: {row['error'][:120]}",
                              file=sys.stderr)
                    else:
                        print(
                            f"{label} answer={row['answer_raw']!r} "
                            f"tools={row['tool_call_count']} "
                            f"turns={row['turns']} "
                            f"t={row['wall_time_s']:.1f}s "
                            f"cost=${row['cost_usd']:.4f}",
                            file=sys.stderr,
                        )
                    pass_count += 1
    finally:
        out_fh.close()

    print(f"[harness] done — {pass_count} runs, total cost "
          f"${total_cost:.2f}, output {args.out}", file=sys.stderr)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--questions", required=True,
                    help="oracle JSONL question bank")
    ap.add_argument("--workspace", required=True,
                    help="fixture root the agent will navigate")
    ap.add_argument("--out", required=True,
                    help="output JSONL path for per-run results")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap on questions (0 = all)")
    ap.add_argument("--trials", type=int, default=1,
                    help="reruns per (question, arm); average across "
                         "trials in scoring to dampen LLM stochasticity")
    ap.add_argument("--arms", default="control,treatment",
                    help="comma-separated arms to run")
    ap.add_argument("--model", default="claude-sonnet-4-6",
                    help="Claude model id (any model the SDK accepts; "
                         "default claude-sonnet-4-6)")
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
