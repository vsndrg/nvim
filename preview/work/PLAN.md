# Plan

Statuses: `- [ ]` open, `- [x]` done, `- [!]` blocked (reason in BLOCKED.md).
How tasks, attempts and `GATE` lines are handled: `preview/agent/WORKFLOW.md`. Never edit the text of an
open task (the attempt counter is keyed by it); add new tasks as new lines.

## P0 Spike: pdf.js inside the existing webview
Spike code lives in `preview/spike/` (kept as a reference until P4). Neovide work: `~/src/neovide-agent`.
- [ ] Minimal pdf.js page loaded through `neovide.webview.open` in the dev Neovide.
- [ ] Worker off the main thread: find the mechanism that works (SPEC, preference order).
- [ ] The page reads PDF bytes by URL; reload with cache-busting.
- [ ] `PDFViewer` + `viewport.js` keyboard motion: visible pages follow, probe shows no new stalls.
- [ ] Measure on a generated 500+ page PDF: time to first page and memory (3 runs, median and spread).
- [ ] `preview/docs/adr/001-pdf-in-webview.md` (ADR, architecture decision record) with the measured results. Neovide change, if needed: generic, on `agent/preview` in `~/src/neovide-agent`, tests/clippy/fmt pass.
- [ ] GATE P0

## P1 Characterization: black-box safety net for markdown
Protected after the gate, so it must survive P2's move and already serve P3a/P3b: built to the SPEC
"Test harness" contract (modes, exit codes incl. 3 = environment, phase table, output budget, adapter seam).
- [ ] `preview/test/run.sh` (`fast` / `env` / `gate <phase>`) + `adapter.lua`; fast tier = build + unit tests (unit tests stay editable).
- [ ] E2E driver per the recipe in `mdpreview/CLAUDE.md` (isolated dev instance from `~/src/neovide-agent`, socket, window-only screenshot, postToPid keys); environment problems exit 3.
- [ ] `e2e/md/` scenarios: open, j/k/d/u/f/b/gg/G, find, links, file switch and back, `<C-b>`, theme switch, focus release.
- [ ] `golden/md/` from current HEAD; suite run 3x, `thresholds/md.json` set above the measured noise.
- [ ] `baseline.md`: bench + probe numbers.
- [ ] GATE P1

## P2 Refactor: core + markdown provider
- [ ] Web: shared runtime vs markdown renderer, one bundle per renderer.
- [ ] Lua: core vs markdown provider per the SPEC contract.
- [ ] Move into `preview/` (SPEC "home"), lazy spec updated, `mdpreview/` removed, `:MdPreview*` aliases, adapter updated.
- [ ] Split `mdpreview/CLAUDE.md` into a short `preview/CLAUDE.md` + `preview/docs/` (nothing dropped; SPEC "home"); fold `preview/work/CONTEXT.md` facts that are permanent into them.
- [ ] GATE P2

## P3a PDF oracles (protected after the gate)
- [ ] `test/pdf/` corpus (see SPEC) with the `.tex` sources and the PDFs built from them; intermediates in `test/out/`.
- [ ] `adapter.lua`: the PDF query functions the scenarios need (position, scale, find result, selected text), stubbed until P3b.
- [ ] `e2e/pdf/` scenarios for every SPEC PDF criterion, only through user keys/commands and adapter functions; references generated at check time by `pdftoppm` / `pdftotext` into `test/out/`.
- [ ] `thresholds/pdf.json`: render diff calibrated on the P0 spike page; perf = the markdown probe reference; time to first page and memory = the P0 ADR medians x1.5 (or above the measured spread, if larger), in DECISIONS.md.
- [ ] GATE P3a

## P3b PDF provider
- [ ] Bundle pdf.js, cmaps, standard fonts; view-only buffer via `BufReadCmd`.
- [ ] Render, virtualisation, fit-width; `zi` / `zo` around the viewport centre.
- [ ] Keyboard motions through the shared scroller; trackpad native.
- [ ] Text layer, selection, Cmd+C.
- [ ] Find via `PDFFindController`, shared keys and protocol.
- [ ] Links, internal and external.
- [ ] File watch + reload: position/zoom kept, partial writes safe.
- [ ] Large document: time to first page and memory within thresholds.
- [ ] Implement the `adapter.lua` PDF query functions (no stubs left).
- [ ] GATE P3b

## P4 Polish
- [ ] Probe pass on PDF, dead code and `preview/spike/` removed, docs.
- [ ] GATE P4
