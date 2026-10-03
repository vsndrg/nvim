# Unattended run

## Once
1. `claude update` (auto mode, `/goal`, auto-continue after a usage limit: v2.1.234+).
2. `brew install poppler` (`pdftoppm`, `pdftotext`).
3. System Settings → Privacy & Security: Screen Recording and Accessibility for the terminal.
4. `git -C ~/.config/nvim worktree add ~/src/preview-agent -b agent/preview`
5. `cd ~/src/preview-agent && claude`: accept the trust dialog once, exit.

## Each run
In tmux, Mac on power, screen not locked (a locked screen gives black screenshots and red visual checks):

    cd ~/src/preview-agent && git merge --ff-only main
    caffeinate -dims claude --permission-mode auto --settings preview/agent/settings.json --add-dir ~/src/neovide

Then paste:

    /goal Every task in preview/work/PLAN.md is ticked [x] or blocked [!], worked strictly by preview/agent/WORKFLOW.md (read it and preview/agent/SPEC.md first). Prove it at the end by printing the output of `grep -c '^- \[ \]' preview/work/PLAN.md` (must be 0) and `git tag -l 'gate/*'`.

A fresh session each night is cheaper than resuming: all state is in `preview/work/` and git.

## Morning
`preview/work/PROGRESS.md` (summary on top), `BLOCKED.md`, `PENDING.md`, `git log --oneline main..agent/preview`.
