"""Shared policy for the agent hooks: what is protected, and since when.

Hooks fail open: an unexpected error is logged (preview/test/out/hooks.log) and the
tool call goes ahead, so a bug here can weaken a check but never stops the run.
The log is on the morning checklist: anything in it means a check was skipped."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import traceback
from pathlib import Path

PLAN = "preview/work/PLAN.md"
BRANCH = "agent/preview"

# Baseline -> protected paths ("dir/" covers everything under it). A tag baseline
# applies once the tag exists; "@base" (merge-base of main and the branch) applies always.
# main only moves through Egor or the gate merge, and guard.py refuses that merge while
# the branch carries a change to a protected path, so the baseline can't be laundered.
PROTECTED = {
    "@base": ["preview/agent/"],
    "gate/P1": [
        "preview/test/run.sh",
        "preview/test/e2e/md/",
        "preview/test/golden/md/",
        "preview/test/baseline.md",
        "preview/test/thresholds/md.json",
    ],
    "gate/P3a": [
        "preview/test/pdf/",
        "preview/test/e2e/pdf/",
        "preview/test/golden/pdf/",
        "preview/test/thresholds/pdf.json",
    ],
    "gate/P3b": [
        "preview/test/adapter.lua",
    ],
}
GATE_TAGS = "refs/tags/gate/"


def git(root, *args, check=True):
    r = subprocess.run(
        ["git", "-c", "core.quotepath=off", "-C", str(root), *args],
        capture_output=True,
        text=True,
    )
    if check and r.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def project_root(data):
    start = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
    return Path(git(start, "rev-parse", "--show-toplevel")).resolve()


def state_dir(root):
    d = Path(git(root, "rev-parse", "--git-common-dir"))
    return (d if d.is_absolute() else root / d).resolve()


def load_state(root, name):
    try:
        return json.loads((state_dir(root) / name).read_text())
    except (OSError, ValueError):
        return {}


def save_state(root, name, value):
    (state_dir(root) / name).write_text(json.dumps(value, indent=1, sort_keys=True))


def active(root, head="HEAD"):
    """[(commit, label, paths)] for every protection in force."""
    out = []
    for ref, paths in PROTECTED.items():
        if ref == "@base":
            commit, label = git(root, "merge-base", "main", head, check=False), "always"
            if not commit:
                raise RuntimeError(f"no merge-base of main and {head}: preview/agent/ unprotected")
        else:
            commit = git(root, "rev-parse", "-q", "--verify", f"refs/tags/{ref}^{{commit}}", check=False)
            label = f"since {ref}"
        if commit:
            out.append((commit, label, paths))
    return out


def covers(paths, rel):
    return any(rel == p or (p.endswith("/") and rel.startswith(p)) for p in paths)


def log_file():
    base = os.environ.get("CLAUDE_PROJECT_DIR")
    if base and (Path(base) / "preview").is_dir():
        d = Path(base) / "preview/test/out"
    else:
        d = Path(os.environ.get("TMPDIR", "/tmp"))
    d.mkdir(parents=True, exist_ok=True)
    return d / "hooks.log"


def run(body):
    """Run a hook body on the JSON from stdin; on any error log it and allow."""
    try:
        body(json.load(sys.stdin))
    except SystemExit:
        raise
    except Exception:
        try:
            with open(log_file(), "a") as f:
                f.write(traceback.format_exc() + "\n")
        except OSError:
            pass
        sys.exit(0)
