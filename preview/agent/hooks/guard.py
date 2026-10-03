#!/usr/bin/env python3
"""PreToolUse: refuse edits to protected files, shell commands that change Egor's live trees,
pushes and tag moves, the gate merge while the branch carries a protected change, and a sixth
subagent run on one task.

The shell checks are best-effort pattern matching; restore.py is the backstop."""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ inside the protected directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import BRANCH, PLAN, active, covers, git, load_state, project_root, run, save_state  # noqa: E402

MAX_RUNS = 5  # 2 attempts + a second opinion + attempt 3 + one spare
RUNS = "preview-agent-runs.json"
NOT_ATTEMPTS = {"Explore", "claude-code-guide", "statusline-setup"}  # read-only helpers
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
AGENT_TOOLS = {"Agent", "Task"}
OPEN_TASK = re.compile(r"^- \[ \] (.+)$", re.M)

# Egor's trees: the live config, the Neovide he builds from, the installed Neovide.
# The agent works in its worktrees (~/src/preview-agent, ~/src/neovide-agent) and may only read these.
LIVE = re.compile(r"\.config/nvim(?![\w.-])|src/neovide(?![\w.-])|neovide-patched")
MERGE = f"git -C ~/.config/nvim merge --ff-only {BRANCH}"
READ_CMDS = {"cat", "head", "tail", "less", "ls", "grep", "rg", "find", "wc", "diff", "stat", "file",
             "du", "echo", "printf", "sed", "awk", "sort", "uniq", "cut", "tr", "jq", "test", "[",
             "true", "realpath", "readlink", "git"}
READ_GIT = {"log", "status", "diff", "show", "rev-parse", "ls-files", "ls-tree", "merge-base",
            "cat-file", "describe", "rev-list", "blame", "grep", "for-each-ref", "shortlog"}
SEGMENT = re.compile(r"\|\|?|&&|;|\n|\$\(|`|[()]")
GIT_SUB = re.compile(r"^git((?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*)\s+([\w-]+)")
SINKS = re.compile(r"\d*>>?\s*/dev/null|\d*>&\d")
ONE = r"[^\n;&|]*"
PUSH = re.compile(rf"\bgit\b{ONE}\spush\b")
TAG_MOVE = re.compile(rf"\bgit\b{ONE}\stag\b{ONE}\s(-\w*[df]\w*|--delete|--force)\b")
UPDATE_REF = re.compile(rf"\bgit\b{ONE}\supdate-ref\b")


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


def may_write(cmd):
    """True unless every part of the command is a known read-only one."""
    if ">" in SINKS.sub("", cmd):
        return True
    for seg in SEGMENT.split(cmd):
        words = seg.split()
        while words and re.match(r"^\w+=", words[0]):
            words.pop(0)
        if not words:
            continue
        head, rest = os.path.basename(words[0]), " ".join(words)
        if head not in READ_CMDS:
            return True
        if head == "sed" and re.search(r"\s-\w*i", rest):
            return True
        if head == "find" and re.search(r"\s-(delete|exec|execdir|ok|okdir|fprint\w*)\b", rest):
            return True
        if head == "git":
            m = GIT_SUB.match(rest)
            if not m or m.group(2) not in READ_GIT:
                return True
    return False


def check_merge(root):
    bad = []
    for commit, label, paths in active(root, BRANCH):
        bad += [f"{p} ({label})" for p in
                git(root, "diff", "--name-only", commit, BRANCH, "--", *paths).splitlines()]
    if bad:
        deny(f"{BRANCH} carries changes to protected files, so it can't be merged into main:\n  " +
             "\n  ".join(bad) + "\nRevert them in a commit, then merge. If one is needed, explain "
             "why in preview/work/PENDING.md and leave the merge to Egor (BLOCKED.md).")


def check_bash(root, data):
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if " ".join(cmd.split()) == MERGE:
        check_merge(root)
        return
    if LIVE.search(cmd) and may_write(cmd):
        deny("This command may change Egor's trees (~/.config/nvim, ~/src/neovide, neovide-patched). "
             "Work in ~/src/preview-agent and ~/src/neovide-agent; the same git history is visible "
             f"there. Commands naming those paths must be read-only (cat/grep/ls/git log|show|diff...), "
             f"with no redirect. The one exception is `{MERGE}`, run on its own.")
    if PUSH.search(cmd):
        deny("Never push.")
    if TAG_MOVE.search(cmd) or UPDATE_REF.search(cmd):
        deny("Tags and refs are never deleted, moved or rewritten; create a tag only at a gate.")


def is_attempt(data):
    """A task attempt is a subagent the main session starts; read-only helpers don't count."""
    if data.get("agent_id"):
        return False
    return (data.get("tool_input") or {}).get("subagent_type") not in NOT_ATTEMPTS


def count_run(root):
    plan = root / PLAN
    m = OPEN_TASK.search(plan.read_text()) if plan.exists() else None
    if not m:
        return
    task = " ".join(m.group(1).split())
    runs = load_state(root, RUNS)
    runs[task] = runs.get(task, 0) + 1
    save_state(root, RUNS, runs)
    if runs[task] > MAX_RUNS:
        deny(f"Task '{task}' already had {MAX_RUNS} subagent runs. Stop working on it: mark it "
             f"'- [!]' in {PLAN}, add the reason and its notes file to preview/work/BLOCKED.md, "
             "and go on with the next task (a GATE: write preview/work/STOP.md and stop).")


def main(data):
    tool = data.get("tool_name")
    if tool in EDIT_TOOLS:
        check_edit(project_root(data), data)
    elif tool == "Bash":
        check_bash(project_root(data), data)
    elif tool in AGENT_TOOLS and is_attempt(data):
        count_run(project_root(data))


run(main)
