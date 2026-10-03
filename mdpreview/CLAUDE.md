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
| `web/src/viewport.js` | scroll position: the document scrolls natively (trackpad, scrollbar, find, anchors); keyboard motions animate `#content`'s transform on the compositor (Core Animation); the scroll position follows them in whole pixels every frame with `<body>` moved back by the same distance (so the native scrollbar moves), and the rest is folded in when they end |
| `web/src/scroll-sync.js` | source line ↔ page offset (port of VSCode's `scroll-sync.ts`), offsets relative to `#content` |
| `web/src/scroller.js` | keyboard motions planned as per-frame trajectories: hold j/k = velocity, d/u/f/b/gg/G = eased jumps; wheel/trackpad input stops them |
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

## Modes and the alternate file

- Markdown files open as a preview (`setup({ auto = false })` turns this off). This applies only to normal file buffers in non-floating, non-diff windows, and not to new or empty files.
- Each buffer remembers its mode: `<CR>` / `<leader>mp` to code stays code when you come back.
- Editing another file over a preview does not close the session. It waits in `preview` mode, and the preview comes back when the source is shown again (`attach_autocmds`, `reenter_win`).
- The view buffer is never anyone's alternate file:
  - source and view are swapped with `keepalt buffer` (`swap_buf`);
  - a `BufEnter` hook turns a view-buffer alternate into its source.

  So `:e #` / `<C-b>` work exactly as for code. `nvim_win_set_buf` would make the source the alternate of its own preview.

## Keyboard model

- While the view window is current in normal mode, Lua gives the webview the keyboard on `SafeState` (`set_webview_focus`, `PAGE_KEYS`). This lets JS see keydown and keyup, so held `j`/`k` scroll smoothly with no key-repeat delay.
- Neovide routes every other key to nvim natively.
- Release focus on every way out of "view current, normal mode": `WinLeave`, `BufLeave` (`:e #` in the same window) and `ModeChanged`.
  - Why: a routed key sends `blur` before nvim has processed the key itself, so `SafeState` hands focus back to the page first.
  - If the key then leaves the view, the webview is hidden while it is first responder. Every keystroke then goes to the NSWindow and beeps.
  - `--remote-send` does not show this: test focus with real keys (`CGEvent.postToPid`).
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
- The probe reads where the `#content` layer sits (native scroll plus `viewport.js`'s transform) at each display-link tick in the UI process. A CA animation measures a perfectly even step with it, so it is trustworthy. A sample can be off when its display-link callback runs late (two neighbouring steps summing to two frames): that is the probe, not the screen.
- To measure a retarget seam, align the clocks: post `performance.now()` pings from the page and stamp them with `CACurrentMediaTime()` on arrival (min over pings). `performance.timeOrigin` can't be used: mach time stops during sleep.
- Reference numbers (2026-10, M-series ProMotion, preview mode, 64 full-speed vsyncs):
  - native scroll, old timestamp-integrating scroller: 40–45 uneven;
  - native scroll, frame-clock scroller: 14–19 uneven, all of them WebKit commit stalls/doubles;
  - compositor-driven keyboard motion (`viewport.js`): 0 stalls, 0 doubles, 0–6 uneven by >1 px (most of them probe pairs summing to two steps);
  - releasing a held key: decelerates without a seam in most runs, sometimes one step a few px off (Core Animation start offset);
  - fold at the end of a motion: no visible step;
  - native wheel scrolling (synthetic, 12 px/event per vsync): a stall+double pair every ~50 frames, as WebKit gives it.
- End-to-end:
  1. Run a dev instance with an isolated init so tests can't touch the user's state (themery, sessions, clipboard): `~/src/neovide/target/release/neovide --no-fork -- -u <mininit.lua> --listen <sock>`. A minimal init sets `mapleader = " "`, prepends this dir to `rtp` and calls `require("mdpreview").setup()`.
     - `--log` takes no value: it writes `neovide_r*.log` to the cwd, and a following word becomes a file argument.
     - Open the markdown file with `:edit` over the socket.
     - Keep the socket path under 104 bytes: a longer one is silently truncated.
  2. Drive it with `nvim --server <sock> --remote-expr`.
  3. Screenshot **only that window**: get its CGWindowID from `CGWindowListCopyWindowInfo` by PID (the largest layer-0 window), then `screencapture -x -o -l <id>`. Never capture the whole screen.
  4. Send real keys with `CGEvent.postToPid(pid)`. Never post global mouse or keyboard events: the test window is usually behind the user's apps.

## Pitfalls already hit

- WebKit caps page rendering at ~60 fps unless `PreferPageRenderingUpdatesNear60FPSEnabled` is off (`set_webkit_feature`; `_features` is a *class* method).
- A heading "Mermaid" gets `id="mermaid"`, so `window.mermaid` is that element (named access) until the script loads. Don't probe the global.
- `drawsBackground = false` makes a transparent scrollbar track show Neovide behind it. The track is painted with `--page-bg`.
- A `<base href=docDir>` is set for relative images and links. Resolve our own assets (`mermaid.min.js`) from `document.currentScript`.
- No buffer-local `<Space>` mapping in the view buffer: leader is space.
- View window options go through `set_win_local` (`scope = "local"`). `vim.wo[win].x = v` acts like `:set` and changes the global value too: `signcolumn=no`, `nonumber` and `winfixbuf` then leaked into every buffer opened later (gitsigns and line numbers disappeared).
- A dev Neovide started while another instance of the same channel runs can come up with no window, and webview commands are then dropped. This is intermittent, so just retry.
- Scroll judder at 120 Hz:
  - WebKit's rAF timestamps have 1 ms resolution and ±2 ms jitter around the vsync a frame is shown at; integrating velocity over them gave 10–16 px steps for 12.5 px/frame. Motions are planned in whole frames of an estimated refresh period, at an integral full-speed step with hysteresis (1500 px/s × 8.33 ms sits exactly on a rounding boundary).
  - Any scroll driven from WebContent misses ~10–15 % of vsyncs as stall+double pairs: JS `scrollTo` (even a trivial loop), WebKit's own smooth keyboard scrolling. Native wheel scrolling has them too, less often. CPU is not the cause (main threads 94–95 % idle), nor is Neovide. Hence keyboard motions are Web Animations on `#content`'s transform, played by Core Animation; the trackpad stays native (its input is uneven anyway, and native feels right).
- Core Animation / WebKit facts behind `viewport.js` (measured with the probe, in an isolated WKWebView host and in Neovide):
  - `scrollBy(k)` plus dropping a static `translateY(-k)` in the same rendering update are applied together: no flash. This needs `#content` in the normal flow. An earlier note here said they race, and a fixed wrapper moved by a scroll-driven animation was built around that. Both were wrong.
  - A scroll from the page while a trackpad gesture is in flight makes WebKit hold the gesture's deltas until the commit carrying that scroll is applied (~5 frames on the preview page, then one catch-up step). So the fold waits for `scrollend`. `scrollend` fires after gestures and after programmatic scrolls.
  - A new animation shows up ~4 frames after the frame it is planned in. Its time base is right, so a motion started at once loses its first frames: a jump. Motions therefore start `HANDOFF_FRAMES` later, repeating the old trajectory until then.
  - Cancelling the old animation and adding its replacement in one commit gives a stall and then a ~33 px jump. The old animation keeps playing underneath for `2 × HANDOFF_FRAMES`.
  - Core Animation holds the start of each keyframe segment for ~0.1 % of the segment's length: a 20 s segment froze for 3 frames, a 120 s one for 14. Segments are capped at 12 frames.
  - A finished CA animation reverts before JS `onfinish` runs, and `fill: 'forwards'` is not kept on the CA side. The inline style is always set to the end state.
  - `composite: 'add'` animations are not accelerated: they run on the main thread and stall like `scrollTo`.
  - Two nested layers with a correction animation don't work either: each animation has its own start offset, so the sum drifts and jumps when the layers are folded.
  - `ThreadedTimeBasedAnimationsEnabled` (WebKit feature flag, Preview, off by default) makes replacements seamless and starts immediate, but steady steps then jitter by ±1.5 px (±0.2 px with Core Animation), with an occasional stall. Not used.
- Synthetic wheel events in a test host need gesture phases (began/changed/ended) and a location in window coordinates (the `NSEvent` has no window). Without phases, WebKit takes the gesture as unfinished, and later animations start several frames late. With a wrong location, the root still scrolls but no DOM `wheel` event is dispatched.
