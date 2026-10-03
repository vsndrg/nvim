#!/usr/bin/env python3
"""Tests for guard.py and restore.py on a throwaway repo: python3 test_hooks.py"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOOKS = Path(__file__).resolve().parent
FILES = {
    "preview/agent/SPEC.md": "spec\n",
    "preview/test/golden/md/a.txt": "golden\n",
    "preview/test/adapter.lua": "return {}\n",
    "preview/work/PLAN.md": "- [x] done\n- [ ] first task\n- [ ] second task\n",
    "src.txt": "code\n",
}


def sh(cwd, *args):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = r = Path(self.tmp.name).resolve() / "repo"
        for p, text in FILES.items():
            (r / p).parent.mkdir(parents=True, exist_ok=True)
            (r / p).write_text(text)
        sh(r, "git", "init", "-q", "-b", "main")
        sh(r, "git", "config", "user.name", "t")
        sh(r, "git", "config", "user.email", "t@t")
        sh(r, "git", "add", "-A")
        sh(r, "git", "commit", "-qm", "init")
        sh(r, "git", "checkout", "-qb", "agent/preview")

    def tearDown(self):
        self.tmp.cleanup()

    def hook(self, name, payload):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=str(self.root), TMPDIR=self.tmp.name)
        text = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.run([sys.executable, str(HOOKS / name)], input=text,
                              capture_output=True, text=True, env=env)

    def edit(self, file_path, tool="Edit", cwd=None):
        r = self.hook("guard.py", {"tool_name": tool, "cwd": str(cwd or self.root),
                                   "tool_input": {"file_path": str(file_path)}})
        self.assertEqual(r.returncode, 0, r.stderr)
        if not r.stdout.strip():
            return "pass"
        return json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"]

    def launch(self):
        r = self.hook("guard.py", {"tool_name": "Agent", "cwd": str(self.root), "tool_input": {"prompt": "x"}})
        return "deny" if "deny" in r.stdout else "pass"

    def bash(self):
        return self.hook("restore.py", {"tool_name": "Bash", "cwd": str(self.root),
                                        "tool_input": {"command": "x"}, "tool_response": {}})

    def test_agent_dir_always_protected(self):
        self.assertEqual(self.edit(self.root / "preview/agent/SPEC.md"), "deny")
        self.assertEqual(self.edit(self.root / "preview/agent/new.md", tool="Write"), "deny")

    def test_goldens_free_before_gate_protected_after(self):
        golden = self.root / "preview/test/golden/md/a.txt"
        self.assertEqual(self.edit(golden), "pass")
        sh(self.root, "git", "tag", "gate/P1")
        self.assertEqual(self.edit(golden), "deny")
        self.assertEqual(self.edit(self.root / "preview/test/golden/md/new.txt", tool="Write"), "deny")
        self.assertEqual(self.edit(self.root / "preview/test/adapter.lua"), "pass")
        self.assertEqual(self.edit(self.root / "src.txt"), "pass")

    def test_paths_outside_and_relative(self):
        self.assertEqual(self.edit(self.root / "../elsewhere.txt"), "pass")
        self.assertEqual(self.edit("agent/SPEC.md", cwd=self.root / "preview"), "deny")
        self.assertEqual(self.edit(self.root / "preview/test/../agent/SPEC.md"), "deny")

    def test_restore_after_gate(self):
        sh(self.root, "git", "tag", "gate/P1")
        g = self.root / "preview/test/golden/md"
        (g / "a.txt").write_text("loosened\n")
        (g / "new.txt").write_text("extra\n")
        r = self.bash()
        self.assertEqual(r.returncode, 2)
        self.assertIn("a.txt", r.stderr)
        self.assertIn("new.txt", r.stderr)
        self.assertEqual((g / "a.txt").read_text(), "golden\n")
        self.assertFalse((g / "new.txt").exists())
        self.assertEqual(self.bash().returncode, 0)

    def test_restore_committed_change(self):
        sh(self.root, "git", "tag", "gate/P1")
        g = self.root / "preview/test/golden/md"
        (g / "a.txt").write_text("loosened\n")
        (g / "b.txt").write_text("added\n")
        sh(self.root, "git", "add", "-A")
        sh(self.root, "git", "commit", "-qm", "cheat")
        self.assertEqual(self.bash().returncode, 2)
        self.assertEqual((g / "a.txt").read_text(), "golden\n")
        self.assertFalse((g / "b.txt").exists())

    def test_restore_deleted_file(self):
        sh(self.root, "git", "tag", "gate/P1")
        (self.root / "preview/test/golden/md/a.txt").unlink()
        self.assertEqual(self.bash().returncode, 2)
        self.assertTrue((self.root / "preview/test/golden/md/a.txt").exists())

    def test_restore_agent_dir_against_main(self):
        spec = self.root / "preview/agent/SPEC.md"
        spec.write_text("weaker\n")
        self.assertEqual(self.bash().returncode, 2)
        self.assertEqual(spec.read_text(), "spec\n")

    def test_main_updates_to_agent_dir_are_not_reverted(self):
        sh(self.root, "git", "checkout", "-q", "main")
        (self.root / "preview/agent/SPEC.md").write_text("spec v2\n")
        sh(self.root, "git", "commit", "-qam", "egor updates the spec")
        sh(self.root, "git", "checkout", "-q", "agent/preview")
        sh(self.root, "git", "merge", "-q", "--ff-only", "main")
        self.assertEqual(self.bash().returncode, 0)
        self.assertEqual((self.root / "preview/agent/SPEC.md").read_text(), "spec v2\n")

    def test_unprotected_changes_untouched(self):
        (self.root / "preview/test/golden/md/a.txt").write_text("new golden\n")  # before the gate
        (self.root / "src.txt").write_text("changed\n")
        self.assertEqual(self.bash().returncode, 0)
        self.assertEqual((self.root / "src.txt").read_text(), "changed\n")
        self.assertEqual((self.root / "preview/test/golden/md/a.txt").read_text(), "new golden\n")

    def test_run_limit_per_task(self):
        for _ in range(5):
            self.assertEqual(self.launch(), "pass")
        self.assertEqual(self.launch(), "deny")
        self.assertEqual(self.launch(), "deny")
        plan = self.root / "preview/work/PLAN.md"
        plan.write_text(plan.read_text().replace("- [ ] first task", "- [!] first task"))
        self.assertEqual(self.launch(), "pass")

    def test_no_open_task(self):
        (self.root / "preview/work/PLAN.md").write_text("- [x] all done\n")
        for _ in range(7):
            self.assertEqual(self.launch(), "pass")

    def test_fail_open(self):
        for name, text in (("guard.py", "not json"), ("restore.py", "{")):
            r = self.hook(name, text)
            self.assertEqual((r.returncode, r.stdout), (0, ""))
        r = subprocess.run([sys.executable, str(HOOKS / "guard.py")], capture_output=True, text=True,
                           input=json.dumps({"tool_name": "Edit", "cwd": "/",
                                             "tool_input": {"file_path": "/x"}}),
                           env=dict(os.environ, CLAUDE_PROJECT_DIR=self.tmp.name, TMPDIR=self.tmp.name))
        self.assertEqual((r.returncode, r.stdout), (0, ""))  # not a git repo

    def test_hooks_leave_no_bytecode(self):
        self.edit(self.root / "src.txt")
        self.bash()
        self.assertFalse((HOOKS / "__pycache__").exists())

    def test_other_tools_ignored(self):
        r = self.hook("guard.py", {"tool_name": "Read", "tool_input": {"file_path": str(self.root / "preview/agent/SPEC.md")}})
        self.assertEqual((r.returncode, r.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
