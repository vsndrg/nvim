# Harness: how the autonomous run works

Built and reviewed in a supervised session BEFORE the first unattended run. The autonomous agent
never edits the harness, hooks, protected tests or thresholds.

## Isolation
- The agent works in a git worktree of `~/.config/nvim` on its own branch, never in the live config.
  Dev Neovide runs with a minimal init pointing at the worktree. Main changes only by merging a green gate.
- Neovide changes: on a branch off `webview` in `~/src/neovide`; dev binary only. Installing into
  `~/.local/share/neovide-patched/Neovide.app` is Egor's step (it is his daily editor).
- Permissions: allowlist in project `.claude/settings.json` (build, test, git, npm, cargo, nvim, the
  e2e scripts) + Claude Code sandbox; no blanket permission skipping.

## Loop
- Wrapper: each iteration is a fresh `claude -p` with the same short prompt
  ("read SPEC/PLAN/PROGRESS, do the next task, verify, commit"), bounded turns.
- State lives only in files + git: PLAN.md checkboxes, PROGRESS.md, DECISIONS.md, BLOCKED.md,
  PENDING_GOLDENS.md.
- Usage limit hit -> sleep until the reset time (parsed, else retry every ~20 min) -> continue.
- Stop: all phases done | only BLOCKED tasks left | N iterations with no new commit (anti-loop).
  Then a macOS notification (+ optional phone push).
- `caffeinate` for the whole run.

## Checks
Fast tier (Stop hook, blocks ending a red iteration; prints failures only):
build, Node tests, Lua headless tests, lint.

Gate tier (phase end): E2E + visual diffs + bench/probe + PDF oracles, then a reviewer subagent with a
fresh context that sees SPEC + diff, not the work log.

Protection (PreToolUse hook): after P1 merge, writes to `test/golden/**`, `test/pdf/**` expected data,
thresholds and `test/baseline.md` are denied. The agent records disagreements in PENDING_GOLDENS.md and
moves on; Egor decides.

## PDF corpus (`test/pdf/`)
text-heavy LaTeX (built from a `.tex` kept in the repo), scanned image, 500+ pages, Cyrillic + CJK,
rotated pages, internal links/outline, broken file, encrypted file.
Oracles: `pdftoppm` (render), `pdftotext` (text/find). Diff tool: odiff or ImageMagick `compare`.

## Token economy
English docs; one task per iteration; fresh context instead of `--resume`; test output = failures
only; screenshots opened only on failure; reviewer only at gates; CLAUDE.md kept short, details in
`docs/` read on demand.

## Egor's one-time prerequisites (macOS)
- Commit or stash current uncommitted mdpreview changes (worktree branches from HEAD).
- `brew install poppler` (+ `odiff` if chosen).
- Terminal: Screen Recording + Accessibility permissions (screenshots, postToPid).
- Overnight: on power, screen NOT locked (a locked session captures black frames -> false red gates).
