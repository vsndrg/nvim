# Preview: spec

Goal: one generic, extensible, VSCode-like previewer inside Neovide. Markdown exists; PDF is the
second provider. Adding a third file type must mean writing a provider, not touching the core.

Quality bar (non-negotiable):
- No hacks, no copy-paste between providers, fix root causes. Prefer mature libraries over own code.
- No regressions in markdown: behaviour, smoothness (reference numbers: `mdpreview/CLAUDE.md`, "Measuring
  smoothness on screen"; after P2 in `preview/docs/`), keys.
- Every decision that could reasonably go either way is written to `preview/work/DECISIONS.md` (one line: what, why, how to revert).

## Scope v1

Markdown: as today, unchanged.

PDF:
- view, continuous vertical scroll, keyboard motions identical to markdown (j/k/d/u/f/b/gg/G, held keys), native trackpad;
- zoom: fit-width by default; `zi` / `zo` zoom in / out by a step, keeping the point at the viewport
  centre fixed; zoom survives reload and hide/show;
- text selection + Cmd+C (text layer);
- find: same keys and `findResult` shape as markdown;
- internal links (outline/ToC targets) jump inside the page; external links open like markdown links;
- auto-reload when the .pdf file changes on disk (not the .tex), keeping position and zoom.

Out of scope: dark mode / page inversion, SyncTeX, annotations, forms, printing.
The architecture must not prevent SyncTeX later (a provider-level `sync` hook).

## Architecture

Neovide (branch `webview`) stays a generic host: `neovide.webview.*`.
Nothing file-type-specific goes there. A Rust change is allowed only if the spike proves it
necessary (see PLAN P0), must be generic, and is made in the worktree `~/src/neovide-agent`, branch
`agent/preview` off `webview` (rules: `IMPLEMENTER.md`, which overrides `mdpreview/CLAUDE.md`'s commit and
install steps). Merging it into `webview`, regenerating `neovide-webview.patch` and installing are Egor's.

Lua:
- core: sessions, view window/buffer, modes, alternate-file handling, keyboard focus model,
  themes, message bus, hide/show/position persistence. The core contains no markdown or PDF knowledge
  (checkable: no provider names, no `markdown`/`pdf` strings in core files).
- provider (one module per type) declares:
  - which buffers it claims (filetype / extension);
  - source kind: `buffer` (text pushed on change, debounced) or `file` (path; core watches the file);
  - whether there is a separate source buffer (markdown: source <-> view swap) or the view is the
    only buffer (PDF: the binary is never loaded into a buffer, `BufReadCmd`);
  - its web bundle;
  - provider-specific message handlers (markdown: click/dblclick/toggleTask/...);
  - optional source<->view position sync (markdown only for now);
  - what "position" means for restore (markdown: line; PDF: page + offset in page + scale).
- home: `~/.config/nvim/preview/` is the generic plugin (these docs live in `preview/agent/`).
  P2 moves `mdpreview/` into it: core, providers and web runtime/renderers under `preview/`;
  `mdpreview/` is removed and the lazy spec (`lua/plugins/mdpreview.lua`) points at `preview/`.
  `:MdPreview*` and current keymaps keep working (aliases); new generic commands `:Preview*`.
  `mdpreview/CLAUDE.md` is split, nothing dropped: a short `preview/CLAUDE.md` (layout + where to read
  more) and `preview/docs/` (Neovide API, protocol, keyboard model, build/test + E2E recipe, smoothness
  probe + reference numbers, pitfalls), read on demand.

File watching (core, `file` sources): `vim.uv` fs_event on the parent directory (tools write a temp
file and rename), debounced. A truncated / half-written file must not crash or blank the view:
keep the last good render and retry on the next event.

Web:
- shared runtime: message dispatcher, `viewport.js`, `scroller.js`, keys, theme, find contract,
  position save/restore, `ready`/`blur`/`scrolled` protocol;
- renderer modules plug into it (markdown = current render/scroll-sync/mermaid; pdf = pdf.js);
- one esbuild entry per renderer; a page loads only its renderer (pdf.js must not load for markdown).

## PDF renderer (pdf.js)

- `pdfjs-dist` with its `PDFViewer` (virtualised pages, rendering queue), `EventBus`,
  `PDFLinkService`, `PDFFindController`, text layer on. Do not reimplement any of these.
- Bundle `cmaps/` and `standard_fonts/` and pass their URLs: needed for CJK and non-embedded fonts.
- The worker must run off the main thread (main-thread parsing = frame stalls). How it is loaded in
  WKWebView from a `file://` page, and how the page reads the PDF bytes (no base64 over `post`),
  is decided in the P0 spike, in this order of preference: works with no Neovide change cleanly ->
  generic `WKURLSchemeHandler` in Neovide -> `allowFileAccessFromFileURLs`.
- Scrolling: the document scroller must be the one `viewport.js` drives; verify `PDFViewer` sees
  the folded scroll position every frame (visible-page detection must not lag a motion).
- Reload: load the new document off-screen; swap when the first visible page is rendered (no flash);
  restore page/offset/scale; on parse error keep the old document.
- Page chrome (gap colour, scrollbar) follows the theme; page content is not recoloured.

## Test harness (`preview/test/`)

Fixed in P1 and protected after it, so it must already cover the later phases. Protection
(details: `IMPLEMENTER.md`, enforced by hooks): after P1 everything under `preview/test/` except
`unit/`, `adapter.lua` and the PDF parts; the PDF corpus and `thresholds/pdf.json` after P3a; the PDF
scenarios, goldens and the adapter after P3b.
- Layout: everything the harness runs lives under `preview/test/`: `run.sh`; shared drivers, image
  diff and helpers in `lib/`; the smoothness probe in `probe/`; its own copies of the fixtures in
  `fixtures/<type>/` (not the plugin's dev files: those move to `preview/dev/` in P2, outside
  `preview/test/`); scenarios in `e2e/<type>/`; `golden/<type>/`; `thresholds/<type>.json`;
  `baseline.md`; unit tests in `unit/` (stay editable). PDF-specific harness code lives in
  `e2e/pdf/`. P2's move must not need any change under `preview/test/` except `adapter.lua`.
- `run.sh fast` = build + unit tests; `run.sh env` = the environment check alone;
  `run.sh gate <phase>` = env check + every suite the phase requires.
- Exit codes: 0 green, 1 a test failed, 3 environment broken (dev instance doesn't start, screenshot
  (near-)uniform/black, screen locked, missing tool, or the display (resolution, backing scale) or
  macOS appearance differs from what the goldens were recorded with). 3 is never a test failure: the
  run stops on it.
- Output: the first failure only, at most 40 lines, plus the path of the full log in `test/out/`.
  A visual failure also writes a cropped, downscaled diff image to `test/out/` and prints its path.
- Suites are discovered by directory `e2e/<type>/`. Per phase: `gate P1`, `gate P2` -> markdown;
  `gate P3a` -> markdown + `pdf` in validate mode (corpus present, references generate, every scenario
  loads and reaches the adapter; assertions not run); `gate P3b`, `gate P4` and any later or unknown
  phase -> everything in full. From P3b a skipped test is a failure.
- Scenarios reach the plugin only through user commands/keys and the query functions of `adapter.lua`
  (the one editable seam: which module to load from where, and how to read position, scale, find
  result, selection). PDF scenarios are written in P3a against adapter functions that P3b implements.
  In P3b a scenario may change only when it is wrong, never to let a weak implementation pass: each
  change gets a `TEST CHANGE:` line in DECISIONS.md, and the gate review checks it.
- Everything generated (actual screenshots, diffs, logs, LaTeX intermediates) goes to `test/out/`
  (gitignored). Untracked files inside protected directories are deleted by a hook after every command.

## Acceptance criteria

PDF corpus (`preview/test/pdf/`): text-heavy LaTeX (the `.tex` and the PDF built from it are both
committed, so tests don't need TeX), scanned image, 500+ pages, Cyrillic + CJK, rotated pages,
internal links/outline, broken file, encrypted file.
Oracles: `pdftoppm` (render), `pdftotext` (text/find).

Automated (the agent must make these pass; see WORKFLOW.md for gates):
- markdown: P1 characterization suite green, bench/probe within noise of the P1 baseline;
- PDF render: each corpus page matches a `pdftoppm` rasterisation at the same scale within the
  perceptual threshold fixed in P1/P3;
- PDF text: find counts and selected text match `pdftotext` for the corpus queries;
- reload: atomic rename and in-place partial write -> no crash, no blank frame, position kept;
- perf: keyboard scroll on PDF meets the markdown probe reference (0 stalls, <= 6 uneven > 1 px per
  64 vsyncs); time to first page and memory on the 500+ page doc under thresholds fixed in P3a from
  the P0 measurement;
- core contains no provider knowledge (grep check), no duplicated runtime code between renderers.

Human (Egor, at the end): subjective smoothness and feel.
