# Workflow (unattended run)

Read SPEC.md first. Work state lives in `preview/work/`: PLAN.md (tasks), PROGRESS.md, DECISIONS.md,
BLOCKED.md, PENDING.md, `notes/<task-slug>.md`. Nobody answers questions during the run.

## Tasks
- Take the first `- [ ]` line in PLAN.md and run it in a fresh subagent. Give it the task line, SPEC.md,
  its notes file and this file; it returns a short summary (done / not done, what changed, checks run).
  The main session stays small: it doesn't read code or paste logs, it only dispatches and records.
- Done = the task's checks ran green (exit codes). Then tick `- [x]` (keep the text), add one line to
  PROGRESS.md, commit.
- Not done = the subagent reverted to the last green commit and appended to the notes file what it tried,
  why it failed and its best hypothesis. Attempt 2 must not repeat a listed approach. Attempt 3 starts by
  questioning the assumptions and asking a second fresh subagent for the root cause.
- After 3 failed attempts: mark `- [!]`, put the reason in BLOCKED.md, move on. A task that depends on a
  blocked one is blocked too. A hook enforces the cap: the 6th subagent run on one task is refused
  (3 attempts + a second opinion + a spare); when that happens, block the task the same way.
- Needs Egor (a decision outside SPEC, a permission, hardware): the exact question in BLOCKED.md, `- [!]`,
  move on.
- Decisions that could go either way: one line in DECISIONS.md (what, why, how to revert); don't deliberate.

## Gates (`- [ ] GATE Pn`)
1. `preview/test/run.sh gate Pn` exits 0. Before P1 exists: the build passes and the phase's deliverables exist.
2. A fresh read-only reviewer subagent reviews `git diff <previous gate tag, or main>..HEAD` against SPEC:
   no hacks or symptom fixes, no duplicated logic between providers/renderers, the core has no provider
   knowledge, nothing reimplemented that a chosen library provides, tests not weakened, docs updated.
   Its findings become tasks inserted before the gate.
3. All green: tick the gate and commit everything (the tag is the baseline protected files are
   measured from), `git tag gate/Pn`, then exactly
   `git -C ~/.config/nvim merge --ff-only agent/preview` (pre-approved). If it fails, note it in
   BLOCKED.md and continue; Egor merges.

## Protected files
- always: `preview/agent/**`
- after GATE P1: `preview/test/run.sh`, `preview/test/e2e/md/**`, `preview/test/golden/md/**`,
  `preview/test/baseline.md`, `preview/test/thresholds/md.json`
- after GATE P3a: `preview/test/pdf/**`, `preview/test/e2e/pdf/**`, `preview/test/golden/pdf/**`,
  `preview/test/thresholds/pdf.json`

Hooks enforce this (`preview/agent/hooks/`): edits are refused, and changes made through the shell are
restored from the baseline after each command. Never try to get around them; if a file looks wrong, write
why in PENDING.md and continue.

## Boundaries
- Work in this worktree and in `~/src/neovide` (branch `agent/<topic>` off `webview`, following its rules in
  CLAUDE.md: commit as Egor Denisov, no AI attribution; never commit on `webview`).
- Never edit `~/.config/nvim` directly (only the merge above), never install Neovide into
  `~/.local/share/neovide-patched`, never push.
- E2E: only the isolated dev instance from CLAUDE.md; never post global input events or capture the whole screen.

## Tokens
- One task per subagent; the main session keeps only summaries.
- Test output: failures only. Open a screenshot only when a visual check fails.
- Read files partially; don't re-derive what the notes already say.

## Done
Every task is `[x]` or `[!]`. Write a summary at the top of PROGRESS.md: what is done, what is blocked and
why, what Egor has to check (subjective smoothness, PENDING.md, BLOCKED.md, any merge left to him).
