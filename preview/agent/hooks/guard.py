#!/usr/bin/env python3
"""PreToolUse: refuse edits to protected and orchestrator-owned files, shell commands that
change Egor's live trees, git commands that rewrite shared refs, subagents, and any write
in the read-only roles (review, opinion; PREVIEW_ROLE is set by run.py).

The shell checks are best-effort pattern matching; restore.py and run.py are the backstop."""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ inside the protected directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import OWNED, active, covers, project_root, run  # noqa: E402

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
AGENT_TOOLS = {"Agent", "Task", "Workflow"}
READ_ONLY_ROLES = {"review", "opinion"}

# Egor's trees: the live config, the Neovide he builds from, the installed Neovide.
# The agent works in its worktrees (~/src/preview-agent, ~/src/neovide-agent) and may only read these.
LIVE = re.compile(r"\.config/nvim(?![\w.-])|src/neovide(?![\w.-])|neovide-patched")
READ_CMDS = {"cat", "head", "tail", "less", "ls", "grep", "rg", "find", "wc", "diff", "stat", "file",
             "du", "echo", "printf", "sed", "awk", "sort", "uniq", "cut", "tr", "jq", "test", "[",
             "true", "realpath", "readlink", "git", "cd", "pwd", "nl", "basename", "dirname"}
READ_GIT = {"log", "status", "diff", "show", "rev-parse", "ls-files", "ls-tree", "merge-base",
            "cat-file", "describe", "rev-list", "blame", "grep", "for-each-ref", "shortlog"}
SEGMENT = re.compile(r"\|\|?|&&|;|\n|\$\(|`|[()]")
GIT_SUB = re.compile(r"^git((?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*)\s+([\w-]+)(.*)$", re.S)
SINKS = re.compile(r"\d*>>?\s*/dev/null|\d*>&\d")
WRITE_OPTS = re.compile(r"\s--output(=|\s)|\s--ext-diff\b|\s-O\S*|\s--open-files-in-pager")

# git subcommands that change shared refs or config (the worktrees share them with Egor's
# repos): only run.py tags, merges into main and saves attempts.
TAG_READ = {"-l", "--list", "-n", "--contains", "--no-contains", "--points-at", "--merged",
            "--no-merged", "--sort", "--format", "--column", "--no-column", "-v", "--verify"}
BRANCH_WRITE = re.compile(r"\s(-[a-zA-Z]*[dDmMcCf][a-zA-Z]*|--delete|--move|--copy|--force|"
                          r"--set-upstream-to\S*|-u|--unset-upstream|--edit-description)\b")
GIT_DENY = {
    "push": "Never push.",
    "update-ref": "Refs are never rewritten by hand.",
    "symbolic-ref": "Refs are never rewritten by hand.",
    "gc": "No gc/prune/reflog expiry: earlier attempts are kept in refs/wip/.",
    "prune": "No gc/prune/reflog expiry: earlier attempts are kept in refs/wip/.",
    "filter-branch": "History is never rewritten.",
    "filter-repo": "History is never rewritten.",
    "replace": "History is never rewritten.",
    "remote": "Remotes belong to Egor.",
}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def role():
    return os.environ.get("PREVIEW_ROLE", "")


def check_edit(root, data):
    if role() in READ_ONLY_ROLES:
        deny("This session is read-only: don't edit anything, report in your answer.")
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
    if rel in OWNED:
        deny(f"{rel} is written by the orchestrator (run.py) only. Report through your answer, "
             "notes, CONTEXT.md, DECISIONS.md or PENDING.md.")
    for _, label, include, exclude in active(root):
        if covers(include, exclude, rel):
            deny(f"{rel} is protected ({label}). Don't change it; if it is wrong, "
                 "explain why in preview/work/PENDING.md and move on.")


def segments(cmd):
    for seg in SEGMENT.split(cmd):
        words = seg.split()
        while words and re.match(r"^\w+=", words[0]):
            words.pop(0)
        if words:
            yield words


def may_write(cmd):
    """True unless every part of the command is a known read-only one."""
    if ">" in SINKS.sub("", cmd):
        return True
    for words in segments(cmd):
        head, rest = os.path.basename(words[0]), " ".join(words)
        if head not in READ_CMDS:
            return True
        if head == "sed" and re.search(r"\s-\w*i", rest):
            return True
        if head == "find" and re.search(r"\s-(delete|exec|execdir|ok|okdir|fprint\w*|fls)\b", rest):
            return True
        if head == "awk" and re.search(r"system\s*\(|\|\s*\"|print\s*>", rest):
            return True
        if head == "git":
            m = GIT_SUB.match(rest)
            if not m or m.group(2) not in READ_GIT or WRITE_OPTS.search(m.group(3)):
                return True
    return False


def git_danger(cmd):
    """Reason to refuse a git command that changes shared refs/config, or None."""
    for words in segments(cmd):
        if os.path.basename(words[0]) != "git":
            continue
        m = GIT_SUB.match(" ".join(words))
        if not m:
            continue
        sub, rest = m.group(2), m.group(3)
        args = rest.split()
        if sub in GIT_DENY:
            return GIT_DENY[sub]
        if sub == "tag" and args and args[0] not in TAG_READ:
            return "Only run.py creates, moves or deletes tags (gate tags are its record)."
        if sub == "branch" and BRANCH_WRITE.search(" " + rest):
            return "Branches are never deleted, moved, copied or forced; stay on agent/preview."
        if sub == "worktree" and (not args or args[0] != "list"):
            return "The worktrees are fixed: don't add, move or remove them."
        if sub == "config" and not (args and args[0] in {"--get", "--get-all", "--get-regexp", "-l", "--list"}):
            return "git config is shared with Egor's repo: read it only (--get/--list)."
        if sub == "reflog" and args and args[0] in {"expire", "delete"}:
            return "No gc/prune/reflog expiry: earlier attempts are kept in refs/wip/."
        if sub in {"checkout", "switch"} and re.search(r"(^|\s)(main|webview)(\s|$)", rest) \
                and " -- " not in f" {rest} ":
            return "Stay on agent/preview: main and webview are Egor's checkouts."
    return None


def check_bash(data):
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if role() in READ_ONLY_ROLES and may_write(cmd):
        deny("This session is read-only: only read commands (cat/grep/ls/git log|show|diff ...), "
             "no redirects, no builds.")
    if LIVE.search(cmd) and may_write(cmd):
        deny("This command may change Egor's trees (~/.config/nvim, ~/src/neovide, neovide-patched). "
             "Work in ~/src/preview-agent and ~/src/neovide-agent; the same git history is visible "
             "there. Commands naming those paths must be read-only (cat/grep/ls/git log|show|diff...), "
             "with no redirect.")
    reason = git_danger(cmd)
    if reason:
        deny(reason)


def main(data):
    tool = data.get("tool_name")
    if tool in EDIT_TOOLS:
        check_edit(project_root(data), data)
    elif tool == "Bash":
        check_bash(data)
    elif tool in AGENT_TOOLS:
        deny("No subagents or workflows: this session is the one worker for its step. "
             "Do the work yourself, keep the context lean (grep, read by range).")


run(main)
