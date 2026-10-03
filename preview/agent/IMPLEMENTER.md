# Implementer: one task, fresh subagent

Read, in this order and only what you need: `preview/work/CONTEXT.md`, your notes file,
`preview/agent/SPEC.md`, then the code. `mdpreview/CLAUDE.md` (after P2: `preview/CLAUDE.md` and
`preview/docs/`) has the Neovide API, protocol, keyboard model, build/test, the E2E recipe, the
smoothness probe and pitfalls: read the section you need, not the whole file.

## Overrides (they win over any CLAUDE.md)
- Neovide: only in the worktree `~/src/neovide-agent`, branch `agent/preview` (off `webview`). Don't
  touch `~/src/neovide`, never commit on `webview`, never install (no copy into
  `~/.local/share/neovide-patched`, no codesign), don't regenerate `neovide-webview.patch`. Before a
  commit there: `cargo test --release`, `cargo clippy --release`, `cargo fmt --check` pass. Commit as
  Egor Denisov, no AI attribution.
- The E2E dev instance is `~/src/neovide-agent/target/release/neovide` with the isolated init from the
  recipe; never post global input events, never capture the whole screen.
- Work in this worktree (`~/src/preview-agent`). Never change `~/.config/nvim` (the gate merge is the
  orchestrator's). Never push. A hook refuses shell commands that name `~/.config/nvim`, `~/src/neovide`
  or `neovide-patched` unless they only read.

## The attempt
- Read the notes first; never repeat an approach listed there. Attempt 3 comes with a second opinion:
  start by checking the assumptions it names.
- Done = the checks for this task ran green (exit codes): `preview/test/run.sh fast` once it exists,
  plus the suite or measurement that covers the task. Then commit (conventional message).
- Not done: `git reset --hard` to the last green commit, then append to the notes file: what you tried,
  why it failed, your best hypothesis (at most 15 lines).
- Environment broken (`run.sh` exit 3, a black or uniform screenshot, the dev instance won't start, the
  screen is locked): stop at once and return ENV with what you saw. Don't retry or work around it.
- A decision outside SPEC, a permission, hardware: don't guess, return NEEDS-EGOR with the exact question.
- Two reasonable options: pick one, one line in DECISIONS.md (what, why, how to revert); don't deliberate.

## Shared knowledge: `preview/work/CONTEXT.md`
What the next subagent would otherwise re-discover: where things are, exact build/test commands,
gotchas. Update it before you return. At most 150 lines: replace and condense, don't append forever.

## Return (at most 10 lines)
`DONE` | `FAILED` | `ENV` | `NEEDS-EGOR`; what changed (files, commits); checks run with exit codes;
for FAILED the hypothesis; for NEEDS-EGOR the question.

## Protected files
- always: `preview/agent/**`
- after GATE P1: `preview/test/run.sh`, `preview/test/e2e/md/**`, `preview/test/golden/md/**`,
  `preview/test/baseline.md`, `preview/test/thresholds/md.json`
- after GATE P3a: `preview/test/pdf/**`, `preview/test/e2e/pdf/**`, `preview/test/golden/pdf/**`,
  `preview/test/thresholds/pdf.json`
- after GATE P3b: `preview/test/adapter.lua`
- gate tags `gate/*` are pinned.

Hooks enforce this: edits are refused, shell changes are restored after each command (untracked files
in protected directories are deleted), and the gate merge is refused while the branch changes a
protected file. Never try to get around them; if a file looks wrong, write why in PENDING.md, go on.

## Files
- Test artifacts, logs, LaTeX intermediates, scratch: `preview/test/out/` only (gitignored).
- `dist/`, `.build/`, `node_modules/` are gitignored; never commit generated bundles.
- A PDF spike/reference page lives in `preview/spike/` until P4 removes it.

## Tokens
- Quiet commands, failures only: `cargo build --release -q --message-format short 2>&1 | tail -30`,
  `node build.mjs 2>&1 | tail -20`; `run.sh` already prints only the first failure. A long build: raise
  the Bash timeout (up to 10 min) or run it in the background.
- grep first, then read files by range. Never read lockfiles or whole large files; never diff
  `package-lock.json`.
- Open an image only when a visual check fails, and then the cropped diff `run.sh` wrote, not a full frame.
- Don't re-derive what CONTEXT.md and the notes already say.
