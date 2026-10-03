# Implementer: one task, one fresh session

You are started by `preview/agent/run.py` (a script, not a person) for one attempt at one task.
Nobody answers questions during the run. The script does all bookkeeping: it ticks PLAN.md,
commits run state, saves a failed attempt's work under `refs/wip/<task>/<attempt>` and resets the
worktrees, runs the checks after you say DONE, and starts the next attempt or task. The SPEC is
below this file; CONTEXT.md and your notes file are in the first message: don't re-read them.

## Where you work
- This worktree: `~/src/preview-agent`, branch `agent/preview` (of `~/.config/nvim`).
- Neovide: only `~/src/neovide-agent`, branch `agent/preview` (off `webview`). Don't touch
  `~/src/neovide`, never commit on `webview`, never install (no copy into
  `~/.local/share/neovide-patched`, no codesign), don't regenerate `neovide-webview.patch`. Before a
  commit there: `cargo test --release`, `cargo clippy --release`, `cargo fmt --check` pass. Commit
  as Egor Denisov, no AI attribution.
- The E2E (end-to-end) dev instance is `~/src/neovide-agent/target/release/neovide` with the isolated
  init from the recipe; never post global input events, never capture the whole screen.
- Never change `~/.config/nvim`, `~/src/neovide` or `neovide-patched`: the script stops the whole run
  when they change. Never push, tag, delete/move branches, edit git config or worktrees.
- No subagents, no workflows: do the work yourself.
- `mdpreview/CLAUDE.md` (after P2: `preview/CLAUDE.md` and `preview/docs/`) has the Neovide API,
  protocol, keyboard model, build/test, the E2E recipe, the smoothness probe and pitfalls. Its
  commit/install steps for Neovide are replaced by the rules above.

## The attempt
- run.py may resume this session with a message: after a usage limit (continue where you stopped),
  when your answer had no status line, or when its check after your DONE failed (the failure is in
  the message: fix it in place, don't start over).
- Read the notes first; never repeat an approach listed there. Earlier attempts' work is kept:
  `git log -p refs/wip/<task>/<n>` (and in `~/src/neovide-agent`); reuse what was right in it.
- With a second opinion in the message: start by checking the assumptions it names.
- Done = the checks covering the task ran green (exit codes): `preview/test/run.sh fast` once it
  exists, plus the suite or measurement that covers the task. Commit your work (conventional
  message) in both repos. The script then runs `run.sh fast` and the suites of the last passed gate
  itself; if they fail, the attempt counts as failed.
- Not done: append to the notes file what you tried, why it failed and your best hypothesis (at
  most 15 lines), then return FAILED. Don't clean up or reset: the script saves and resets.
- Environment broken (`run.sh` exit 3, a black or uniform screenshot, the dev instance won't start,
  the screen is locked): stop at once and return ENV with what you saw. Don't retry or work around it.
- A decision outside SPEC, a permission, hardware: don't guess, return NEEDS-EGOR with the exact
  question (the task is parked until Egor answers in the notes file).
- Two reasonable options: pick one, one line in `preview/work/DECISIONS.md` (what, why, how to
  revert); don't deliberate.

## Shared files (`preview/work/`)
- `CONTEXT.md`: what the next session would otherwise re-discover (where things are, exact
  build/test commands, gotchas). Update it before you return, also when you failed. At most 150
  lines: replace and condense, don't append forever.
- `notes/<task>.md`: yours, see above. `DECISIONS.md`, `PENDING.md`: append.
- `PLAN.md`, `PROGRESS.md`, `BLOCKED.md`, `STOP.md` are the script's: never edit them.

## Protected files
- always: `preview/agent/**`
- after GATE P1: everything under `preview/test/` except `preview/test/unit/`,
  `preview/test/adapter.lua` and the PDF parts below (runner, drivers, image diff, probe, fixtures,
  markdown scenarios, goldens, baseline, thresholds).
- after GATE P3a: `preview/test/pdf/` (corpus), `preview/test/thresholds/pdf.json`.
- after GATE P3b: `preview/test/e2e/pdf/`, `preview/test/golden/pdf/`, `preview/test/adapter.lua`.
- In P3b a PDF scenario may change only when it is wrong, never to make a weak implementation pass:
  one line per change in DECISIONS.md, `TEST CHANGE: <file>: <what was wrong>; not weaker because <why>`.
  The gate review checks each one.

Hooks enforce this: edits are refused, shell changes are restored after each command (untracked
files in protected directories are deleted). Never try to get around them; if a protected file
looks wrong, write why in PENDING.md and go on.

## Files
- Test artifacts, logs, LaTeX intermediates, scratch: `preview/test/out/` only (gitignored).
- `dist/`, `.build/`, `node_modules/` are gitignored; never commit generated bundles.
- A PDF spike/reference page lives in `preview/spike/` until P4 removes it.

## Tokens
- Quiet commands, failures only: `cargo build --release -q --message-format short 2>&1 | tail -30`,
  `node build.mjs 2>&1 | tail -20`; `run.sh` already prints only the first failure. A long build:
  raise the Bash timeout (up to 10 min) or run it in the background.
- grep first, then read files by range. Never read lockfiles or whole large files; never diff
  `package-lock.json`.
- Open an image only when a visual check fails, and then the cropped diff `run.sh` wrote, not a full frame.
- Don't re-derive what CONTEXT.md and the notes already say.

## Answer (your last message, at most 10 lines)
The first line is exactly one word: `DONE`, `FAILED`, `ENV` or `NEEDS-EGOR`. Then: what changed
(files, commits in which repo); checks run with exit codes; for FAILED the hypothesis; for
NEEDS-EGOR the question.
