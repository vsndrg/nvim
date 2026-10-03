# Plan

The agent takes the first unchecked task, does it, checks it, commits, ticks it, writes one line to
`PROGRESS.md`, and ends the iteration. A phase ends at its gate; a green gate is merged into main.

## P0 Spike: pdf.js inside the existing webview -> `preview/docs/adr/001-pdf-in-webview.md`
- [ ] Minimal pdf.js page loaded through `neovide.webview.open` in the dev Neovide.
- [ ] Worker off the main thread: which mechanism works (see SPEC, preference order).
- [ ] How the page reads PDF bytes by URL; reload with cache-busting.
- [ ] `PDFViewer` + `viewport.js` keyboard motion: visible pages follow, probe shows no new stalls.
- [ ] ADR written. If a Neovide change is needed: implement it generic, tests/clippy/fmt, patch regenerated.
Gate: ADR exists and states measured results, not expectations.

## P1 Characterization (safety net before refactoring)
- [ ] Node tests: scroller, scroll-sync, render (source map), find.
- [ ] Lua tests in headless nvim: sessions, modes, alternate file, retarget, set_win_local leak.
- [ ] E2E scripts (`test/e2e/`) per CLAUDE.md recipe: isolated dev instance, socket, window-only
      screenshot, real keys via postToPid. Scenarios: open, scroll keys, find, links, file switch and back,
      `<C-b>`, theme switch, focus release (no beep path).
- [ ] Goldens captured from current HEAD; run the E2E suite 3x, set diff thresholds above measured noise.
- [ ] Bench + probe baseline recorded in `test/baseline.md`.
Gate: all suites green 3 runs in a row. After merge, tests/goldens/thresholds become protected.

## P2 Refactor: core + markdown provider
- [ ] Extract web runtime vs markdown renderer; separate bundles.
- [ ] Extract Lua core vs markdown provider per SPEC contract.
- [ ] Move into `preview/` (see SPEC home), lazy spec updated, `mdpreview/` removed, `:MdPreview*` aliases.
- [ ] `preview/CLAUDE.md` from the mdpreview one, short; Pitfalls moved to `preview/docs/pitfalls.md`.
Gate: P1 suite green, perf within baseline noise, grep check, reviewer subagent approves against SPEC.

## P3 PDF provider
- [ ] Corpus in `test/pdf/` (+ expected `pdftotext` output, `pdftoppm` references), see HARNESS.
- [ ] Bundle pdf.js, cmaps, standard fonts; view-only buffer via `BufReadCmd`.
- [ ] Render + virtualisation + fit-width; `zi` / `zo` zoom around the viewport centre.
- [ ] Keyboard motions through shared scroller; trackpad native.
- [ ] Text layer, selection, Cmd+C.
- [ ] Find via `PDFFindController`, shared keys and protocol.
- [ ] Links (internal / external).
- [ ] File watch + reload with position restore and partial-write safety.
- [ ] Large-document memory and time-to-first-page thresholds fixed and met.
Gate: all SPEC automated criteria green, reviewer approves.

## P4 Polish
- [ ] Perf pass with the probe on PDF; docs; dead code removed.
Gate: full suite green 3x; notify Egor for the subjective check.
