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
    "preview/test/run.sh": "exit 0\n",
    "preview/test/lib/diff.py": "THRESH = 1\n",
    "preview/test/unit/a_test.lua": "-- unit\n",
    "preview/test/e2e/pdf/scroll.lua": "-- scenario\n",
    "preview/test/pdf/a.tex": "tex\n",
    "preview/test/thresholds/pdf.json": "{}\n",
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

    def hook(self, name, payload, role="implement"):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=str(self.root), TMPDIR=self.tmp.name, PREVIEW_ROLE=role)
        text = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.run([sys.executable, str(HOOKS / name)], input=text,
                              capture_output=True, text=True, env=env)

    def edit(self, file_path, tool="Edit", cwd=None, role="implement"):
        r = self.hook("guard.py", {"tool_name": tool, "cwd": str(cwd or self.root),
                                   "tool_input": {"file_path": str(file_path)}}, role)
        self.assertEqual(r.returncode, 0, r.stderr)
        if not r.stdout.strip():
            return "pass"
        return json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"]

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

    def test_ignored_artifacts_untouched(self):
        sh(self.root, "git", "tag", "gate/P1")
        (self.root / ".gitignore").write_text("preview/test/golden/md/*.actual.png\n")
        sh(self.root, "git", "add", ".gitignore")
        sh(self.root, "git", "commit", "-qm", "ignore")
        actual = self.root / "preview/test/golden/md/a.actual.png"
        actual.write_text("png")
        self.assertEqual(self.bash().returncode, 0)
        self.assertTrue(actual.exists())

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


    # --- shell guard -------------------------------------------------------------------------

    def cmd(self, command, role="implement"):
        r = self.hook("guard.py", {"tool_name": "Bash", "cwd": str(self.root),
                                   "tool_input": {"command": command}}, role)
        self.assertEqual(r.returncode, 0, r.stderr)
        return "deny" if '"deny"' in r.stdout else "pass"

    def test_live_trees_read_only(self):
        for c in ("cp x ~/.config/nvim/a", "echo x > ~/.config/nvim/a", "cd ~/.config/nvim && git commit -qam x",
                  "git -C ~/.config/nvim reset --hard agent/preview", "sed -i '' s/a/b/ ~/.config/nvim/init.lua",
                  "find ~/.config/nvim -name x -delete", "cargo build --manifest-path ~/src/neovide/Cargo.toml",
                  "cp target/release/neovide ~/.local/share/neovide-patched/x",
                  "git -C ~/.config/nvim merge --ff-only agent/preview && echo done",
                  "cat ~/.config/nvim/init.lua | tee /tmp/x"):
            self.assertEqual(self.cmd(c), "deny", c)
        for c in ("cat ~/.config/nvim/mdpreview/CLAUDE.md", "git -C ~/.config/nvim log --oneline -3",
                  "ls ~/.config/nvim 2>/dev/null", "grep -rn x ~/src/neovide/src 2>&1 | head",
                  "cd ~/src/neovide-agent && cargo build --release -q", "echo x > ~/.config/nvim-other/a",
                  "npm run build", "git commit -qam 'feat: x'"):
            self.assertEqual(self.cmd(c), "pass", c)

    def test_push_and_tag_moves_refused(self):
        for c in ("git push", "git -c x=y push origin main", "git tag -a -f gate/P1", "git tag -d gate/P1",
                  "git -C . tag --delete gate/P1", "git update-ref refs/tags/gate/P1 HEAD"):
            self.assertEqual(self.cmd(c), "deny", c)
        for c in ("git tag gate/P1", "git tag -a -m 'gate P1' gate/P1"):
            self.assertEqual(self.cmd(c), "deny", c)
        for c in ("git tag", "git tag -l 'gate/*'", "git tag --points-at HEAD"):
            self.assertEqual(self.cmd(c), "pass", c)

    # --- harness, owned files, roles, shared refs --------------------------------------------

    def test_harness_protected_after_p1_with_exceptions(self):
        r = self.root / "preview/test"
        for p in ("run.sh", "lib/diff.py", "e2e/md/new.lua", "fixtures/md/k.md"):
            self.assertEqual(self.edit(r / p, tool="Write"), "pass", p)
        sh(self.root, "git", "tag", "gate/P1")
        for p in ("run.sh", "lib/diff.py", "e2e/md/new.lua", "fixtures/md/k.md", "probe/probe.m"):
            self.assertEqual(self.edit(r / p, tool="Write"), "deny", p)
        for p in ("unit/a_test.lua", "unit/new_test.lua", "adapter.lua", "e2e/pdf/scroll.lua",
                  "pdf/a.tex", "thresholds/pdf.json", "golden/pdf/p1.png"):
            self.assertEqual(self.edit(r / p, tool="Write"), "pass", p)

    def test_pdf_tests_staged(self):
        r = self.root / "preview/test"
        sh(self.root, "git", "tag", "gate/P1")
        sh(self.root, "git", "tag", "gate/P3a")
        self.assertEqual(self.edit(r / "pdf/a.tex"), "deny")
        self.assertEqual(self.edit(r / "thresholds/pdf.json"), "deny")
        self.assertEqual(self.edit(r / "e2e/pdf/scroll.lua"), "pass")
        sh(self.root, "git", "tag", "gate/P3b")
        self.assertEqual(self.edit(r / "e2e/pdf/scroll.lua"), "deny")
        self.assertEqual(self.edit(r / "unit/a_test.lua"), "pass")

    def test_restore_respects_exceptions(self):
        sh(self.root, "git", "tag", "gate/P1")
        (self.root / "preview/test/lib/diff.py").write_text("THRESH = 99\n")
        (self.root / "preview/test/unit/a_test.lua").write_text("-- changed\n")
        (self.root / "preview/test/unit/b_test.lua").write_text("-- new\n")
        (self.root / "preview/test/lib/extra.py").write_text("x\n")
        r = self.bash()
        self.assertEqual(r.returncode, 2)
        self.assertEqual((self.root / "preview/test/lib/diff.py").read_text(), "THRESH = 1\n")
        self.assertFalse((self.root / "preview/test/lib/extra.py").exists())
        self.assertEqual((self.root / "preview/test/unit/a_test.lua").read_text(), "-- changed\n")
        self.assertTrue((self.root / "preview/test/unit/b_test.lua").exists())

    def test_owned_files_refused(self):
        for p in ("PLAN.md", "PROGRESS.md", "BLOCKED.md", "STOP.md"):
            self.assertEqual(self.edit(self.root / "preview/work" / p), "deny", p)
        for p in ("CONTEXT.md", "DECISIONS.md", "PENDING.md", "notes/P0.1.md"):
            self.assertEqual(self.edit(self.root / "preview/work" / p, tool="Write"), "pass", p)

    def test_read_only_roles(self):
        for role in ("review", "opinion"):
            self.assertEqual(self.edit(self.root / "src.txt", role=role), "deny")
            for c in ("git diff -M --stat a..b", "cd preview && git log --oneline -3", "grep -rn x preview | head",
                      "sed -n 1,20p src.txt", "git show HEAD:src.txt | wc -l"):
                self.assertEqual(self.cmd(c, role=role), "pass", c)
            for c in ("touch x", "echo x > src.txt", "sed -i '' s/a/b/ src.txt", "git commit -qam x",
                      "npm test", "git diff --output=/tmp/x", "awk 'BEGIN{system(\"rm x\")}'"):
                self.assertEqual(self.cmd(c, role=role), "deny", c)
        self.assertEqual(self.cmd("touch x"), "pass")

    def test_subagents_refused(self):
        for tool in ("Agent", "Task", "Workflow"):
            r = self.hook("guard.py", {"tool_name": tool, "cwd": str(self.root), "tool_input": {"prompt": "x"}})
            self.assertIn('"deny"', r.stdout, tool)

    def test_shared_refs_and_config(self):
        for c in ("git branch -D main", "git branch -f webview HEAD", "git branch -m agent/preview x",
                  "git worktree remove ~/src/neovide-agent", "git worktree add ../x", "git config user.name x",
                  "git gc --prune=now", "git reflog expire --all", "git checkout main", "git switch webview",
                  "git -C ~/src/neovide-agent update-ref refs/heads/webview HEAD", "git remote add x y",
                  "git symbolic-ref HEAD refs/heads/main"):
            self.assertEqual(self.cmd(c), "deny", c)
        for c in ("git branch", "git branch -a -v", "git branch --show-current", "git branch spike-x",
                  "git worktree list", "git config --get user.name", "git checkout main -- src.txt",
                  "git checkout -- src.txt", "git reset --hard HEAD~1", "git stash", "git commit -qam 'x'",
                  "git log refs/wip/P0.1/1 --stat", "git -C ~/src/neovide-agent commit -qam 'feat: x'"):
            self.assertEqual(self.cmd(c), "pass", c)

    # --- tag pins ----------------------------------------------------------------------------

    def rev(self, ref):
        return subprocess.run(["git", "-C", str(self.root), "rev-parse", "-q", "--verify", ref],
                              capture_output=True, text=True).stdout.strip()

    def test_gate_tags_pinned(self):
        sh(self.root, "git", "tag", "-a", "-m", "gate", "gate/P1")
        pinned = self.rev("refs/tags/gate/P1")
        self.assertEqual(self.bash().returncode, 0)
        (self.root / "src.txt").write_text("more\n")
        sh(self.root, "git", "commit", "-qam", "more")
        sh(self.root, "git", "tag", "-f", "gate/P1")
        r = self.bash()
        self.assertEqual(r.returncode, 2)
        self.assertIn("gate/P1", r.stderr)
        self.assertEqual(self.rev("refs/tags/gate/P1"), pinned)
        sh(self.root, "git", "tag", "-d", "gate/P1")
        self.assertEqual(self.bash().returncode, 2)
        self.assertEqual(self.rev("refs/tags/gate/P1"), pinned)
        self.assertEqual(self.bash().returncode, 0)

    def test_two_tags_on_one_commit(self):
        sh(self.root, "git", "tag", "gate/P0")
        sh(self.root, "git", "tag", "gate/P1")
        self.assertEqual(self.bash().returncode, 0)
        sh(self.root, "git", "tag", "-d", "gate/P0")
        self.assertEqual(self.bash().returncode, 2)
        self.assertTrue(self.rev("refs/tags/gate/P0"))

    def test_adapter_protected_after_p3b(self):
        adapter = self.root / "preview/test/adapter.lua"
        sh(self.root, "git", "tag", "gate/P3a")
        self.assertEqual(self.edit(adapter), "pass")
        sh(self.root, "git", "tag", "gate/P3b")
        self.assertEqual(self.edit(adapter), "deny")

    def test_failures_logged_in_test_out(self):
        self.hook("guard.py", "not json")
        self.assertIn("JSONDecodeError", (self.root / "preview/test/out/hooks.log").read_text())

if __name__ == "__main__":
    unittest.main()
