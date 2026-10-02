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
| `web/src/viewport.js` | virtual scrolling: the document never scrolls, `#content` is moved by compositor (Core Animation) animations; own scrollbar |
| `web/src/scroll-sync.js` | source line ↔ page offset (port of VSCode's `scroll-sync.ts`), offsets relative to `#content` |
| `web/src/scroller.js` | motions planned as per-frame trajectories: hold j/k = velocity, d/u/f/b/gg/G = eased jumps, wheel/trackpad = smoothed follow |
| `web/src/mermaid.js`, `find.js` | lazy mermaid with SVG cache; in-page search |
| `web/themes/*.css` | `themes.css` maps every theme onto github-markdown-css variables; `preview.css` page chrome |
| `web/build.mjs` | esbuild IIFE bundles → `web/dist/` (gitignored), plus `dist/dev.html` fed with `test/kitchen-sink.md` |
| `test/` | `kitchen-sink.md` (every feature), `other.md` (cross-file links), `vsync-probe/` (on-screen smoothness probe) |
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
- `scrolled {line, echo}`: on whole-line changes while scrolling, then the exact line 100 ms after it settles
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
- `:MdPreview bench` reports frame pacing of a held-key scroll (`vim.g.mdpreview_bench`). Expect ~120 fps on ProMotion and `uneven` near 0: it counts full-speed frames whose JS scroll step differs from the median. It only sees the page side; see below for what reaches the screen.

## Measuring smoothness on screen

- rAF fps says nothing about judder. Count uneven steps per vsync instead.
- ScreenCaptureKit window capture can't be used at 120 Hz. Even a layer moved every display-link tick, or a CA animation, comes out as `0, 50, 0, 50` px steps, whether or not the window is frontmost.
- Use `test/vsync-probe/` instead:
  1. Build `probe.dylib` (command in `probe.m`).
  2. Start the dev Neovide with `DYLD_INSERT_LIBRARIES=…/probe.dylib PROBE_OUT=…/probe.tsv`. nvim inherits the variable harmlessly.
  3. Wait at least 3 s: the SIGHUP handler is installed late, and SIGHUP before that kills Neovide.
  4. Send `kill -HUP` to Neovide, run `:MdPreview bench`, and send `kill -HUP` again 2 s later.
  5. Run `analyze.py probe.tsv`.
- The probe reads the `#content` layer (or, with native scrolling, the RenderView) at each display-link tick in the UI process. A CA animation measures a perfectly even step with it, so it is trustworthy. A sample can be off when its display-link callback runs late (two neighbouring steps summing to two frames): that is the probe, not the screen.
- To measure a retarget seam, align the clocks: post `performance.now()` pings from the page and stamp them with `CACurrentMediaTime()` on arrival (min over pings). `performance.timeOrigin` can't be used: mach time stops during sleep.
- Reference numbers (2026-10, M-series ProMotion, preview mode, 64 full-speed vsyncs):
  - native scroll, old timestamp-integrating scroller: 40–45 uneven;
  - native scroll, frame-clock scroller: 14–19 uneven, all of them WebKit commit stalls/doubles;
  - compositor-driven (`viewport.js`): 0 stalls, 0 doubles, 0–4 uneven by >1 px;
  - releasing a held key: one step 0.4–8 px off (Core Animation start jitter), then smooth;
  - wheel at 12.5 px/vsync: step s.d. 0.3–0.7 px.
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
- Scroll judder at 120 Hz:
  - WebKit's rAF timestamps have 1 ms resolution and ±2 ms jitter around the vsync a frame is shown at; integrating velocity over them gave 10–16 px steps for 12.5 px/frame. Motions are planned in whole frames of an estimated refresh period, at an integral full-speed step with hysteresis (1500 px/s × 8.33 ms sits exactly on a rounding boundary).
  - Any scroll driven from WebContent misses ~10–15 % of vsyncs as stall+double pairs: JS `scrollTo` (even a trivial loop), WebKit's own smooth keyboard scrolling, synthetic wheel events. CPU is not the cause (main threads 94–95 % idle), nor is Neovide. Hence `viewport.js`: no native scrolling at all, every motion a Web Animation on `#content`'s transform, played by Core Animation.
- Core Animation / WebKit facts behind `viewport.js` (all measured with the probe):
  - Handing an offset between a transform and the native scroll position races (applied 0–1 frames apart, nondeterministically): one frame flashes the whole distance. So there is no native scroll.
  - A new animation shows up ~3 frames after the frame it is planned in, and its first shown frame can be stale. A replacement therefore repeats the old trajectory for `HANDOFF_FRAMES`, and the old animation keeps playing underneath until the new one surely shows. Replacing at once gave a −12/+31 px seam.
  - Each new animation starts with ±~5 ms jitter. That is invisible once, but visible when retargeting every frame, so wheel input retargets at most every 3 frames.
  - Starting the thumb animation in the same commit as the content's made the content's start worse (up to 8 px); per-frame thumb style writes too. The thumb animation is started one frame later.
  - A keyframe segment much longer than the one before it stalls for a frame at the join; segments are capped at 12 frames.
  - A finished CA animation reverts before JS `onfinish` runs, and `fill: 'forwards'` is not kept on the CA side. The inline style is always set to the end state.
  - `composite: 'add'` animations are not accelerated: they run on the main thread and stall like `scrollTo`.
  - Two nested layers with a correction animation don't work either: each animation has its own start offset, so the sum drifts and jumps when the layers are folded.
