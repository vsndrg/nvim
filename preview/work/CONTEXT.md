# Context

Shared by subagents: what the next one would otherwise re-discover. At most 150 lines; keep it current
(replace and condense, drop what is obsolete). Permanent facts move to preview/CLAUDE.md / docs in P2.

## Where things are
- Worktree: `~/src/preview-agent` (branch `agent/preview` of `~/.config/nvim`). Neovide: `~/src/neovide-agent`
  (branch `agent/preview` off `webview`). Both share git history with Egor's trees, which are read-only.
- Markdown previewer today: `mdpreview/`, loaded by `lua/plugins/mdpreview.lua`. `mdpreview/CLAUDE.md`
  sections: Layout, Neovide side, Message protocol, Modes and the alternate file, Keyboard model,
  Build / test, Measuring smoothness on screen (probe + reference numbers + E2E recipe), Pitfalls.
- Web build: `cd mdpreview/web && node build.mjs` -> `web/dist/` (gitignored); `npm ci` when
  `node_modules` is missing.
- Neovide build: `cd ~/src/neovide-agent && cargo build --release -q --message-format short`
  (the first build in the fresh worktree compiles all dependencies: minutes).
- Oracles: `pdftoppm`, `pdftotext` (poppler).

## Commands that work

## Gotchas
