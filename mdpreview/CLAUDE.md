# mdpreview

Graphical markdown preview **inside Neovide** (VSCode/GitHub-like). A native `WKWebView` is overlaid
on an nvim window by a patched Neovide; rendering is done by a JS page; Lua glues the two.
macOS + patched Neovide only. In any other UI `<leader>mp` shows a single notification and does nothing.

## Layout

| Path | What |
|---|---|
| `lua/mdpreview/init.lua` | sessions, modes, autocmds, keymaps, message handlers |
| `lua/mdpreview/theme.lua` | themes `github` / `vscode` / `colorscheme` (CSS vars from highlight groups) |
| `lua/mdpreview/build.lua` | `:MdPreviewBuild` (`npm ci` + `node build.mjs`), auto-build when `web/dist` is missing |
| `web/src/render.js` | markdown-it + plugins (GFM, alerts, footnotes, emoji, front matter, KaTeX, mermaid, hljs), `data-line` source map |
| `web/src/main.js` | page runtime: message dispatcher, DOM diff (morphdom), mouse, keys, theming |
| `web/src/scroll-sync.js` | source line ↔ scroll offset (port of VSCode's `scroll-sync.ts`) |
| `web/src/scroller.js` | keyboard scrolling: hold j/k = velocity, d/u/f/b/gg/G = eased jumps |
| `web/src/mermaid.js`, `find.js` | lazy mermaid with SVG cache; in-page search |
| `web/themes/*.css` | `themes.css` maps every theme onto github-markdown-css variables; `preview.css` page chrome |
| `web/build.mjs` | esbuild IIFE bundles → `web/dist/` (gitignored), plus `dist/dev.html` fed with `test/kitchen-sink.md` |
| `test/` | `kitchen-sink.md` (every feature), `other.md` (cross-file links) |
| `neovide-webview.patch` | the Neovide side as a diff (`git diff metal-displaylink-vsync..webview` in `~/src/neovide`) |

The plugin is loaded by `lua/plugins/mdpreview.lua` (lazy `dir =` spec, `ft = markdown`).

## Neovide side (`~/src/neovide`, branch `webview`)

- Lua API `neovide.webview.{open(id, winid, path), set_window(id, winid), post(id, json), focus(id, bool, keys), close(id), on_message[id]}`.
  It is generic, so there is nothing markdown-specific in Neovide.
- `src/platform/macos/webview.rs`:
  - every frame the view is moved onto the window's pixel rect;
  - it is hidden when the window isn't displayed;
  - it is masked under floating windows (`CAShapeLayer`).
- `win_pos` carries the window handle down to `RenderedWindow.window_handle`. Without it, a winid can't be matched to a grid.
- `KeyRoutingWebView`: only the keys passed to `focus(..., keys)` plus Cmd+C/Cmd+A reach the page. Every other key event goes synchronously from `keyDown:` to the editor view. `resignFirstResponder` posts `{"type":"blur"}`.
- After changing Neovide:
  1. Run `cargo test --release`, `cargo clippy --release` and `cargo fmt --check`, then commit on `webview`. Commit as Egor Denisov, with no AI attribution.
  2. Regenerate `neovide-webview.patch`.
  3. Install: `cp target/release/neovide …/Neovide.app/Contents/MacOS/neovide.new && mv` over the old binary (atomic, so running instances keep working), then `codesign --force --deep -s -` the `.app`. The app bundle is at `~/.local/share/neovide-patched/Neovide.app`; `~/.local/bin/neovide-patched` is a wrapper that execs it.
  4. Restart Neovide. Running instances keep the old binary.

## Message protocol (JSON strings)

nvim → page (`neovide.webview.post` → `window.neovideReceive`):
- `update {text, docDir}`
- `follow {line}` (editor topline, 0-based)
- `cursor {line}`
- `theme {name, mode, vars?}`
- `scroll {action, n}`
- `find {query, backwards}`, `findNext`, `clearFind`
- `activeLine {enabled}`
- `ownKeys {enabled}`
- `bench`

page → nvim (`webkit.messageHandlers.neovide` → `on_message`):
- `ready`
- `click {line}`, `dblclick {line}`
- `scrolled {line, echo}`
- `link {href}`
- `copy {text}`
- `toggleTask {line}`
- `blur`
- `findResult`
- `benchResult`

Lines are 0-based markdown-it `map[0]` values.

## Keyboard model

- While the view window is current in normal mode, Lua gives the webview the keyboard on `SafeState` (`set_webview_focus`, `PAGE_KEYS`). This lets JS see keydown and keyup, so held `j`/`k` scroll smoothly with no key-repeat delay.
- Neovide routes every other key to nvim natively.
- Never replay keys from JS through nvim (`nvim_input` / `exec_lua`). It races with direct input: `<Space>mp` arrived as `<Space>p`.
- Letter keys are matched by physical key (`e.code` in JS, ANSI key codes in Rust), so the RU layout works.

## Build / test

- Renderer:
  - `cd web && node build.mjs`.
  - Open `dist/dev.html#github-dark` (or `#vscode-light`, …) in a browser, or run headless Chrome (`--dump-dom --enable-logging=stderr`) to see page `console.log` output. Without a webkit handler, `post()` logs `[mdpreview →nvim] {...}`.
  - headless Chrome with `--virtual-time-budget` does not tick `requestAnimationFrame`. Test `scroller.js` in Node with stubbed `window` and rAF.
- `:MdPreview bench` reports frame pacing of a held-key scroll (`vim.g.mdpreview_bench`). Expect ~120 fps on ProMotion.
- End-to-end:
  1. Run a dev instance with an isolated init so tests can't touch the user's state (themery, sessions, clipboard): `~/src/neovide/target/release/neovide --no-fork --log FILE -- -u <mininit.lua> --listen <sock>`. A minimal init sets `mapleader = " "`, prepends this dir to `rtp` and calls `require("mdpreview").setup()`.
  2. Drive it with `nvim --server <sock> --remote-expr`.
  3. Screenshot **only that window**: get its CGWindowID from `CGWindowListCopyWindowInfo` by PID (the largest layer-0 window), then `screencapture -x -o -l <id>`. Never capture the whole screen.
  4. Send real keys with `CGEvent.postToPid(pid)`. Never post global mouse or keyboard events: the test window is usually behind the user's apps.

## Pitfalls already hit

- WebKit caps page rendering at ~60 fps unless `PreferPageRenderingUpdatesNear60FPSEnabled` is off (`set_webkit_feature`; `_features` is a *class* method).
- A heading "Mermaid" gets `id="mermaid"`, so `window.mermaid` is that element (named access) until the script loads. Don't probe the global.
- `drawsBackground = false` makes a transparent scrollbar track show Neovide behind it. The track is painted with `--page-bg`.
- A `<base href=docDir>` is set for relative images and links. Resolve our own assets (`mermaid.min.js`) from `document.currentScript`.
- No buffer-local `<Space>` mapping in the view buffer: leader is space.
- A dev Neovide started while another instance of the same channel runs can come up with no window, and webview commands are then dropped. This is intermittent, so just retry.
