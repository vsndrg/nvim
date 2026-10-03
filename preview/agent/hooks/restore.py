#!/usr/bin/env python3
"""PostToolUse(Bash): put back protected files that a shell command changed.

guard.py refuses Edit/Write up front; this catches every other way (cp, scripts,
git checkout, commits) by comparing each protected path with its baseline."""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ inside the protected directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import active, git, project_root, run  # noqa: E402


def main(data):
    root = project_root(data)
    restored = []
    for commit, label, paths in active(root):
        changed = git(root, "diff", "--name-only", commit, "--", *paths).splitlines()
        untracked = git(root, "ls-files", "--others", "--exclude-standard", "--", *paths).splitlines()
        base = set(git(root, "ls-tree", "-r", "--name-only", commit, "--", *paths).splitlines())
        back = [p for p in changed if p in base]
        extra = [p for p in changed if p not in base]
        if back:
            git(root, "checkout", commit, "--", *back)
        if extra:
            git(root, "rm", "-q", "-f", "--", *extra)
        for p in untracked:
            (root / p).unlink(missing_ok=True)
        restored += [f"{p} ({label})" for p in back + extra + untracked]
    if restored:
        sys.stderr.write(
            "Restored protected files changed by that command (working tree and index; commit "
            "the restore if the change had been committed):\n  " + "\n  ".join(restored) +
            "\nDon't change them; if one is wrong, explain why in preview/work/PENDING.md and move on.\n")
        sys.exit(2)


run(main)
