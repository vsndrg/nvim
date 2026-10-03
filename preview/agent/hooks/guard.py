#!/usr/bin/env python3
"""PreToolUse: refuse edits to protected files, and a sixth subagent run on one task."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ inside the protected directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import PLAN, active, covers, project_root, run, state_dir  # noqa: E402

MAX_RUNS = 5  # 3 attempts + a second opinion + one spare
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
AGENT_TOOLS = {"Agent", "Task"}
OPEN_TASK = re.compile(r"^- \[ \] (.+)$", re.M)


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def check_edit(root, data):
    args = data.get("tool_input") or {}
    raw = args.get("file_path") or args.get("notebook_path")
    if not raw:
        return
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = Path(data.get("cwd") or root) / path
    try:
        rel = path.resolve().relative_to(root).as_posix()
    except ValueError:
        return  # outside the worktree: the settings.json rules apply
    for _, label, paths in active(root):
        if covers(paths, rel):
            deny(f"{rel} is protected ({label}). Don't change it; if it is wrong, "
                 "explain why in preview/work/PENDING.md and move on.")


def count_run(root):
    plan = root / PLAN
    m = OPEN_TASK.search(plan.read_text()) if plan.exists() else None
    if not m:
        return
    task = m.group(1).strip()
    state = state_dir(root) / "preview-agent-runs.json"
    try:
        saved = json.loads(state.read_text())
    except (OSError, ValueError):
        saved = {}
    count = saved.get("count", 0) + 1 if saved.get("task") == task else 1
    state.write_text(json.dumps({"task": task, "count": count}))
    if count > MAX_RUNS:
        deny(f"Task '{task}' already had {MAX_RUNS} subagent runs. Stop working on it: mark it "
             f"'- [!]' in {PLAN}, add the reason and its notes file to preview/work/BLOCKED.md, "
             "and go on with the next task.")


def main(data):
    tool = data.get("tool_name")
    if tool in EDIT_TOOLS:
        check_edit(project_root(data), data)
    elif tool in AGENT_TOOLS:
        count_run(project_root(data))


run(main)
