# Plan

Statuses: `- [ ]` open, `- [x]` done, `- [!]` blocked (reason in BLOCKED.md).
How tasks, attempts and `GATE` lines are handled: `preview/agent/WORKFLOW.md`.

## P0 Spike: pdf.js inside the existing webview
- [ ] Minimal pdf.js page loaded through `neovide.webview.open` in the dev Neovide.
- [ ] Worker off the main thread: find the mechanism that works (SPEC, preference order).
- [ ] The page reads PDF bytes by URL; reload with cache-busting.
- [ ] `PDFViewer` + `viewport.js` keyboard motion: visible pages follow, probe shows no new stalls.
- [ ] `preview/docs/adr/001-pdf-in-webview.md` with measured results. Neovide change, if needed: generic, on a branch off `webview`, tests/clippy/fmt pass.
- [ ] GATE P0

## P1 Characterization: black-box safety net for markdown
Protected after the gate, so it must survive P2's move: it talks to the plugin only through user-facing
commands/keys and `preview/test/adapter.lua` (the one place saying which module to load and from where;
stays editable). `preview/test/run.sh fast|gate <phase>` is the suite entry: exit code + failures only;
it discovers suites by directory, so P3a adds `e2e/pdf/` without editing it.
- [ ] `preview/test/run.sh` + `adapter.lua`; fast tier = build + unit tests (unit tests stay editable).
- [ ] E2E driver per the CLAUDE.md recipe (isolated dev instance, socket, window-only screenshot, postToPid keys).
- [ ] `e2e/md/` scenarios: open, j/k/d/u/f/b/gg/G, find, links, file switch and back, `<C-b>`, theme switch, focus release.
- [ ] `golden/md/` from current HEAD; suite run 3x, `thresholds/md.json` set above the measured noise.
- [ ] `baseline.md`: bench + probe numbers.
- [ ] GATE P1

## P2 Refactor: core + markdown provider
- [ ] Web: shared runtime vs markdown renderer, one bundle per renderer.
- [ ] Lua: core vs markdown provider per the SPEC contract.
- [ ] Move into `preview/` (SPEC "home"), lazy spec updated, `mdpreview/` removed, `:MdPreview*` aliases, adapter updated.
- [ ] `preview/CLAUDE.md` (short) + `preview/docs/pitfalls.md`.
- [ ] GATE P2

## P3a PDF oracles (protected after the gate)
- [ ] `test/pdf/` corpus (see SPEC) with the `.tex` sources it is built from.
- [ ] `e2e/pdf/` scenarios for every SPEC PDF criterion; references generated at check time by `pdftoppm` / `pdftotext`.
- [ ] `thresholds/pdf.json`: render diff calibrated on the P0 page; perf = the markdown probe reference.
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
- [ ] GATE P3b

## P4 Polish
- [ ] Probe pass on PDF, dead code removed, docs.
- [ ] GATE P4
