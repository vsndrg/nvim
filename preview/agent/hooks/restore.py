#!/usr/bin/env python3
"""PostToolUse(Bash): put back gate tags and protected files that a shell command changed.

guard.py refuses edits and the obvious commands up front; this catches every other way
(cp, scripts, git checkout, commits, tag moves) by comparing with the baselines."""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ inside the protected directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import GATE_TAGS, active, changed, covers, git, load_state, project_root, run, save_state  # noqa: E402

PINS = "preview-agent-tags.json"


def pin_tags(root):
    """A gate tag is pinned the first time a hook sees it; a moved or deleted one is put back.
    Egor moves a tag on purpose by also deleting the pins file (see RUN.md)."""
    pins = load_state(root, PINS)
    now = dict(line.split(" ", 1) for line in
               git(root, "for-each-ref", "--format=%(refname) %(objectname)", GATE_TAGS).splitlines()
               if line)
    fixed = []
    for ref, sha in pins.items():
        if now.get(ref) != sha:
            git(root, "update-ref", ref, sha)
            fixed.append(f"{ref[len('refs/tags/'):]} (tag moved or deleted)")
    if any(ref not in pins for ref in now):
        save_state(root, PINS, {**now, **pins})
    return fixed


def restore_files(root):
    restored = []
    for commit, label, include, exclude in active(root):
        diff = changed(root, commit, include, exclude)
        untracked = [p for p in git(root, "ls-files", "--others", "--exclude-standard", "--",
                                    *include).splitlines() if p and covers(include, exclude, p)]
        base = set(git(root, "ls-tree", "-r", "--name-only", commit, "--", *include).splitlines())
        back = [p for p in diff if p in base]
        extra = [p for p in diff if p not in base]
        if back:
            git(root, "checkout", commit, "--", *back)
        if extra:
            git(root, "rm", "-q", "-f", "--ignore-unmatch", "--", *extra)
        for p in untracked:
            (root / p).unlink(missing_ok=True)
        restored += [f"{p} ({label})" for p in back + extra + untracked]
    return restored


def main(data):
    root = project_root(data)
    restored = pin_tags(root) + restore_files(root)
    if restored:
        sys.stderr.write(
            "Restored protected tags/files changed by that command (working tree and index; commit "
            "the restore if the change had been committed):\n  " + "\n  ".join(restored) +
            "\nDon't change them; if one is wrong, explain why in preview/work/PENDING.md and move on. "
            "Build outputs and test artifacts belong in preview/test/out/.\n")
        sys.exit(2)


run(main)
