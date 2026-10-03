# Plan

Statuses: `- [ ]` open, `- [x]` done, `- [!]` blocked (reason in BLOCKED.md). `preview/agent/run.py`
works through it top to bottom (WORKFLOW.md); only it edits this file during a run.
A task line is `- [ ] <ID> <text>`; the ID keys attempts and the notes file
(`preview/work/notes/<ID>.md`), so never reuse one. `(needs <ID>, ...)`: blocked when one of those is.
Lines run.py adds before a gate: `<phase>.C<n>` gate check (before run.sh exists), `<phase>.F<n>`
red gate, `<phase>.R<n>` review finding, `X.F<n>` run.sh fast red at start.
To unblock a task: turn its `[!]` back into `[ ]` and answer in its notes file; it gets a fresh
attempt cap.

## P0 Spike: pdf.js inside the existing webview
Spike code lives in `preview/spike/` (kept as a reference until P4). Neovide work: `~/src/neovide-agent`.
- [ ] P0.1 Minimal pdf.js page loaded through `neovide.webview.open` in the dev Neovide.
- [ ] P0.2 Worker off the main thread: find the mechanism that works (SPEC, preference order). (needs P0.1)
- [ ] P0.3 The page reads PDF bytes by URL; reload with cache-busting. (needs P0.2)
- [ ] P0.4 `PDFViewer` + `viewport.js` keyboard motion: visible pages follow, probe shows no new stalls. (needs P0.3)
- [ ] P0.5 Measure on a generated 500+ page PDF: time to first page and memory (3 runs, median and spread). (needs P0.3)
- [ ] P0.6 `preview/docs/adr/001-pdf-in-webview.md` (ADR, architecture decision record) with the measured results. Neovide change, if needed: generic, on `agent/preview` in `~/src/neovide-agent`, tests/clippy/fmt pass. (needs P0.4, P0.5)
- [ ] GATE P0

## P1 Characterization: black-box safety net for markdown
Protected after the gate, so it must survive P2's move and already serve P3a/P3b: built to the SPEC
"Test harness" contract (layout, modes, exit codes incl. 3 = environment, phase table, output budget,
adapter seam).
- [ ] P1.1 `preview/test/run.sh` (`fast` / `env` / `gate <phase>`) + `adapter.lua`; fast tier = build + unit tests in `preview/test/unit/`.
- [ ] P1.2 E2E driver in `preview/test/lib/` per the recipe in `mdpreview/CLAUDE.md` (isolated dev instance from `~/src/neovide-agent`, socket, window-only screenshot, postToPid keys); environment problems exit 3. The probe copied into `preview/test/probe/`, fixtures into `preview/test/fixtures/md/`. (needs P1.1)
- [ ] P1.3 `e2e/md/` scenarios: open, j/k/d/u/f/b/gg/G, find, links, file switch and back, `<C-b>`, theme switch, focus release. (needs P1.2)
- [ ] P1.4 `golden/md/` from current HEAD; suite run 3x, `thresholds/md.json` set above the measured noise. (needs P1.3)
- [ ] P1.5 `baseline.md`: bench + probe numbers. (needs P1.2)
- [ ] GATE P1

## P2 Refactor: core + markdown provider
- [ ] P2.1 Web: shared runtime vs markdown renderer, one bundle per renderer.
- [ ] P2.2 Lua: core vs markdown provider per the SPEC contract.
- [ ] P2.3 Move into `preview/` (SPEC "home"), lazy spec updated, `mdpreview/` removed, its dev files in `preview/dev/`, `:MdPreview*` aliases, adapter updated; nothing else under `preview/test/` changes. (needs P2.1, P2.2)
- [ ] P2.4 Split `mdpreview/CLAUDE.md` into a short `preview/CLAUDE.md` + `preview/docs/` (nothing dropped; SPEC "home"); fold `preview/work/CONTEXT.md` facts that are permanent into them. (needs P2.3)
- [ ] GATE P2

## P3a PDF oracles (corpus and thresholds protected after the gate)
- [ ] P3a.1 `test/pdf/` corpus (see SPEC) with the `.tex` sources and the PDFs built from them; intermediates in `test/out/`.
- [ ] P3a.2 `adapter.lua`: the PDF query functions the scenarios need (position, scale, find result, selected text), stubbed until P3b.
- [ ] P3a.3 `e2e/pdf/` scenarios for every SPEC PDF criterion, only through user keys/commands and adapter functions; references generated at check time by `pdftoppm` / `pdftotext` into `test/out/`; text comparison normalisation (whitespace, ligatures, hyphenation) written down in the scenarios. (needs P3a.1, P3a.2)
- [ ] P3a.4 `thresholds/pdf.json`: render diff calibrated on the P0 spike page; perf = the markdown probe reference; time to first page and memory = the P0 ADR medians x1.5 (or above the measured spread, if larger), in DECISIONS.md. (needs P3a.3)
- [ ] GATE P3a

## P3b PDF provider
- [ ] P3b.1 Bundle pdf.js, cmaps, standard fonts; view-only buffer via `BufReadCmd`.
- [ ] P3b.2 Render, virtualisation, fit-width. (needs P3b.1)
- [ ] P3b.3 `zi` / `zo` around the viewport centre; zoom survives reload and hide/show. (needs P3b.2)
- [ ] P3b.4 Keyboard motions through the shared scroller; trackpad native. (needs P3b.2)
- [ ] P3b.5 Text layer, selection, Cmd+C. (needs P3b.2)
- [ ] P3b.6 Find via `PDFFindController`, shared keys and protocol. (needs P3b.5)
- [ ] P3b.7 Links, internal and external. (needs P3b.2)
- [ ] P3b.8 File watch + reload: position/zoom kept, partial writes safe. (needs P3b.3)
- [ ] P3b.9 Large document: time to first page and memory within thresholds. (needs P3b.2)
- [ ] P3b.10 Implement the `adapter.lua` PDF query functions (no stubs left). (needs P3b.3, P3b.5, P3b.6)
- [ ] GATE P3b

## P4 Polish
- [ ] P4.1 Probe pass on PDF, dead code and `preview/spike/` removed, docs.
- [ ] GATE P4
