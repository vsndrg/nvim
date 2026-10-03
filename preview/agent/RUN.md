# Unattended run

## Once
1. `claude update` (2.1.259+: `--permission-prompts`; run.py checks).
2. `brew install poppler` (`pdftoppm`, `pdftotext`).
3. System Settings → Privacy & Security: Screen Recording and Accessibility for the terminal.
   Lock Screen: "Start Screen Saver when inactive" and "Require password" so that they never fire
   while plugged in (a locked screen gives black screenshots: the run stops with STOP.md).
4. Worktrees (your own trees stay untouched; the agent may only read them). The nvim one exists
   already; for Neovide:

       git -C ~/src/neovide worktree add ~/src/neovide-agent -b agent/preview webview

5. `cd ~/src/preview-agent && claude`: accept the trust dialog once, exit.
6. Check: `cd ~/src/preview-agent && git merge main && python3 preview/agent/run.py --check`.
   It runs the hook tests and one tiny `claude -p` with the real flags and prints
   "preflight and self-check passed".

## Each run
In tmux, Mac on power, lid open or an external display:

    cd ~/src/preview-agent
    caffeinate -dims python3 preview/agent/run.py            # add --until 07:30 to stop by the morning

That is all: it merges `main` itself (your spec/plan edits), waits out usage limits, and keeps
going until every task is done or blocked, or until it has to stop. Ctrl-C is safe: the next start
saves what the interrupted session left (`refs/wip/startup`) and continues.
Settings through the environment: `PREVIEW_MODEL` (default `opus`), `PREVIEW_EFFORT`,
`PREVIEW_STEP_TIMEOUT` (seconds, default 3 h per session).

## Morning
- `preview/work/PROGRESS.md` (summary on top), `BLOCKED.md`, `PENDING.md`, `DECISIONS.md`,
  `STOP.md` (fix the cause, then delete it), `git log --oneline main..agent/preview`.
- Logs: `preview/test/out/agent/run.log`; every session's prompt and JSON (with its session id for
  `claude --resume <id>`) next to it.
- Unblocking a task: in `~/src/preview-agent`, turn `[!]` back into `[ ]` and answer in its notes
  file (commit or not: the next start commits `preview/work/` edits). It gets a fresh attempt cap.
- Failed attempts' work: `git for-each-ref refs/wip` (both repos). Delete them when done with:
  `git for-each-ref --format='%(refname)' refs/wip | xargs -n1 git update-ref -d`.
- Gate tags are pinned in `$(git rev-parse --git-common-dir)/preview-agent-tags.json`: to move or
  delete a `gate/*` tag on purpose, delete that file too, or the next hook run restores the tag.
- Neovide: merging `agent/preview` into `webview`, regenerating `mdpreview/neovide-webview.patch`
  (later `preview/`), installing into `neovide-patched`: yours.
