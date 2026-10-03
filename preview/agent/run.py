#!/usr/bin/env python3
"""Unattended orchestrator for the preview work (see RUN.md, WORKFLOW.md).

Plain code drives the loop; Claude (`claude -p`, one fresh session per step) only does the
work of a step: implement a task, give a second opinion, review a gate. Everything that is
bookkeeping is done here, deterministically: picking the task, attempt counts, saving and
rolling back failed attempts, verifying DONE, ticking PLAN.md, gates, tags, the merge into
main, waiting out usage limits, and checking that Egor's own trees were not touched.

    cd ~/src/preview-agent && caffeinate -dims python3 preview/agent/run.py [--until 07:30]

Exit codes: 0 finished (all tasks done/blocked, or --until reached), 2 stopped (STOP.md says
why), 1 refused to start (the reason is printed)."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from datetime import datetime, timedelta
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ inside the protected directory
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "hooks"))
from policy import BRANCH, OWNED, PLAN, log_file, protected_changes  # noqa: E402
import policy  # noqa: E402

HOME = Path.home()


def env_path(name, default):
    return Path(os.environ.get(name) or default).expanduser()


NEOVIDE = env_path("PREVIEW_NEOVIDE", HOME / "src/neovide-agent")
LIVE_NVIM = env_path("PREVIEW_LIVE_NVIM", HOME / ".config/nvim")
LIVE_NEOVIDE = env_path("PREVIEW_LIVE_NEOVIDE", HOME / "src/neovide")
PATCHED = env_path("PREVIEW_PATCHED", HOME / ".local/share/neovide-patched")
CLAUDE = os.environ.get("PREVIEW_CLAUDE", "claude")
MODEL = os.environ.get("PREVIEW_MODEL", "opus")
EFFORT = os.environ.get("PREVIEW_EFFORT", "")
NEOVIDE_BRANCH = "agent/preview"
NEOVIDE_BASE = "webview"

STEP_TIMEOUT = int(os.environ.get("PREVIEW_STEP_TIMEOUT", 3 * 3600))  # one claude session
CHECK_TIMEOUT = int(os.environ.get("PREVIEW_CHECK_TIMEOUT", 3600))  # one run.sh call
MAX_TURNS = int(os.environ.get("PREVIEW_MAX_TURNS", 300))  # per session; 0 = no cap
TASK_BUDGET = float(os.environ.get("PREVIEW_TASK_BUDGET", 50))  # estimated USD per task; 0 = no cap
VERIFY_FIXES = 2          # DONE whose check failed: resume the same session this many times first
MAX_ATTEMPTS = 3          # per task; a second opinion comes before the last one
MAX_INTERRUPTS = 3        # sessions that ended without a status (crash, timeout) = 1 failed attempt
MAX_INFRA = 20            # consecutive sessions without a status (limits, outages) -> STOP
BACKOFF_MIN = [5, 10, 20, 30]
REVIEW_ROUNDS = 2         # full review, then a review of the fixes only
GATE_FIX_ROUNDS = 3       # red gate -> fix task, at most this many times per gate
MAX_FINDINGS = 6          # blocking findings that become separate tasks; the rest are batched
MIN_CLAUDE = (2, 1, 259)  # --permission-prompts

WORK = "preview/work"
RUNSH = "preview/test/run.sh"
OUT = "preview/test/out/agent"
STATE = "preview-agent-state.json"
PINS = "preview-agent-tags.json"
STATUSES = ("DONE", "FAILED", "ENV", "NEEDS-EGOR")
TOOLS = {
    "implement": "Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch",
    "review": "Bash,Read,Glob,Grep",
    "opinion": "Bash,Read,Glob,Grep",
    "selfcheck": "Bash",
}
PROMPTS = {"implement": "IMPLEMENTER.md", "review": "REVIEW.md", "opinion": "OPINION.md"}
LIMIT_RE = re.compile(r"usage limit|hit your [\w ]*limit|session limit|weekly limit|rate.?limit|"
                      r"limit (reached|exceeded)|\bresets\b|\b(429|529)\b|overloaded|high load|capacity|quota",
                      re.I)
RESUME_LIMIT = ("run.py: this session was cut off by a usage limit, which has reset now. Continue the same "
                "task where you stopped (your edits and commits are still in place), then answer as "
                "instructed, status line first.")
NUDGE = ("run.py: your last message had no status line. Answer again in the required format: the first "
         "line is exactly one of DONE, FAILED, ENV, NEEDS-EGOR.")
FIX_AFTER_DONE = ("run.py: you returned DONE, but run.py's own check failed:\n{why}\n\nFix it in place "
                  "(don't start over), run that check yourself, commit, then answer as instructed, status "
                  "line first.")
RESET_RE = re.compile(r"resets\s+(?:(\w{3})\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)", re.I)


def reset_time(text):
    """'You've hit your session limit · resets 3:45pm' -> the next such local time, or None."""
    m = RESET_RE.search(text or "")
    if not m:
        return None
    if m.group(1) or re.search(r"weekly limit", text, re.I):
        raise Stop(f"Weekly usage limit: {one_line(m.group(0))}. Start again after the reset.")
    h, mi, ap = int(m.group(2)) % 12, int(m.group(3) or 0), m.group(4).lower()
    t = datetime.now().replace(hour=h + (12 if ap == "pm" else 0), minute=mi, second=0, microsecond=0)
    return t if t > datetime.now() else t + timedelta(days=1)


class Stop(Exception):
    """End the run: write STOP.md (unless `clean`) and exit."""

    def __init__(self, reason, clean=False):
        super().__init__(reason)
        self.reason, self.clean = reason, clean


# --- small helpers ---------------------------------------------------------------------------

def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M")


def sh(cwd, *args, check=True, env=None, timeout=None):
    r = subprocess.run(list(args), cwd=str(cwd), capture_output=True, text=True,
                       env={**os.environ, **(env or {})}, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))} (in {cwd}): {r.stderr.strip()[-2000:]}")
    return r


def git(repo, *args, check=True, env=None):
    return sh(repo, "git", "-c", "core.quotepath=off", *args, check=check, env=env).stdout.strip()


def head(repo):
    return git(repo, "rev-parse", "HEAD")


def dirty(repo):
    return bool(git(repo, "status", "--porcelain", "--untracked-files=all"))


def log(msg):
    line = f"[{now()}] {msg}"
    print(line, flush=True)
    try:
        with open(ROOT / OUT / "run.log", "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def sleep_min(minutes, why):
    log(f"waiting {minutes} min: {why}")
    if not os.environ.get("PREVIEW_NO_SLEEP"):
        time.sleep(minutes * 60)


# --- PLAN.md ---------------------------------------------------------------------------------

BOX = re.compile(r"^- \[([ x!])\] (.*)$")
TASK_ID = re.compile(r"^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+$")
NEEDS = re.compile(r"\(needs ([A-Za-z0-9., ]+)\)")


class Item:
    def __init__(self, idx, box, rest):
        self.idx, self.box = idx, box
        words = rest.split(None, 1)
        self.gate = words[1].strip() if words[0] == "GATE" and len(words) > 1 else None
        if self.gate:
            self.id, self.text = f"GATE {self.gate}", rest
        else:
            self.id, self.text = words[0], words[1] if len(words) > 1 else ""
        m = NEEDS.search(self.text)
        self.needs = [x.strip() for x in m.group(1).replace(",", " ").split()] if m else []
        self.phase = self.gate  # tasks get the phase of the gate below them

    @property
    def open(self):
        return self.box == " "


def parse_plan(text):
    items = []
    for i, line in enumerate(text.splitlines()):
        m = BOX.match(line)
        if not m:
            continue
        it = Item(i, m.group(1), m.group(2))
        if it.gate or TASK_ID.match(it.id):
            items.append(it)
    phase = None
    for it in reversed(items):
        if it.gate:
            phase = it.gate
        it.phase = phase
    return items


def set_box(text, item, box):
    lines = text.splitlines()
    lines[item.idx] = f"- [{box}] " + lines[item.idx][6:]
    return "\n".join(lines) + "\n"


def insert_before(text, item, new_lines):
    lines = text.splitlines()
    lines[item.idx:item.idx] = new_lines
    return "\n".join(lines) + "\n"


def next_id(items, prefix):
    nums = [int(it.id[len(prefix):]) for it in items
            if it.id.startswith(prefix) and it.id[len(prefix):].isdigit()]
    return f"{prefix}{max(nums, default=0) + 1}"


def one_line(s, n=200):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n - 1] + "…"


# --- the run ---------------------------------------------------------------------------------

class Run:
    def __init__(self, args):
        self.args = args
        self.state = policy.load_state(ROOT, STATE)
        for k in ("attempts", "interrupts", "notes", "gatefix", "review", "gate_neovide", "task_cost"):
            self.state.setdefault(k, {})
        self.state.setdefault("infra", 0)
        self.state.setdefault("cost", 0.0)
        self.run_cost = 0.0
        self.last_cost = 0.0
        self.green = {}
        self.live = None
        self.seq = 0
        self.stopped = None
        self.deadline = None
        if args.until:
            h, m = map(int, args.until.split(":"))
            t = datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
            self.deadline = t if t > datetime.now() else t + timedelta(days=1)

    # -- state ------------------------------------------------------------------------------

    def save(self):
        policy.save_state(ROOT, STATE, self.state)

    def plan_text(self):
        return (ROOT / PLAN).read_text()

    def write(self, rel, text):
        p = ROOT / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def append(self, rel, text):
        p = ROOT / rel
        old = p.read_text() if p.exists() else ""
        if old and not old.endswith("\n"):
            old += "\n"
        self.write(rel, old + text.rstrip("\n") + "\n")

    def restore_owned(self):
        """Owned files are run.py's: undo whatever a session did to them."""
        base = self.green["nvim"]
        for rel in OWNED:
            if sh(ROOT, "git", "cat-file", "-e", f"{base}:{rel}", check=False).returncode == 0:
                git(ROOT, "checkout", base, "--", rel)
            else:
                (ROOT / rel).unlink(missing_ok=True)

    def commit(self, msg):
        """Commit everything in the worktree (state and accepted work); green = the result."""
        self.summary()
        git(ROOT, "add", "-A")
        if git(ROOT, "status", "--porcelain"):
            git(ROOT, "commit", "-q", "--no-verify", "-m", f"chore(preview-agent): {msg}")
        self.green["nvim"] = head(ROOT)
        self.green["neovide"] = head(NEOVIDE)
        self.save()

    def progress(self, line):
        self.append(f"{WORK}/PROGRESS.md", f"- {now()} {line}")

    def summary(self):
        stopped = self.stopped
        p = ROOT / WORK / "PROGRESS.md"
        old = p.read_text() if p.exists() else "# Progress\n"
        old = re.sub(r"<!-- summary -->.*?<!-- /summary -->\n*", "", old, flags=re.S)
        if not old.startswith("# "):
            old = "# Progress\n\n" + old
        items = parse_plan(self.plan_text())
        tasks = [it for it in items if not it.gate]
        done = [it for it in tasks if it.box == "x"]
        blocked = [it.id for it in tasks if it.box == "!"]
        gates = [it.gate for it in items if it.gate and it.box == "x"]
        nxt = next((it for it in items if it.open), None)
        lines = [
            "<!-- summary -->",
            f"## Summary ({now()}, written by run.py)",
            f"- Done: {len(done)} of {len(tasks)} tasks; gates passed: {', '.join(gates) or 'none'}.",
            f"- Blocked: {', '.join(blocked) or 'none'} (reasons and questions: BLOCKED.md).",
            f"- Next: {nxt.id + ' ' + one_line(nxt.text, 120) if nxt else 'nothing open'}.",
            f"- State: {('stopped: ' + one_line(stopped, 300)) if stopped else 'running or finished cleanly'}.",
            f"- Estimated spend: ${self.run_cost:.2f} this run, ${self.state['cost']:.2f} in total "
            "(client-side estimate).",
            "- For Egor: BLOCKED.md, PENDING.md, DECISIONS.md, `git log --oneline main..agent/preview`, "
            "merges left to you, the Neovide branch agent/preview -> webview, subjective smoothness.",
            "<!-- /summary -->",
            "",
        ]
        title, _, rest = old.partition("\n")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(title + "\n\n" + "\n".join(lines) + rest.lstrip("\n"))

    # -- Egor's trees ---------------------------------------------------------------------------

    def snapshot(self):
        h = hashlib.sha256()
        for repo in (LIVE_NVIM, LIVE_NEOVIDE):
            if not (repo / ".git").exists():
                continue
            e = {"GIT_OPTIONAL_LOCKS": "0"}
            h.update(str(repo).encode())
            h.update(git(repo, "rev-parse", "HEAD", "--symbolic-full-name", "HEAD", env=e).encode())
            h.update(git(repo, "status", "--porcelain", env=e).encode())
            h.update(sh(repo, "git", "diff", "HEAD", "--binary", env=e).stdout.encode())
        if PATCHED.exists():
            for p in sorted(PATCHED.rglob("*")):
                try:
                    st = p.lstat()
                except OSError:
                    continue
                h.update(f"{p}:{st.st_size}:{st.st_mtime_ns}".encode())
        return h.hexdigest()

    def check_live(self, what):
        if self.snapshot() != self.live:
            raise Stop(f"Egor's trees (~/.config/nvim, ~/src/neovide or neovide-patched) changed during "
                       f"{what}. Check `git status`/`git log` there before restarting; the run stopped so "
                       "nothing else can touch them.")

    def check_hooks_log(self):
        p = log_file(ROOT)
        if p.exists() and p.read_text().strip():
            raise Stop(f"A hook crashed (log: {p.relative_to(ROOT)}), so one of its checks was skipped. "
                       "Fix the hook, empty the log, restart.")

    # -- saving and rolling back attempts ---------------------------------------------------------

    def wip_save(self, repo, key, ref, msg):
        """Keep everything an attempt left (commits, edits, new files) under refs/wip/."""
        if head(repo) == self.green[key] and not dirty(repo):
            return None
        with tempfile.TemporaryDirectory() as d:
            e = {"GIT_INDEX_FILE": os.path.join(d, "index")}
            git(repo, "read-tree", "HEAD", env=e)
            git(repo, "add", "-A", env=e)
            tree = git(repo, "write-tree", env=e)
        commit = git(repo, "commit-tree", tree, "-p", "HEAD", "-m", msg)
        name, k = ref, 1
        while git(repo, "rev-parse", "-q", "--verify", name, check=False):
            k += 1
            name = f"{ref}-{k}"
        git(repo, "update-ref", name, commit)
        return name

    def reset(self, repo, key, branch):
        git(repo, "checkout", "-q", "-f", branch)
        git(repo, "reset", "-q", "--hard", self.green[key])
        git(repo, "clean", "-q", "-fd")

    def agent_files(self):
        """preview/work files a session may write (everything but the owned ones)."""
        out = {}
        base = ROOT / WORK
        for p in base.rglob("*") if base.exists() else []:
            rel = p.relative_to(ROOT).as_posix()
            if p.is_file() and rel not in OWNED:
                out[rel] = p.read_bytes()
        return out

    def rollback(self, tid, n, reason, note=None):
        keep = self.agent_files()
        refs = []
        for repo, key, branch in ((ROOT, "nvim", BRANCH), (NEOVIDE, "neovide", NEOVIDE_BRANCH)):
            ref = self.wip_save(repo, key, f"refs/wip/{tid}/{n}", f"wip {tid} attempt {n}: {reason}")
            if ref:
                refs.append(f"{'' if repo == ROOT else '~/src/neovide-agent '}{ref}")
            self.reset(repo, key, branch)
        for rel, data in keep.items():
            p = ROOT / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        if refs or note:
            self.append(f"{WORK}/notes/{tid}.md",
                        f"\n(run.py, {now()}) Attempt {n}: {reason}."
                        + (f" {note}" if note else "")
                        + (f" Its work is kept in {', '.join(refs)}." if refs else ""))
        self.commit(f"{tid} attempt {n}: {reason}")

    def salvage(self):
        """Before writing STOP.md: put aside whatever an unfinished step left (refs/wip/stop)."""
        keep = self.agent_files()
        refs = []
        for repo, key, branch in ((ROOT, "nvim", BRANCH), (NEOVIDE, "neovide", NEOVIDE_BRANCH)):
            ref = self.wip_save(repo, key, "refs/wip/stop", "wip left when the run stopped")
            if ref:
                log(f"{repo}: unfinished work saved in {ref}")
                refs.append(f"{'' if repo == ROOT else '~/src/neovide-agent '}{ref}")
                self.reset(repo, key, branch)
        for rel, data in keep.items():
            p = ROOT / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        self.restore_owned()
        self.drop_resume("the run stopped", refs)

    def drop_resume(self, why, refs):
        """A session waiting to be resumed can't be once the worktrees were reset: note where its work is."""
        pend = self.state.pop("resume", None)
        if not pend:
            return
        self.save()
        log(f"{pend['task']}: session {pend.get('session')} will not be resumed ({why})")
        self.append(f"{WORK}/notes/{pend['task']}.md",
                    f"\n(run.py, {now()}) Attempt {pend['n']}: {why} while its session waited to be resumed; "
                    "the next start is a fresh session." + (f" Its work is kept in {', '.join(refs)}." if refs else ""))

    # -- checks ---------------------------------------------------------------------------------

    def run_check(self, *args):
        """run.sh <args> -> (exit code, last lines of its output)."""
        path = ROOT / RUNSH
        cmd = [str(path)] if os.access(path, os.X_OK) else ["bash", str(path)]
        self.seq += 1
        out = ROOT / OUT / f"{self.seq:04d}-check-{'-'.join(args)}.log"
        try:
            r = subprocess.run(cmd + list(args), cwd=str(ROOT), capture_output=True, text=True,
                               timeout=CHECK_TIMEOUT)
            code, text = r.returncode, r.stdout + r.stderr
        except subprocess.TimeoutExpired as e:
            code, text = 124, f"timed out after {CHECK_TIMEOUT}s\n{e.stdout or ''}"
        out.write_text(text if isinstance(text, str) else text.decode(errors="replace"))
        tail = "\n".join(str(text).strip().splitlines()[-12:])
        log(f"check run.sh {' '.join(args)} -> {code}")
        self.check_live(f"run.sh {' '.join(args)}")
        return code, tail

    def last_gate(self):
        gates = [it.gate for it in parse_plan(self.plan_text()) if it.gate and it.box == "x"]
        return gates[-1] if gates else None

    def verify(self):
        """After DONE: (ok, why, env_broken)."""
        for repo, key, branch in ((ROOT, "nvim", BRANCH), (NEOVIDE, "neovide", NEOVIDE_BRANCH)):
            cur = git(repo, "rev-parse", "--abbrev-ref", "HEAD", check=False)
            if cur != branch:
                return False, f"{repo.name} is on {cur!r}, not {branch}", False
            if sh(repo, "git", "merge-base", "--is-ancestor", self.green[key], "HEAD",
                  check=False).returncode:
                return False, f"{repo.name}: history before the attempt was rewritten", False
        if dirty(NEOVIDE):
            return False, "uncommitted changes left in ~/src/neovide-agent (commit them after " \
                          "cargo test/clippy/fmt pass)", False
        if not (ROOT / RUNSH).exists():
            return True, "", False
        suites = [("fast",)]
        last = self.last_gate()
        if last and last != "P0" and not self.args.no_regression:
            suites.append(("gate", last))
        for args in suites:
            code, tail = self.run_check(*args)
            if code == 3:
                return False, f"run.sh {' '.join(args)}: environment broken\n{tail}", True
            if code:
                return False, f"`preview/test/run.sh {' '.join(args)}` exited {code}:\n{tail}", False
        return True, "", False

    # -- claude sessions --------------------------------------------------------------------------

    def system_prompt(self, role):
        out = ROOT / OUT / f"system-{role}.md"
        if role == "selfcheck":
            parts = ["Self-check of an unattended run: do exactly what the message says, nothing else."]
        else:
            parts = [(HERE / PROMPTS[role]).read_text(), (HERE / "SPEC.md").read_text()]
        out.write_text("\n\n---\n\n".join(parts))
        return out

    def claude(self, role, prompt, label, resume=None):
        """One session (fresh, or `resume`d by id). -> dict(text, error, limit, session, cutoff) where
        error means: no usable answer, and cutoff: run.py's own caps (timeout, max turns) ended it."""
        self.seq += 1
        base = ROOT / OUT / f"{self.seq:04d}-{label.replace(' ', '_')}"
        base.with_suffix(".prompt.md").write_text(prompt)
        cmd = [CLAUDE, "-p", prompt, "--output-format", "json", "--model", MODEL,
               "--permission-mode", "auto", "--permission-prompts", "none",
               "--settings", str(HERE / "settings.json"), "--add-dir", str(NEOVIDE),
               "--strict-mcp-config", "--disable-slash-commands", "--no-chrome",
               "--append-system-prompt-file", str(self.system_prompt(role)),
               "--tools", TOOLS[role], "--disallowedTools", "mcp__*"]
        if MAX_TURNS:
            cmd += ["--max-turns", str(MAX_TURNS)]
        if resume:
            cmd += ["--resume", resume]
        if EFFORT:
            cmd += ["--effort", EFFORT]
        log(f"session {label} ({role}) {'resumed from ' + resume if resume else 'started'}")
        t0 = time.time()
        timed_out = False
        proc = subprocess.Popen(cmd, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env={**os.environ, "PREVIEW_ROLE": role},
                                start_new_session=True)
        CHILDREN.add(proc)
        try:
            out, err = proc.communicate(timeout=STEP_TIMEOUT)
        except subprocess.TimeoutExpired:
            kill(proc)
            timed_out = True
            out, err = proc.communicate()
            err = f"run.py: session timed out after {STEP_TIMEOUT}s\n{err}"
        finally:
            CHILDREN.discard(proc)
        data = {}
        for line in reversed((out or "").strip().splitlines()):
            try:
                data = json.loads(line)
                break
            except ValueError:
                continue
        base.with_suffix(".json").write_text(json.dumps(
            {"exit": proc.returncode, "result": data, "stdout_tail": (out or "")[-4000:],
             "stderr": (err or "")[-4000:]}, indent=1))
        cost = float(data.get("total_cost_usd") or 0)
        self.last_cost = cost
        self.run_cost += cost
        self.state["cost"] = self.state.get("cost", 0.0) + cost
        text = data.get("result") if isinstance(data.get("result"), str) else ""
        error = proc.returncode != 0 or bool(data.get("is_error")) or not text.strip()
        cutoff = None
        if error and timed_out:
            cutoff = f"the session hit run.py's timeout ({STEP_TIMEOUT}s); keep steps shorter"
        elif error and "max_turns" in str(data.get("subtype", "")):
            cutoff = f"the session hit --max-turns {MAX_TURNS}; take a shorter path or split the work"
        limit = bool(LIMIT_RE.search(f"{text}\n{out}\n{err}")) if error and not cutoff else False
        self.reset_at = reset_time(f"{text}\n{out}\n{err}") if limit else None
        log(f"session {label} ended: exit {proc.returncode}, {time.time() - t0:.0f}s, ${cost:.2f}, "
            f"session {data.get('session_id', '?')}: {one_line(text or err, 160)}")
        return {"text": text.strip(), "error": error, "limit": limit, "cutoff": cutoff,
                "session": data.get("session_id") or None}

    def infra(self, what, limit):
        """A session ended without a usable answer: wait (limits, outages) and let the loop retry."""
        self.state["infra"] += 1
        self.save()
        k = self.state["infra"]
        if k > MAX_INFRA:
            raise Stop(f"{k - 1} sessions in a row ended without an answer (last: {what}). "
                       f"See {OUT}/run.log and the session JSON files.")
        mins = BACKOFF_MIN[min(k - 1, len(BACKOFF_MIN) - 1)] if limit or k > 1 else 1
        reset = getattr(self, "reset_at", None) if limit else None
        if reset:  # the limit says when it resets: wait for that (at most 6 h), plus a margin
            mins = max(1, min(360, int((reset - datetime.now()).total_seconds() // 60) + 3))
            self.state["infra"] = max(0, k - 1)  # a known reset time is not a failure streak
            self.save()
        sleep_min(mins, f"{what} ended without an answer{' (usage limit)' if limit else ''}")

    @staticmethod
    def status_of(text):
        for line in text.splitlines():
            m = re.match(r"^\W*(DONE|FAILED|ENV|NEEDS-EGOR)\b", line.strip())
            if m:
                return m.group(1)
        return None

    # -- steps ----------------------------------------------------------------------------------

    def block(self, item, reason, question=None):
        text = set_box(self.plan_text(), item, "!")
        self.write(PLAN, text)
        entry = f"- {item.id} {one_line(item.text, 160)}: {reason}. Notes: {WORK}/notes/{item.id}.md"
        if question:
            entry += "\n  Question: " + "\n  ".join(question.splitlines())
        self.append(f"{WORK}/BLOCKED.md", entry)
        self.progress(f"{item.id} blocked: {reason}")
        self.commit(f"{item.id} blocked")
        log(f"{item.id} blocked: {reason}")

    def notes(self, tid):
        p = ROOT / WORK / "notes" / f"{tid}.md"
        return p.read_text() if p.exists() else "(none yet)"

    def context(self):
        p = ROOT / WORK / "CONTEXT.md"
        return p.read_text() if p.exists() else "(missing)"

    def opinion(self, item):
        prompt = (f"Task {item.id}: {item.text}\n\nTwo attempts at it failed. Their notes "
                  f"({WORK}/notes/{item.id}.md):\n\n{self.notes(item.id)}\n")
        for _ in range(2):
            r = self.claude("opinion", prompt, f"{item.id}-opinion")
            self.charge(item.id)
            self.check_live(f"the second opinion on {item.id}")
            if not r["error"]:
                self.state["infra"] = 0
                return "\n".join(r["text"].splitlines()[:12])
            if r["limit"]:
                self.infra(f"second opinion on {item.id}", True)
        return None

    def charge(self, tid):
        self.state["task_cost"][tid] = self.state["task_cost"].get(tid, 0.0) + self.last_cost

    def failed(self, item, n, text, note=None):
        """The attempt failed: save its work, reset, and block the task after the last attempt."""
        st = self.state
        st["attempts"][item.id] = n
        st["interrupts"][item.id] = 0
        st["notes"][item.id] = one_line(text, 1500)
        self.rollback(item.id, n, "failed", note)
        if n >= MAX_ATTEMPTS:
            self.block(item, f"{MAX_ATTEMPTS} attempts failed")

    def task(self, item):
        items = {it.id: it for it in parse_plan(self.plan_text())}
        dead = [x for x in item.needs if x in items and items[x].box == "!"]
        st = self.state
        pend = st.pop("resume", None)
        if pend and pend.get("task") != item.id:  # shouldn't happen: start() and salvage() drop it
            self.rollback(pend["task"], pend["n"], f"the plan moved on to {item.id} before its session "
                          "was resumed")
            pend = None
        if dead and not pend:
            return self.block(item, f"depends on blocked {', '.join(dead)}")
        spent = st["task_cost"].get(item.id, 0.0)
        if TASK_BUDGET and spent >= TASK_BUDGET:
            n = pend["n"] if pend else max(st["attempts"].get(item.id, 0), 1)
            st["task_cost"].pop(item.id, None)  # a reopened task gets a fresh budget
            self.rollback(item.id, n, f"estimated spend reached {TASK_BUDGET:g} USD")
            return self.block(item, f"estimated spend for this task reached {spent:.2f} USD "
                                    f"(PREVIEW_TASK_BUDGET={TASK_BUDGET:g})")
        resumed = pend is not None
        if resumed:
            n = pend["n"]
            r = self.claude("implement", pend["prompt"], f"{item.id}-a{n}-{pend['why']}", resume=pend["session"])
        else:
            n = st["attempts"].get(item.id, 0) + 1
            if n > MAX_ATTEMPTS:  # Egor reopened it: a fresh cap
                log(f"{item.id} reopened: attempts reset")
                st["attempts"][item.id], st["interrupts"][item.id], n = 0, 0, 1
            second = self.opinion(item) if n == MAX_ATTEMPTS else None
            prompt = "\n".join(filter(None, [
                f"Task {item.id}: {item.text}",
                f"Attempt {n} of {MAX_ATTEMPTS}. Notes file: {WORK}/notes/{item.id}.md",
                f"Work from: {BRANCH} at {self.green['nvim'][:12]} (this worktree) and "
                f"{NEOVIDE_BRANCH} at {self.green['neovide'][:12]} (~/src/neovide-agent).",
                st["notes"].get(item.id) and f"Previous attempt: {st['notes'][item.id]}",
                second and f"Second opinion (start by checking its assumptions):\n{second}",
                f"\n## {WORK}/CONTEXT.md\n\n{self.context()}",
                f"\n## {WORK}/notes/{item.id}.md\n\n{self.notes(item.id)}",
            ]))
            r = self.claude("implement", prompt, f"{item.id}-a{n}")
            pend = {"task": item.id, "n": n, "fixes": 0, "nudged": False}
        self.charge(item.id)
        pend["session"] = r["session"] or pend.get("session")
        self.check_live(f"{item.id} attempt {n}")
        self.check_hooks_log()
        if r["cutoff"]:  # run.py's own caps: a failed attempt, not an interruption to retry
            return self.failed(item, n, r["cutoff"], r["cutoff"])
        status = None if r["error"] else self.status_of(r["text"])
        if status is None:
            if r["limit"] and pend["session"]:  # keep the worktrees as they are and resume after the reset
                pend.update(prompt=RESUME_LIMIT, why="resume")
                st["resume"] = pend
                return self.infra(f"{item.id} attempt {n}", True)
            if not r["error"] and pend["session"] and not pend["nudged"]:  # answered, but no status line
                pend.update(prompt=NUDGE, why="status", nudged=True)
                st["resume"] = pend
                self.save()
                return
            if resumed and r["error"] and not r["limit"]:  # the resume itself failed: start afresh
                self.rollback(item.id, n, "its session could not be resumed; started afresh")
                return
            interrupted = "limit" if r["limit"] else "no status"
            if not r["limit"]:
                st["interrupts"][item.id] = st["interrupts"].get(item.id, 0) + 1
            if st["interrupts"].get(item.id, 0) >= MAX_INTERRUPTS:
                st["interrupts"][item.id] = 0
                st["attempts"][item.id] = n
                self.rollback(item.id, n, f"ended without a status {MAX_INTERRUPTS} times",
                              "Counted as one failed attempt (crash or timeout: keep steps shorter).")
                if n >= MAX_ATTEMPTS:
                    self.block(item, f"{MAX_ATTEMPTS} attempts failed")
                self.state["infra"] = 0
                return
            self.rollback(item.id, n, f"interrupted ({interrupted}); retried")
            return self.infra(f"{item.id} attempt {n}", r["limit"])
        st["infra"] = 0
        st["interrupts"][item.id] = 0
        if status == "ENV":
            self.rollback(item.id, n, "environment broken", one_line(r["text"], 600))
            raise Stop(f"{item.id} attempt {n} found the environment broken:\n{r['text']}")
        if status == "NEEDS-EGOR":
            self.rollback(item.id, n, "needs Egor")
            return self.block(item, "needs a decision from Egor", question=r["text"])
        if status == "DONE":
            ok, why, env_broken = self.verify()
            if ok:
                st["notes"].pop(item.id, None)
                st["task_cost"].pop(item.id, None)
                self.restore_owned()
                self.write(PLAN, set_box(self.plan_text(), item, "x"))
                self.progress(f"{item.id} done (attempt {n}): {one_line(r['text'], 200)}")
                self.commit(f"{item.id} done")
                log(f"{item.id} done")
                return
            if env_broken:
                self.rollback(item.id, n, "environment broken during the DONE check", one_line(why, 600))
                raise Stop(f"The check after {item.id} found the environment broken:\n{why}")
            if pend["session"] and pend["fixes"] < VERIFY_FIXES:  # the session has the context: let it fix
                pend["fixes"] += 1
                pend.update(prompt=FIX_AFTER_DONE.format(why=why), why=f"fix{pend['fixes']}")
                st["resume"] = pend
                self.save()
                log(f"{item.id}: the check after DONE failed; resuming the session to fix it "
                    f"({pend['fixes']}/{VERIFY_FIXES})")
                return
            r["text"] = f"returned DONE, but {why}"
        self.failed(item, n, r["text"], None if status == "FAILED" else one_line(r["text"], 800))

    # -- gates ----------------------------------------------------------------------------------

    def gate(self, item):
        phase = item.gate
        items = parse_plan(self.plan_text())
        mine = [it for it in items if it.phase == phase and not it.gate]
        blocked = [it.id for it in mine if it.box == "!"]
        if blocked:
            raise Stop(f"GATE {phase} blocked: {', '.join(blocked)} (BLOCKED.md). A phase never starts "
                       "without the previous gate.")
        self.check_hooks_log()
        if (ROOT / RUNSH).exists():
            code, tail = self.run_check("gate", phase)
            if code == 3:
                raise Stop(f"run.sh gate {phase}: environment broken\n{tail}")
            if code:
                k = self.state["gatefix"].get(phase, 0) + 1
                self.state["gatefix"][phase] = k
                if k > GATE_FIX_ROUNDS:
                    raise Stop(f"GATE {phase} still red after {GATE_FIX_ROUNDS} fix tasks:\n{tail}")
                tid = next_id(items, f"{phase}.F")
                first = one_line(tail.splitlines()[0] if tail else f"exit {code}", 160)
                self.write(PLAN, insert_before(self.plan_text(), item, [
                    f"- [ ] {tid} Fix gate {phase}: make `preview/test/run.sh gate {phase}` pass "
                    f"(first failure: {first})"]))
                self.append(f"{WORK}/notes/{tid}.md", f"# {tid}\n\nrun.sh gate {phase} exited {code}:\n\n"
                            f"```\n{tail}\n```")
                self.commit(f"GATE {phase} red: {tid}")
                return
        else:
            checks = [it for it in mine if re.match(rf"^{re.escape(phase)}\.C\d+$", it.id)]
            if not checks:
                tid = f"{phase}.C1"
                self.write(PLAN, insert_before(self.plan_text(), item, [
                    f"- [ ] {tid} Gate check: the build passes and every {phase} deliverable above "
                    "exists and works; fix small gaps, return FAILED for big ones"]))
                self.commit(f"GATE {phase}: check task")
                return
        rv = self.state["review"].setdefault(phase, {"round": 0})
        if rv["round"] < REVIEW_ROUNDS and self.review(item, rv):
            return
        self.finish_gate(item)

    def review(self, item, rv):
        """-> True when it inserted fix tasks (or must be retried)."""
        phase, r = item.gate, rv["round"] + 1
        if r == 1:
            prev = [it.gate for it in parse_plan(self.plan_text()) if it.gate and it.box == "x"]
            base = (git(ROOT, "rev-parse", f"refs/tags/gate/{prev[-1]}^{{commit}}", check=False)
                    if prev else "") or git(ROOT, "merge-base", "main", "HEAD")
            nbase = (self.state["gate_neovide"].get(prev[-1]) if prev else None) or \
                git(NEOVIDE, "merge-base", NEOVIDE_BASE, "HEAD", check=False) or head(NEOVIDE)
            extra = ""
        else:
            base, nbase = rv["fixbase"], rv["nfixbase"]
            extra = ("This is the follow-up review. It covers only the fixes for these findings of the "
                     "first review; check each is really fixed and the fixes add no new blocking "
                     "problem:\n" + "\n".join(rv.get("findings", [])) + "\n")
        prompt = (f"Gate {phase}, review round {r} of {REVIEW_ROUNDS}.\n"
                  f"Range in this worktree: {base}..HEAD\n"
                  f"Range in ~/src/neovide-agent: {nbase}..HEAD\n{extra}")
        res = self.claude("review", prompt, f"GATE-{phase}-review{r}")
        self.check_live(f"the review of {phase}")
        self.check_hooks_log()
        text = "" if res["error"] else res["text"]
        blocking = [one_line(m, 400) for m in re.findall(r"^\W*BLOCKING:\s*(.+)$", text, re.M)]
        minor = [one_line(m, 400) for m in re.findall(r"^\W*MINOR:\s*(.+)$", text, re.M)]
        clean = re.search(r"^\W*NO FINDINGS\b", text, re.M)
        key = f"GATE {phase}"
        if not (blocking or minor or clean):
            if res["limit"]:
                self.infra(f"review of {phase}", True)
                return True
            k = self.state["interrupts"].get(key, 0) + 1
            self.state["interrupts"][key] = k
            if k < MAX_INTERRUPTS:
                self.save()
                self.infra(f"review of {phase}", False)
                return True
            self.append(f"{WORK}/PENDING.md", f"- GATE {phase}: review round {r} gave no usable answer "
                        f"{k} times; the gate passed on its tests alone. Review it yourself.")
            rv["round"] = REVIEW_ROUNDS
            self.commit(f"GATE {phase}: review skipped")
            return False
        self.state["infra"] = 0
        self.state["interrupts"][key] = 0
        if minor:
            self.append(f"{WORK}/PENDING.md", f"\n## GATE {phase}, review {r}: minor findings\n" +
                        "\n".join(f"- {m}" for m in minor))
        rv["round"] = r
        if blocking:
            items = parse_plan(self.plan_text())
            lines, first = [], next_id(items, f"{phase}.R")
            n0 = int(first[len(phase) + 2:])
            for i, f in enumerate(blocking[:MAX_FINDINGS]):
                lines.append(f"- [ ] {phase}.R{n0 + i} Fix: {f}")
            if len(blocking) > MAX_FINDINGS:
                tid = f"{phase}.R{n0 + MAX_FINDINGS}"
                lines.append(f"- [ ] {tid} Fix the remaining review findings listed in {WORK}/notes/{tid}.md")
                self.append(f"{WORK}/notes/{tid}.md", f"# {tid}\n\nFindings of review {r} of GATE {phase}:\n" +
                            "\n".join(f"- {f}" for f in blocking[MAX_FINDINGS:]))
            self.write(PLAN, insert_before(self.plan_text(), item, lines))
            rv["findings"] = blocking
            rv["fixbase"], rv["nfixbase"] = self.green["nvim"], self.green["neovide"]
            self.progress(f"GATE {phase} review {r}: {len(blocking)} blocking, {len(minor)} minor")
            if r == REVIEW_ROUNDS:
                self.append(f"{WORK}/PENDING.md", f"- GATE {phase}: the fixes for review {r} are not "
                            "reviewed again (only tested). Look at them.")
            self.commit(f"GATE {phase} review {r}: {len(blocking)} findings")
            return True
        self.progress(f"GATE {phase} review {r}: no blocking findings")
        self.commit(f"GATE {phase} review {r} clean")
        return False

    def finish_gate(self, item):
        phase = item.gate
        self.restore_owned()
        self.write(PLAN, set_box(self.plan_text(), item, "x"))
        self.progress(f"GATE {phase} passed")
        self.commit(f"GATE {phase} passed")
        tag = f"gate/{phase}"
        git(ROOT, "tag", "-a", tag, "-m", f"gate {phase}")
        pins = policy.load_state(ROOT, PINS)
        pins[f"refs/tags/{tag}"] = git(ROOT, "rev-parse", f"refs/tags/{tag}")
        policy.save_state(ROOT, PINS, pins)
        self.state["gate_neovide"][phase] = head(NEOVIDE)
        self.save()
        log(f"GATE {phase} passed, tagged {tag}")
        bad = protected_changes(ROOT, BRANCH)
        ahead = git(NEOVIDE, "rev-list", "--count", f"{NEOVIDE_BASE}..{NEOVIDE_BRANCH}", check=False)
        if bad:
            why = "the branch changes protected files: " + ", ".join(bad)
        elif ahead not in ("", "0"):
            why = (f"~/src/neovide-agent has {ahead} commit(s) on {NEOVIDE_BRANCH} that are not in "
                   f"{NEOVIDE_BASE}, so the config may need a Neovide you haven't installed yet. Merge them "
                   f"into {NEOVIDE_BASE} and install first, then merge {BRANCH} into main")
        else:
            r = sh(LIVE_NVIM, "git", "merge", "--ff-only", BRANCH, check=False)
            why = None if r.returncode == 0 else one_line(r.stderr or r.stdout, 400)
            self.live = self.snapshot()
        if why:
            self.append(f"{WORK}/BLOCKED.md", f"- GATE {phase}: merge of {BRANCH} into main left to Egor: {why}")
            self.progress(f"GATE {phase}: merge into main left to Egor")
        else:
            self.progress(f"GATE {phase}: {BRANCH} merged into main (~/.config/nvim)")
        self.commit(f"GATE {phase} merge")

    # -- start ----------------------------------------------------------------------------------

    def start(self):
        (ROOT / OUT).mkdir(parents=True, exist_ok=True)
        if (ROOT / WORK / "STOP.md").exists():
            raise Stop(f"{WORK}/STOP.md exists: fix its cause, delete it, then start again.", clean=True)
        self.preflight()
        # Egor's morning edits (PLAN.md, notes answers) are kept; anything else a crashed
        # session left is saved under refs/wip/ and dropped.
        if git(ROOT, "status", "--porcelain", "--untracked-files=all", "--", WORK):
            git(ROOT, "add", "-A", "--", WORK)
            git(ROOT, "commit", "-q", "--no-verify", "-m", "chore(preview-agent): edits to preview/work")
        self.green = {"nvim": head(ROOT), "neovide": head(NEOVIDE)}
        refs = []
        for repo, key, branch in ((ROOT, "nvim", BRANCH), (NEOVIDE, "neovide", NEOVIDE_BRANCH)):
            if git(repo, "rev-parse", "--abbrev-ref", "HEAD") != branch:
                raise Stop(f"{repo} is not on {branch}.", clean=True)
            ref = self.wip_save(repo, key, "refs/wip/startup", "wip left by an interrupted run")
            if ref:
                log(f"{repo}: leftovers of an interrupted run saved in {ref}")
                refs.append(f"{'' if repo == ROOT else '~/src/neovide-agent '}{ref}")
                self.reset(repo, key, branch)
        if self.state.get("resume"):
            self.drop_resume("the run was restarted", refs)
            self.commit("note on a session that was not resumed")
        r = sh(ROOT, "git", "merge", "--no-edit", "-q", "main", check=False)
        if r.returncode:
            sh(ROOT, "git", "merge", "--abort", check=False)
            raise Stop(f"`git merge main` conflicts in {ROOT}: resolve it, commit, start again.", clean=True)
        self.green = {"nvim": head(ROOT), "neovide": head(NEOVIDE)}
        self.live = self.snapshot()
        self.selfcheck()
        if (ROOT / RUNSH).exists():
            code, tail = self.run_check("env")
            if code:
                raise Stop(f"run.sh env exited {code}: the environment is not ready\n{tail}", clean=True)
            code, tail = self.run_check("fast")
            items = parse_plan(self.plan_text())
            first = next((it for it in items if it.open), None)
            if code and first and not first.id.startswith("X.F"):
                tid = next_id(items, "X.F")
                self.write(PLAN, insert_before(self.plan_text(), first, [
                    f"- [ ] {tid} Fix: `preview/test/run.sh fast` is red at the start of the run "
                    f"(first failure: {one_line(tail.splitlines()[0] if tail else code, 160)})"]))
                self.commit(f"{tid}: run.sh fast red at start")
        self.save()

    def preflight(self):
        out = sh(ROOT, CLAUDE, "--version", check=False).stdout
        m = re.search(r"(\d+)\.(\d+)\.(\d+)", out)
        if not m or tuple(map(int, m.groups())) < MIN_CLAUDE:
            raise Stop(f"Claude Code {'.'.join(map(str, MIN_CLAUDE))}+ is needed (have: {out.strip() or '?'}); "
                       "run `claude update`.", clean=True)
        if not NEOVIDE.is_dir():
            raise Stop(f"{NEOVIDE} is missing (RUN.md, setup step 4).", clean=True)
        if not os.environ.get("PREVIEW_SKIP_HOOK_TESTS"):
            r = sh(HERE / "hooks", sys.executable, "-B", "test_hooks.py", check=False)
            if r.returncode:
                raise Stop("Hook tests fail:\n" + "\n".join((r.stdout + r.stderr).splitlines()[-20:]),
                           clean=True)
        self.check_hooks_log()

    def selfcheck(self):
        """Same flags as a real step: login, flags, auto mode letting a shell command through."""
        for _ in range(MAX_INFRA):
            r = self.claude("selfcheck", "Self-check. Run `git rev-parse --abbrev-ref HEAD` with the Bash "
                            "tool, then reply with exactly one line: OK <its output>", "selfcheck")
            if not r["error"] and f"OK {BRANCH}" in r["text"]:
                self.state["infra"] = 0
                return
            if not r["limit"]:
                raise Stop(f"Self-check failed: `claude -p` with the run's flags did not answer "
                           f"'OK {BRANCH}'. Got: {one_line(r['text'], 400)}. Session JSON: {OUT}/.",
                           clean=True)
            self.infra("self-check", True)

    # -- loop -----------------------------------------------------------------------------------

    def loop(self):
        while True:
            if self.deadline and datetime.now() >= self.deadline:
                raise Stop(f"--until {self.args.until} reached", clean=True)
            item = next((it for it in parse_plan(self.plan_text()) if it.open), None)
            if item is None:
                raise Stop("every task is done or blocked", clean=True)
            if item.gate:
                self.gate(item)
            else:
                self.task(item)


CHILDREN = set()


def kill(proc):
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            proc.wait(timeout=30)
            return
        except subprocess.TimeoutExpired:
            continue


def on_signal(signum, _frame):
    for p in list(CHILDREN):
        kill(p)
    log(f"signal {signum}: stopped; the next start saves what the session left in refs/wip/startup")
    sys.exit(130)


def main():
    global ROOT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--until", metavar="HH:MM", help="start no new step after this time")
    ap.add_argument("--no-regression", action="store_true",
                    help="after DONE run only `run.sh fast`, not the suites of the last passed gate")
    ap.add_argument("--check", action="store_true", help="preflight and self-check only, then exit")
    args = ap.parse_args()
    try:
        ROOT = Path(git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
    except RuntimeError:
        print("run.py: start it inside ~/src/preview-agent", file=sys.stderr)
        return 1
    if git(ROOT, "rev-parse", "--abbrev-ref", "HEAD") != BRANCH or ROOT == LIVE_NVIM.resolve():
        print(f"run.py: start it in the agent worktree (branch {BRANCH}), not in ~/.config/nvim",
              file=sys.stderr)
        return 1
    lock = open(policy.state_dir(ROOT) / "preview-agent.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("run.py: another run is active", file=sys.stderr)
        return 1
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGHUP, on_signal)
    run = Run(args)
    try:
        if args.check:
            (ROOT / OUT).mkdir(parents=True, exist_ok=True)
            run.preflight()
            run.green = {"nvim": head(ROOT), "neovide": head(NEOVIDE)}
            run.selfcheck()
            print("run.py: preflight and self-check passed")
            return 0
        run.start()
        run.loop()
    except Stop as s:
        return finish(run, s.reason, s.clean)
    except Exception:  # a bug or an unexpected git/OS failure: stop like any other STOP, never silently
        tb = traceback.format_exc()
        log(tb.rstrip())
        return finish(run, "run.py crashed (a bug or an unexpected git/OS failure):\n\n```\n"
                      + tb[-3000:].rstrip() + "\n```", False)
    return 0


def finish(run, reason, clean):
    log(f"stop: {one_line(reason, 300)}")
    finished = clean and reason.startswith(("every task", "--until"))
    if clean and "STOP.md exists" in reason:
        return 1
    stop = f"# Stopped {now()}\n\n{reason}\n"
    if not clean:  # first, so that STOP.md exists even when saving the work below fails
        try:
            run.write(f"{WORK}/STOP.md", stop)
        except OSError as e:
            log(f"could not write STOP.md: {e}")
    if run.green:
        try:
            run.salvage()  # restores run.py's own files, STOP.md included: write it again
            if not clean:
                run.write(f"{WORK}/STOP.md", stop)
            run.stopped = None if finished else reason
            run.commit("stop" if not clean else "end of run")
        except Exception as e:
            log(f"saving the work after the stop failed: {e}")
            if not clean:
                try:
                    run.append(f"{WORK}/STOP.md", f"\nSaving the work after the stop failed too: {one_line(e, 600)}. "
                               "The worktrees may be dirty; the next start saves leftovers in refs/wip/startup.")
                except OSError:
                    pass
    return 0 if finished else (1 if clean else 2)


ROOT = Path.cwd()

if __name__ == "__main__":
    sys.exit(main())
