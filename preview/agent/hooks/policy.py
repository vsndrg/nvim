"""Shared policy for the agent hooks and run.py: what is protected, and since when.

Hooks fail open: an unexpected error is logged (preview/test/out/hooks.log) and the
tool call goes ahead, so a bug here can weaken a check but never stops the run.
run.py stops the run when that log is not empty (before every gate and at start)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import traceback
from pathlib import Path

PLAN = "preview/work/PLAN.md"
BRANCH = "agent/preview"
GATE_TAGS = "refs/tags/gate/"
# Files only run.py writes; agents may read them.
OWNED = ["preview/work/PLAN.md", "preview/work/PROGRESS.md", "preview/work/BLOCKED.md",
         "preview/work/STOP.md"]

# (baseline, protected prefixes, exceptions). "dir/" covers everything under it.
# A tag baseline applies once the tag exists; "@base" (merge-base of main and the
# branch) applies always. main only moves through Egor or run.py's gate merge, and
# run.py refuses that merge while the branch changes a protected path.
PDF_TESTS = ["preview/test/pdf/", "preview/test/e2e/pdf/", "preview/test/golden/pdf/",
             "preview/test/thresholds/pdf.json"]
PROTECTED = [
    ("@base", ["preview/agent/"], []),
    # The whole harness (runner, drivers, image diff, probe, fixtures, md suites) is fixed
    # at P1. Editable: unit tests, the adapter seam, and the PDF parts written later.
    ("gate/P1", ["preview/test/"],
     ["preview/test/unit/", "preview/test/adapter.lua", "preview/test/out/"] + PDF_TESTS),
    # Corpus and thresholds are fixed at P3a; scenarios stay editable in P3b (every change
    # justified in DECISIONS.md and checked by the gate review), then fixed at P3b.
    ("gate/P3a", ["preview/test/pdf/", "preview/test/thresholds/pdf.json"], []),
    ("gate/P3b", ["preview/test/e2e/pdf/", "preview/test/golden/pdf/",
                  "preview/test/adapter.lua"], []),
]


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
    return (d if d.is_absolute() else Path(root) / d).resolve()


def load_state(root, name):
    try:
        return json.loads((state_dir(root) / name).read_text())
    except (OSError, ValueError):
        return {}


def save_state(root, name, value):
    path = state_dir(root) / name
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True))
    tmp.replace(path)


def active(root, head="HEAD"):
    """[(commit, label, include, exclude)] for every protection in force."""
    out = []
    for ref, include, exclude in PROTECTED:
        if ref == "@base":
            commit, label = git(root, "merge-base", "main", head, check=False), "always"
            if not commit:
                raise RuntimeError(f"no merge-base of main and {head}: preview/agent/ unprotected")
        else:
            commit = git(root, "rev-parse", "-q", "--verify", f"refs/tags/{ref}^{{commit}}", check=False)
            label = f"since {ref}"
        if commit:
            out.append((commit, label, include, exclude))
    return out


def _under(paths, rel):
    return any(rel == p or (p.endswith("/") and rel.startswith(p)) for p in paths)


def covers(include, exclude, rel):
    return _under(include, rel) and not _under(exclude, rel)


def changed(root, commit, include, exclude, head=None):
    """Protected paths that differ between commit and head (None: the working tree)."""
    rng = [commit] if head is None else [commit, head]
    names = git(root, "diff", "--name-only", "--no-renames", *rng, "--", *include).splitlines()
    return [p for p in names if p and covers(include, exclude, p)]


def protected_changes(root, ref):
    """['path (label)'] for every protected file that `ref` changes against its baseline."""
    bad = []
    for commit, label, include, exclude in active(root, ref):
        bad += [f"{p} ({label})" for p in changed(root, commit, include, exclude, ref)]
    return bad


def log_file(root=None):
    base = root or os.environ.get("CLAUDE_PROJECT_DIR")
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
