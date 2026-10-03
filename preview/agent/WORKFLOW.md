# Workflow: the main session (orchestrator)

You dispatch and record. You don't read code, diffs, logs, notes or screenshots, and you don't need
SPEC.md: subagents work by `IMPLEMENTER.md`, reviewers by `REVIEW.md`. Nobody answers questions during
the run. State lives in `preview/work/`: PLAN.md, PROGRESS.md, DECISIONS.md, BLOCKED.md, PENDING.md,
CONTEXT.md, `notes/<slug>.md` (slug = the task text, lowercased, non-alphanumerics -> `-`, max 50 chars),
STOP.md.

## Task loop
1. Take the first `- [ ]` line in PLAN.md. Never edit the text of an open line: the attempt counter
   (a hook) is keyed by it.
2. Start one subagent with exactly this prompt: paths only, never paste file contents.

       Read preview/agent/IMPLEMENTER.md and follow it.
       Task: <the task line>
       Notes: preview/work/notes/<slug>.md
       Attempt: <n>
       <attempt 3 only: "Second opinion: <its answer>">

3. It returns at most 10 lines starting with DONE, FAILED, ENV or NEEDS-EGOR.
4. DONE: once `preview/test/run.sh` exists, run `preview/test/run.sh fast >/dev/null 2>&1; echo $?`
   yourself. 0 -> tick `- [x]` (keep the text), one line in PROGRESS.md, commit. Otherwise treat it as
   FAILED and say so in the next attempt's prompt.
5. FAILED: next attempt. Before attempt 3, start a read-only second-opinion subagent:
   "Read preview/work/notes/<slug>.md and the code it names. Don't edit anything. In at most 10 lines: the
   most likely root cause, and which assumptions all attempts shared that may be wrong."
   Pass its answer into attempt 3. (Subagents can't start subagents; this is yours.)
6. Attempt 3 failed, or the hook refused a launch: `- [!]`, BLOCKED.md gets the reason and the notes
   path, move on. Later tasks of the same phase that need its result: `- [!]` "depends on <task>".
7. NEEDS-EGOR: the exact question in BLOCKED.md, `- [!]`, move on. A `[!]` always has either three
   attempts in its notes or a question for Egor.
8. ENV: write STOP.md (the subagent's lines, the task) and stop. Don't retry: nothing fixes the
   environment at night, and every retry burns a run.
9. Decisions that could go either way are the subagents' (DECISIONS.md); don't deliberate.

## Gates (`- [ ] GATE Pn`)
1. Check: `preview/test/run.sh gate Pn >/dev/null 2>&1; echo $?`. 0 -> step 2; 1 -> the failure becomes
   a task inserted before the gate (`- [ ] Fix gate Pn: run preview/test/run.sh gate Pn`); 3 -> STOP.md.
   Before run.sh exists (P0): a subagent (the task-loop prompt, task "GATE P0: check") confirms the
   build passes and the phase's deliverables exist.
2. Review: a fresh subagent with "Read preview/agent/REVIEW.md and follow it. Range: <base>..HEAD",
   base = the previous `gate/*` tag, or `$(git merge-base main HEAD)` for P0. Each finding line it
   returns is inserted as a `- [ ]` task before the gate; the gate is checked again after them.
   `NO FINDINGS` -> step 3.
3. Tick the gate, commit everything (the tag is the baseline protected files are measured from),
   `git tag gate/Pn`, then run exactly this, as a command on its own (pre-approved):
   `git -C ~/.config/nvim merge --ff-only agent/preview`. If it fails or a hook refuses it, put the
   message in BLOCKED.md and continue; Egor merges.
4. A gate that can't go green (blocked by the run cap or a blocked task it needs): STOP.md
   "GATE Pn blocked: <why>" and stop. Never start a phase without the previous gate: its tests are what
   protects the next one.

## Done
Every task is `[x]` or `[!]`, or STOP.md exists. Write a summary at the top of PROGRESS.md: what is
done, what is blocked and why, why the run stopped (if it did), what Egor has to check (subjective
smoothness, PENDING.md, BLOCKED.md, any merge left to him, the Neovide branch to merge into `webview`).
