# Workflow: what run.py does

The orchestrator is `preview/agent/run.py`, plain code. Claude only works inside steps, one fresh
`claude -p` session per step (no long-lived context, no compaction): implement a task
(`IMPLEMENTER.md`), give a second opinion (`OPINION.md`), review a gate (`REVIEW.md`). Each gets
its instructions plus SPEC.md as the system prompt (the same text every time, so it is cached),
read-only roles get read-only tools, and nobody can start subagents. State lives in
`preview/work/` (git) and `$(git rev-parse --git-common-dir)/preview-agent-state.json`.

## Start
1. Refuse to start while `preview/work/STOP.md` exists, Claude Code is older than 2.1.259, the
   hook tests fail or `preview/test/out/hooks.log` is not empty.
2. Commit Egor's edits under `preview/work/` (unblocked tasks, answers in notes). Save anything
   else an interrupted run left under `refs/wip/startup` and reset both worktrees to HEAD.
3. `git merge main` (Egor's spec/plan edits). A conflict refuses to start.
4. Snapshot Egor's trees (`~/.config/nvim`, `~/src/neovide`: HEAD, status, diff;
   `neovide-patched`: file list with sizes and mtimes).
5. Self-check: one tiny `claude -p` with the real flags must run a shell command and answer.
6. Once `run.sh` exists: `run.sh env` must be 0; a red `run.sh fast` inserts a fix task `X.F<n>`
   before the first open task.

## Task loop (the first open line of PLAN.md)
- A task whose `(needs ...)` is blocked: `[!]` "depends on", next.
- Attempt n of 3; before attempt 3 a read-only second opinion, passed into attempt 3. The prompt
  carries the task, the attempt, the base commits, CONTEXT.md and the notes file inline.
- After every session and every `run.sh` call: Egor's trees must match the snapshot (else STOP),
  the hook log must be empty (else STOP).
- DONE: both worktrees on `agent/preview`, history before the attempt intact, nothing left
  uncommitted in `~/src/neovide-agent`, then `run.sh fast` and (after GATE P1) `run.sh gate <last
  passed gate>` green. Then: run.py's own files restored, `[x]`, a PROGRESS line, one commit of
  everything (that commit is the new "green" base).
- FAILED, or DONE whose check failed: the attempt's work goes to `refs/wip/<ID>/<n>` (both repos),
  both worktrees are reset to green, `preview/work/` notes/CONTEXT/DECISIONS/PENDING are kept, a
  line goes into the notes, the next attempt starts. After attempt 3: `[!]`, BLOCKED.md.
- NEEDS-EGOR: saved and reset the same way, `[!]`, the question in BLOCKED.md.
- ENV (or `run.sh` exit 3): saved and reset, STOP.md, exit. Nothing fixes the environment at night.
- No status (crash, timeout, usage limit, outage): saved and reset, not counted, wait (1, then
  5/10/20/30 min; usage limits at least 5) and retry. Three non-limit interruptions of one task
  count as one failed attempt; 20 in a row: STOP.

## Gates (`- [ ] GATE Pn`)
1. A blocked task in the phase: STOP ("a phase never starts without the previous gate").
2. Tests: `run.sh gate Pn`. 3: STOP. Red: a fix task `Pn.F<k>` before the gate (with the failure
   in its notes), at most 3 per gate, then STOP. Before run.sh exists (P0): a check task `Pn.C1`.
3. Review round 1 (read-only session, range = previous gate tag..HEAD in both repos). BLOCKING
   findings become tasks `Pn.R<k>` before the gate (at most 6, the rest batched into one), MINOR
   ones go to PENDING.md. After the fixes (and green tests) round 2 reviews only the fixes. Its
   findings are fixed and tested but not reviewed again (noted in PENDING.md).
4. Pass: `[x]`, commit, `git tag -a gate/Pn` (pinned), then `git -C ~/.config/nvim merge --ff-only
   agent/preview` unless the branch changes a protected file or the merge fails: then a line in
   BLOCKED.md and Egor merges.

## End
All tasks `[x]`/`[!]`, `--until` reached (exit 0), or STOP.md (exit 2). PROGRESS.md always starts
with a summary: done/blocked counts, gates, next task, why it stopped, estimated spend, what Egor
has to look at.
