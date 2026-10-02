# PR draft — neovide/neovide

**Title:** macos: fix intermittent key repeat halving by pacing Metal rendering with CVDisplayLink

**Branch:** `metal-displaylink-vsync` (1 commit, `src/renderer/metal.rs`, +14 −3)

---

**What does this PR do**

Fixes the intermittent halving of the key autorepeat rate on macOS with the Metal renderer (closes #NNNN — full diagnosis with measurements there; likely also #1336).

Root cause in short: with `VSync::MacosMetal()` there is no active frame pacing — `wait_for_vsync()` is a no-op and winit throttling is off — so the only throttle is the **blocking `nextDrawable()`** call, which runs on the winit event thread. While it blocks, the run loop cannot dequeue input. Measured on a 120 Hz ProMotion display, the main thread is busy ~6–10 ms of every 8.3 ms frame, and once event-dispatch latency crosses roughly one frame, macOS silently coalesces pending key autorepeats instead of queueing them — every second repeat vanishes before `NSApplication.sendEvent:`. The latency phase-drifts across that threshold, which is why the symptom appears and disappears mid-keyhold.

The change: use the CVDisplayLink-driven vsync (`VSync::MacosDisplayLink`) for the Metal renderer, exactly as the OpenGL path on macOS already does. Rendering is then scheduled right after the vsync tick — the moment a drawable has just been freed — so `nextDrawable()` returns immediately and the event thread stays responsive between ticks. `displaySyncEnabled` stays on, so presentation remains aligned with the refresh cycle; this is not `--no-vsync` (which pushes frames on a software timer and makes scrolling choppy on high-refresh displays).

**Why this is safe**

- It routes the Metal renderer through the same `VSync::MacosDisplayLink` / winit-throttling machinery the OpenGL renderer has been using on macOS, including display-change handling (`VSync::update` recreates the link when the window moves to another screen).
- CVDisplayLink is deprecated in newer SDKs, but this adds no new surface: `vsync_macos_display_link.rs` is already compiled and used for OpenGL.
- No behavior change for `--no-vsync` (still `VSync::Timer`) or for other platforms.

**Testing**

- Before: on a MacBook Pro (ProMotion, adaptive 24–120 Hz), holding `h/j/k/l` degraded to exactly 2× the repeat interval several times per hour; verified with an external CGEventTap plus probes at `sendEvent:` / `keyDown:` / Neovim (`vim.on_key`) — the WindowServer offered a full 16.7 ms stream while `sendEvent:` received a thinned one.
- After: with this patch, event-dispatch latency stays well below one frame, and no episode occurred in extended daily use with the same instrumentation active. Scrolling smoothness is unchanged (frames still aligned to refresh), animations unchanged, `--no-vsync` unchanged.
- `cargo fmt` clean; builds against current `main`.
