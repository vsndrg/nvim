# Preview: spec

Goal: one generic, extensible, VSCode-like previewer inside Neovide. Markdown exists; PDF is the
second provider. Adding a third file type must mean writing a provider, not touching the core.

Quality bar (non-negotiable):
- No hacks, no copy-paste between providers, fix root causes. Prefer mature libraries over own code.
- No regressions in markdown: behaviour, smoothness (see CLAUDE.md reference numbers), keys.
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

Neovide (`~/src/neovide`, branch `webview`) stays a generic host: `neovide.webview.*`.
Nothing file-type-specific goes there. A Rust change is allowed only if the spike proves it
necessary (see PLAN P0), must be generic, and follows the Neovide rules in CLAUDE.md.

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
  `mdpreview/` is removed and the lazy spec in `lua/plugins/` points at `preview/`.
  `:MdPreview*` and current keymaps keep working (aliases); new generic commands `:Preview*`.

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

## Acceptance criteria

PDF corpus (`preview/test/pdf/`): text-heavy LaTeX (built from a `.tex` kept in the repo), scanned image,
500+ pages, Cyrillic + CJK, rotated pages, internal links/outline, broken file, encrypted file.
Oracles: `pdftoppm` (render), `pdftotext` (text/find).

Automated (the agent must make these pass; see WORKFLOW.md for gates):
- markdown: P1 characterization suite green, bench/probe within noise of the P1 baseline;
- PDF render: each corpus page matches a `pdftoppm` rasterisation at the same scale within the
  perceptual threshold fixed in P1/P3;
- PDF text: find counts and selected text match `pdftotext` for the corpus queries;
- reload: atomic rename and in-place partial write -> no crash, no blank frame, position kept;
- perf: keyboard scroll on PDF meets the markdown probe reference (0 stalls, <= 6 uneven > 1 px per
  64 vsyncs); time to first page and memory on the 500+ page doc under thresholds fixed in P3;
- core contains no provider knowledge (grep check), no duplicated runtime code between renderers.

Human (Egor, at the end): subjective smoothness and feel.
