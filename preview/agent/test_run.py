#!/usr/bin/env python3
"""End-to-end tests for run.py against a fake `claude` and throwaway repos:
python3 preview/agent/test_run.py"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

AGENT = Path(__file__).resolve().parent
PREVIEW = AGENT.parent

FAKE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
if sys.argv[1:2] == ["--version"]:
    print("2.1.300 (Claude Code)"); sys.exit(0)
prompt = sys.argv[sys.argv.index("-p") + 1]
role = os.environ.get("PREVIEW_ROLE")
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({"role": role, "prompt": prompt,
                        "resume": sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else None,
                        "max_turns": "--max-turns" in sys.argv}) + "\n")
if prompt.startswith("Self-check"):
    branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
    print(json.dumps({"type": "result", "is_error": False, "result": "OK " + branch, "total_cost_usd": 0.01}))
    sys.exit(0)
steps = json.load(open(os.environ["FAKE_SCENARIO"]))
pos_file = os.environ["FAKE_SCENARIO"] + ".pos"
pos = int(open(pos_file).read()) if os.path.exists(pos_file) else 0
open(pos_file, "w").write(str(pos + 1))
if pos >= len(steps):
    print(json.dumps({"type": "result", "is_error": True, "result": "fake: scenario exhausted"})); sys.exit(1)
step = steps[pos]
if step.get("role") and step["role"] != role:
    print(json.dumps({"type": "result", "is_error": True, "result": f"fake: expected {step['role']}, got {role}"}))
    sys.exit(1)
if step.get("sh"):
    subprocess.run(["bash", "-ec", step["sh"]], check=True)
print(json.dumps({"type": "result", "is_error": step.get("is_error", False), "result": step.get("result", ""),
                  "subtype": step.get("subtype", "success"), "total_cost_usd": 0.5, "session_id": f"s{pos}"}))
sys.exit(step.get("exit", 0))
'''

RUNSH = '''#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)/out"; mkdir -p "$d"
f="$d/rc-$1"; if [ -f "$f" ]; then echo "fake run.sh $1: failing on purpose"; exit "$(cat "$f")"; fi
exit 0
'''

GITENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
          "GIT_COMMITTER_EMAIL": "t@t"}


def sh(cwd, *args):
    r = subprocess.run(list(args), cwd=str(cwd), capture_output=True, text=True, env={**os.environ, **GITENV})
    if r.returncode:
        raise RuntimeError(f"{args}: {r.stderr}")
    return r.stdout.strip()


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.t = Path(self.tmp.name).resolve()
        live = self.live = t / "nvim"
        (live / "preview").mkdir(parents=True)
        shutil.copytree(AGENT, live / "preview/agent",
                        ignore=shutil.ignore_patterns("__pycache__", "test_run.py"))
        (live / "preview/work").mkdir()
        (live / "preview/work/CONTEXT.md").write_text("# Context\n")
        (live / "preview/.gitignore").write_text("test/out/\nnode_modules/\ndist/\n")
        (live / "init.lua").write_text("-- egor\n")
        sh(live, "git", "init", "-q", "-b", "main")
        self.wt = t / "preview-agent"
        nv = self.nv_live = t / "neovide"
        nv.mkdir()
        (nv / "main.rs").write_text("fn main() {}\n")
        sh(nv, "git", "init", "-q", "-b", "webview")
        sh(nv, "git", "add", "-A")
        sh(nv, "git", "commit", "-qm", "init")
        self.nv = t / "neovide-agent"
        sh(nv, "git", "worktree", "add", "-q", str(self.nv), "-b", "agent/preview")
        self.patched = t / "patched"
        self.patched.mkdir()
        (self.patched / "neovide").write_text("bin\n")
        fake = t / "fake-claude"
        fake.write_text(FAKE)
        fake.chmod(0o755)
        self.log = t / "calls.jsonl"
        self.scenario = t / "scenario.json"

    def tearDown(self):
        self.tmp.cleanup()

    def init(self, plan, runsh=False):
        (self.live / "preview/work/PLAN.md").write_text("# Plan\n\n" + textwrap.dedent(plan))
        if runsh:
            p = self.live / "preview/test/run.sh"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(RUNSH)
            p.chmod(0o755)
        sh(self.live, "git", "add", "-A")
        sh(self.live, "git", "commit", "-qm", "init")
        sh(self.live, "git", "worktree", "add", "-q", str(self.wt), "-b", "agent/preview")

    def run_py(self, steps, *args, env_extra=None):
        self.scenario.write_text(json.dumps(steps))
        env = {**(env_extra or {}), **os.environ, **GITENV, "PREVIEW_NEOVIDE": str(self.nv), "PREVIEW_LIVE_NVIM": str(self.live),
               "PREVIEW_LIVE_NEOVIDE": str(self.nv_live), "PREVIEW_PATCHED": str(self.patched),
               "PREVIEW_CLAUDE": str(self.t / "fake-claude"), "PREVIEW_NO_SLEEP": "1",
               "PREVIEW_SKIP_HOOK_TESTS": "1", "FAKE_LOG": str(self.log), "FAKE_SCENARIO": str(self.scenario)}
        r = subprocess.run([sys.executable, "-B", "preview/agent/run.py", *args], cwd=str(self.wt),
                           capture_output=True, text=True, env=env, timeout=300)
        self.output = r.stdout + r.stderr
        return r.returncode

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def work(self, name):
        p = self.wt / "preview/work" / name
        return p.read_text() if p.exists() else ""

    def rc(self, mode, code):
        d = self.wt / "preview/test/out"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"rc-{mode}").write_text(str(code))

    def ref(self, repo, name):
        return subprocess.run(["git", "-C", str(repo), "rev-parse", "-q", "--verify", name],
                              capture_output=True, text=True).stdout.strip()

    def clean(self, repo):
        return sh(repo, "git", "status", "--porcelain") == ""

    # ---------------------------------------------------------------------------------------

    def test_happy_path_gates_review_merge(self):
        self.init("""\
            - [ ] P0.1 first
            - [ ] P0.2 second (needs P0.1)
            - [ ] GATE P0

            - [ ] P1.1 harness
            - [ ] GATE P1
            """)
        steps = [
            {"role": "implement", "sh": "echo a > a.txt; git add a.txt; git commit -qm a", "result": "DONE\nadded a"},
            # leaves a file uncommitted and tampers with PLAN.md: run.py commits the one, undoes the other
            {"role": "implement", "sh": "echo l > l.txt; perl -pi -e 's/- \\[ \\] GATE P0/- [x] GATE P0/' preview/work/PLAN.md;"
                                        "cd $PREVIEW_NEOVIDE && echo '// x' >> main.rs && git commit -qam nv",
             "result": "**DONE**"},
            {"role": "implement", "result": "DONE\ncheck ok"},               # P0.C1
            {"role": "review", "result": "NO FINDINGS"},
            {"role": "implement", "sh": "mkdir -p preview/test && printf '%s' \"$RUNSH\" > preview/test/run.sh;"
                                        "chmod +x preview/test/run.sh; git add -A; git commit -qm runsh",
             "result": "DONE"},
            {"role": "review", "result": "BLOCKING: hack in x, a.txt (symptom fix)\nMINOR: name, b"},
            {"role": "implement", "sh": "echo fixed > a.txt; git commit -qam fix", "result": "DONE"},  # P1.R1
            {"role": "review", "result": "NO FINDINGS"},
        ]
        os.environ["RUNSH"] = RUNSH
        main_before = sh(self.live, "git", "rev-parse", "main")
        try:
            code = self.run_py(steps)
        finally:
            del os.environ["RUNSH"]
        self.assertEqual(code, 0, self.output)
        plan = self.work("PLAN.md")
        self.assertNotIn("- [ ]", plan)
        self.assertNotIn("- [!]", plan)
        self.assertIn("- [x] P0.C1 Gate check", plan)
        self.assertIn("- [x] P1.R1 Fix: hack in x, a.txt (symptom fix)", plan)
        self.assertTrue(self.ref(self.wt, "refs/tags/gate/P0"))
        self.assertTrue(self.ref(self.wt, "refs/tags/gate/P1"))
        self.assertEqual(sh(self.wt, "git", "ls-files", "l.txt"), "l.txt")
        # P0.2 committed in Neovide: no gate merge into Egor's main until he merges that into webview
        self.assertEqual(sh(self.live, "git", "rev-parse", "main"), main_before)
        self.assertIn("1 commit(s) on agent/preview that are not in webview", self.work("BLOCKED.md"))
        self.assertTrue(self.ref(self.wt, "refs/tags/gate/P1"))
        self.assertIn("MINOR: name, b".split(": ", 1)[1], self.work("PENDING.md"))
        self.assertTrue(self.work("PROGRESS.md").startswith("# Progress\n\n<!-- summary -->"))
        self.assertIn("Done: 5 of 5 tasks; gates passed: P0, P1", self.work("PROGRESS.md"))
        reviews = [c for c in self.calls() if c["role"] == "review"]
        self.assertIn("follow-up", reviews[-1]["prompt"])
        self.assertIn("hack in x", reviews[-1]["prompt"])
        first = [c for c in self.calls() if c["role"] == "implement"][0]["prompt"]
        self.assertIn("Task P0.1: first", first)
        self.assertIn("# Context", first)
        self.assertTrue(self.clean(self.wt) and self.clean(self.nv))

    def test_failures_rollback_opinion_blocks(self):
        self.init("""\
            - [ ] P0.1 hard
            - [ ] P0.2 later (needs P0.1)
            - [ ] P0.3 ask
            - [ ] GATE P0
            """)
        notes = "mkdir -p preview/work/notes; echo '{}' >> preview/work/notes/P0.1.md"
        steps = [
            {"role": "implement", "sh": "echo x > x.txt; " + notes.format("tried A"), "result": "FAILED\nA"},
            {"role": "implement", "sh": "echo y > y.txt; git add y.txt; git commit -qm y; cd $PREVIEW_NEOVIDE; "
                                        "echo z > z.rs; cd -; " + notes.format("tried B"), "result": "FAILED\nB"},
            {"role": "opinion", "result": "root cause: Z"},
            {"role": "implement", "sh": notes.format("tried C"), "result": "FAILED\nC"},
            {"role": "implement", "result": "NEEDS-EGOR\nWhich option, 1 or 2?"},
        ]
        self.assertEqual(self.run_py(steps), 2, self.output)
        for n in (1, 2):
            self.assertTrue(self.ref(self.wt, f"refs/wip/P0.1/{n}"), n)
        self.assertTrue(self.ref(self.nv, "refs/wip/P0.1/2"))
        self.assertFalse((self.wt / "x.txt").exists() or (self.wt / "y.txt").exists())
        self.assertFalse((self.nv / "z.rs").exists())
        notes_text = self.work("notes/P0.1.md")
        for s in ("tried A", "tried B", "tried C", "refs/wip/P0.1/1"):
            self.assertIn(s, notes_text)
        third = [c for c in self.calls() if c["role"] == "implement"][2]["prompt"]
        self.assertIn("Attempt 3 of 3", third)
        self.assertIn("Second opinion", third)
        self.assertIn("root cause: Z", third)
        self.assertIn("tried B", third)
        plan = self.work("PLAN.md")
        for tid in ("P0.1", "P0.2", "P0.3"):
            self.assertIn(f"- [!] {tid}", plan)
        blocked = self.work("BLOCKED.md")
        self.assertIn("depends on blocked P0.1", blocked)
        self.assertIn("Which option, 1 or 2?", blocked)
        self.assertIn("GATE P0 blocked", self.work("STOP.md"))
        self.assertTrue(self.clean(self.wt) and self.clean(self.nv))
        # a second start refuses while STOP.md exists, and changes nothing
        before = sh(self.wt, "git", "rev-parse", "HEAD")
        self.assertEqual(self.run_py([]), 1)
        self.assertEqual(sh(self.wt, "git", "rev-parse", "HEAD"), before)

    def test_limit_resumes_and_failed_check_is_fixed_in_session(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] P0.2 two
            - [ ] GATE P0
            """, runsh=True)
        steps = [
            {"role": "implement", "sh": "echo w > w.txt", "is_error": True, "exit": 1,
             "result": "Claude AI usage limit reached|1700000000"},
            {"role": "implement", "sh": "test -f w.txt; echo 1 > preview/test/out/rc-fast; git add -A; git commit -qm w",
             "result": "DONE"},
            {"role": "implement", "sh": "rm preview/test/out/rc-fast", "result": "DONE"},
            {"role": "implement", "result": "ENV\nscreenshot is black: screen locked"},
        ]
        self.assertEqual(self.run_py(steps), 2, self.output)
        impl = [c for c in self.calls() if c["role"] == "implement"]
        self.assertEqual(impl[1]["resume"], "s0")                     # the limit: same session, edits kept
        self.assertIn("usage limit", impl[1]["prompt"])
        self.assertEqual(impl[2]["resume"], "s1")                     # red check after DONE: fixed in place
        self.assertIn("`preview/test/run.sh fast` exited 1", impl[2]["prompt"])
        self.assertIsNone(impl[3]["resume"])
        self.assertIn("Attempt 1 of 3", impl[3]["prompt"])           # P0.2
        self.assertTrue(all(c["max_turns"] for c in impl))
        self.assertEqual(sh(self.wt, "git", "ls-files", "w.txt"), "w.txt")
        self.assertFalse(self.ref(self.wt, "refs/wip/P0.1/1"))
        self.assertIn("- [x] P0.1", self.work("PLAN.md"))
        self.assertIn("screen locked", self.work("STOP.md"))
        self.assertIn("waiting 5 min", self.output)

    def test_check_still_red_after_fixes_rolls_back(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """, runsh=True)
        steps = [
            {"role": "implement", "sh": "echo 1 > preview/test/out/rc-fast; echo z > z.txt; git add z.txt; git commit -qm z",
             "result": "DONE"},
            {"role": "implement", "result": "DONE"},                    # fix 1, still red
            {"role": "implement", "result": "DONE"},                    # fix 2, still red
            {"role": "implement", "sh": "rm preview/test/out/rc-fast", "result": "DONE"},
            {"role": "review", "result": "NO FINDINGS"},
        ]
        self.assertEqual(self.run_py(steps), 0, self.output)
        impl = [c for c in self.calls() if c["role"] == "implement"]
        self.assertEqual([c["resume"] for c in impl], [None, "s0", "s1", None])
        self.assertIn("Attempt 2 of 3", impl[3]["prompt"])
        self.assertIn("returned DONE, but `preview/test/run.sh fast` exited 1", impl[3]["prompt"])
        self.assertFalse((self.wt / "z.txt").exists())
        self.assertTrue(self.ref(self.wt, "refs/wip/P0.1/1"))
        # no Neovide commits: the gate merge moved Egor's main up to the P0 tag
        sh(self.live, "git", "merge-base", "--is-ancestor", "gate/P0", "main")

    def test_missing_status_line_is_asked_for(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        steps = [{"role": "implement", "result": "All done, tests pass."},
                 {"role": "implement", "result": "DONE"},
                 {"role": "implement", "result": "DONE"},                # P0.C1
                 {"role": "review", "result": "NO FINDINGS"}]
        self.assertEqual(self.run_py(steps), 0, self.output)
        impl = [c for c in self.calls() if c["role"] == "implement"]
        self.assertEqual(impl[1]["resume"], "s0")
        self.assertIn("no status line", impl[1]["prompt"])

    def test_max_turns_is_a_failed_attempt(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        steps = [{"role": "implement", "is_error": True, "exit": 1, "subtype": "error_max_turns", "result": ""},
                 {"role": "implement", "result": "DONE"},
                 {"role": "implement", "result": "DONE"},
                 {"role": "review", "result": "NO FINDINGS"}]
        self.assertEqual(self.run_py(steps), 0, self.output)
        impl = [c for c in self.calls() if c["role"] == "implement"]
        self.assertIsNone(impl[1]["resume"])
        self.assertIn("Attempt 2 of 3", impl[1]["prompt"])
        self.assertIn("--max-turns", self.work("notes/P0.1.md"))

    def test_task_budget_blocks(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        steps = [{"role": "implement", "result": "FAILED\nA"}, {"role": "implement", "result": "FAILED\nB"}]
        self.assertEqual(self.run_py(steps, env_extra={"PREVIEW_TASK_BUDGET": "0.9"}), 2, self.output)
        self.assertEqual(len([c for c in self.calls() if c["role"] in ("implement", "opinion")]), 2)
        self.assertIn("- [!] P0.1", self.work("PLAN.md"))
        self.assertIn("estimated spend for this task reached 1.00 USD", self.work("BLOCKED.md"))

    def test_crash_writes_stop(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        steps = [{"role": "implement", "sh": 'touch "$(git rev-parse --git-dir)/index.lock"', "result": "DONE"}]
        self.assertEqual(self.run_py(steps), 2, self.output)
        stop = self.work("STOP.md")
        self.assertIn("run.py crashed", stop)
        self.assertIn("index.lock", stop)

    def test_live_tree_change_stops(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        steps = [{"role": "implement", "sh": f"echo 'oops' >> {self.live}/init.lua; echo w > w.txt; git add w.txt;"
                                             "git commit -qm w", "result": "DONE"}]
        self.assertEqual(self.run_py(steps), 2, self.output)
        self.assertIn("Egor's trees", self.work("STOP.md"))
        self.assertIn("- [ ] P0.1", self.work("PLAN.md"))
        self.assertFalse((self.wt / "w.txt").exists())
        self.assertTrue(self.ref(self.wt, "refs/wip/stop"))

    def test_red_gate_fix_task(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """, runsh=True)
        self.rc("gate", 1)
        steps = [
            {"role": "implement", "result": "DONE"},
            {"role": "implement", "sh": "rm preview/test/out/rc-gate", "result": "DONE"},   # P0.F1
            {"role": "review", "result": "NO FINDINGS"},
        ]
        self.assertEqual(self.run_py(steps), 0, self.output)
        plan = self.work("PLAN.md")
        self.assertIn("- [x] P0.F1 Fix gate P0", plan)
        self.assertIn("failing on purpose", self.work("notes/P0.F1.md"))
        self.assertTrue(self.ref(self.wt, "refs/tags/gate/P0"))

    def test_interruptions_count_as_one_attempt(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        boom = {"role": "implement", "is_error": True, "exit": 1, "result": "boom"}
        steps = [boom, boom, boom, {"role": "implement", "result": "DONE"}, {"role": "implement", "result": "DONE"},
                 {"role": "review", "result": "NO FINDINGS"}]
        self.assertEqual(self.run_py(steps), 0, self.output)
        impl = [c for c in self.calls() if c["role"] == "implement"]
        self.assertIn("Attempt 1 of 3", impl[2]["prompt"])
        self.assertIn("Attempt 2 of 3", impl[3]["prompt"])
        self.assertIn("ended without a status 3 times", self.work("notes/P0.1.md"))

    def test_startup_keeps_egor_edits_and_saves_leftovers(self):
        self.init("""\
            - [!] P0.1 one
            - [ ] GATE P0
            """)
        plan = self.wt / "preview/work/PLAN.md"
        plan.write_text(plan.read_text().replace("- [!] P0.1", "- [ ] P0.1"))   # Egor unblocks
        (self.wt / "half.txt").write_text("half-done work of a crashed session\n")
        steps = [{"role": "implement", "result": "DONE"}, {"role": "implement", "result": "DONE"},
                 {"role": "review", "result": "NO FINDINGS"}]
        self.assertEqual(self.run_py(steps), 0, self.output)
        self.assertTrue(self.ref(self.wt, "refs/wip/startup"))
        self.assertFalse((self.wt / "half.txt").exists())
        self.assertIn("- [x] P0.1", self.work("PLAN.md"))

    def test_restart_drops_a_pending_resume(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        (self.live / ".git/preview-agent-state.json").write_text(json.dumps(
            {"resume": {"task": "P0.1", "n": 1, "session": "old", "prompt": "x", "why": "resume",
                        "fixes": 0, "nudged": False}}))
        (self.wt / "half.txt").write_text("work of the session that waited for the limit\n")
        steps = [{"role": "implement", "result": "DONE"}, {"role": "implement", "result": "DONE"},
                 {"role": "review", "result": "NO FINDINGS"}]
        self.assertEqual(self.run_py(steps), 0, self.output)
        impl = [c for c in self.calls() if c["role"] == "implement"]
        self.assertIsNone(impl[0]["resume"])
        self.assertIn("refs/wip/startup", impl[0]["prompt"])          # the note reached the fresh session
        self.assertTrue(self.ref(self.wt, "refs/wip/startup"))
        self.assertFalse((self.wt / "half.txt").exists())

    def test_review_rounds_batching_and_refused_merge(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        many = "\n".join(f"BLOCKING: problem {i}, f{i}.lua (why {i})" for i in range(1, 9))
        steps = [{"role": "implement", "sh": "echo weaker >> preview/agent/SPEC.md; git commit -qam launder",
                  "result": "DONE"},
                 {"role": "implement", "result": "DONE"},                     # P0.C1
                 {"role": "review", "result": many + "\nMINOR: tiny"}]
        steps += [{"role": "implement", "result": "DONE"} for _ in range(7)]  # R1..R6 + the batch R7
        steps += [{"role": "review", "result": "BLOCKING: problem 3 still there, f3.lua (not fixed)"},
                  {"role": "implement", "result": "DONE"}]                    # R8, not reviewed again
        before = sh(self.live, "git", "rev-parse", "main")
        self.assertEqual(self.run_py(steps), 0, self.output)
        plan = self.work("PLAN.md")
        self.assertIn("- [x] P0.R6 Fix: problem 6", plan)
        self.assertIn("- [x] P0.R7 Fix the remaining review findings", plan)
        self.assertIn("- [x] P0.R8 Fix: problem 3 still there", plan)
        self.assertIn("problem 8", self.work("notes/P0.R7.md"))
        self.assertIn("not reviewed again", self.work("PENDING.md"))
        self.assertIn("merge of agent/preview into main left to Egor", self.work("BLOCKED.md"))
        self.assertIn("preview/agent/SPEC.md", self.work("BLOCKED.md"))
        self.assertEqual(sh(self.live, "git", "rev-parse", "main"), before)
        self.assertEqual(len([c for c in self.calls() if c["role"] == "review"]), 2)

    def test_reopened_task_gets_a_fresh_cap(self):
        self.init("""\
            - [ ] P0.1 one
            - [ ] GATE P0
            """)
        (self.live / ".git/preview-agent-state.json").write_text(json.dumps({"attempts": {"P0.1": 3}}))
        steps = [{"role": "implement", "result": "DONE"}, {"role": "implement", "result": "DONE"},
                 {"role": "review", "result": "NO FINDINGS"}]
        self.assertEqual(self.run_py(steps), 0, self.output)
        self.assertIn("Attempt 1 of 3", self.calls()[1]["prompt"])


if __name__ == "__main__":
    unittest.main()
