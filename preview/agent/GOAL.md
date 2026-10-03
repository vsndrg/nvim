# Unattended run

## Once
1. `claude update` (auto mode, `/goal`, auto-continue after a usage limit: v2.1.234+).
2. `brew install poppler` (`pdftoppm`, `pdftotext`).
3. System Settings → Privacy & Security: Screen Recording and Accessibility for the terminal.
4. Worktrees (your own trees stay untouched; the agent may only read them):

       git -C ~/.config/nvim worktree add ~/src/preview-agent -b agent/preview
       git -C ~/src/neovide worktree add ~/src/neovide-agent -b agent/preview webview

5. `cd ~/src/preview-agent && claude`: accept the trust dialog once, exit.
6. Check the hooks fire: start the session as in "Each run" and ask, one at a time:
   - `append a line "x" to preview/agent/SPEC.md` → "is protected (always)" (Edit refused) or
     "Restored protected tags/files" (shell write reverted);
   - `run: touch ~/.config/nvim/x` → refused ("may change Egor's trees").
   Then `/exit`; `git status` in the worktree must be clean, `~/.config/nvim/x` must not exist.
   Hook logic tests: `python3 preview/agent/hooks/test_hooks.py`.

## Each run
In tmux, Mac on power, screen not locked (a locked screen gives black screenshots: the run stops with
STOP.md instead of burning attempts):

    cd ~/src/preview-agent && git merge main
    caffeinate -dims claude --permission-mode auto --settings preview/agent/settings.json --add-dir ~/src/neovide-agent

(`git merge main` brings in your spec/plan edits; if it conflicts, resolve before starting.) Then paste:

    /goal Every task in preview/work/PLAN.md is ticked [x] or blocked [!], or preview/work/STOP.md exists; worked strictly by preview/agent/WORKFLOW.md (read it first). Prove it at the end by printing the output of `grep -c '^- \[ \]' preview/work/PLAN.md`, `git tag -l 'gate/*'` and `cat preview/work/STOP.md 2>/dev/null`.

A fresh session each night is cheaper than resuming: all state is in `preview/work/` and git.

## Morning
- `preview/work/PROGRESS.md` (summary on top), `STOP.md` (fix the cause, then delete it), `BLOCKED.md`,
  `PENDING.md`, `git log --oneline main..agent/preview`.
- `preview/test/out/hooks.log` must not exist or be empty: an entry means a hook crashed and its check
  was skipped (hooks fail open).
- Unblocking a task: turn `[!]` back into `[ ]` and answer it in its notes file. Its attempt count is
  kept in `$(git rev-parse --git-common-dir)/preview-agent-runs.json` (delete its entry for a fresh cap).
- Gate tags are pinned in `$(git rev-parse --git-common-dir)/preview-agent-tags.json`: to move or
  delete a `gate/*` tag on purpose, delete that file too, or the next hook run restores the tag.
- Neovide: merging `agent/preview` into `webview`, regenerating `mdpreview/neovide-webview.patch`
  (later `preview/`), installing into `neovide-patched`: yours.
