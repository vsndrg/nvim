# Issue draft — neovide/neovide

**Title:** macOS/Metal: key autorepeat rate intermittently halves while holding a key — repeats are coalesced by the OS when the event thread is busy in `nextDrawable()`

---

**Describe the bug**

While holding `h`/`j`/`k`/`l` in normal mode, cursor movement intermittently slows down to exactly half the configured key repeat rate. The inter-key interval, as observed inside Neovim, jumps from the normal 16.7 ms to a clean 33.4 ms — every second autorepeat is missing. The regime can flip mid-hold: one part of a single key hold runs at full rate, the rest at half rate. Frame rate is unaffected (profiler shows a steady 120 FPS during episodes); rendering stays smooth, only input is degraded.

I traced this down to the delivery layer with measurements at four points of the input pipeline (details below): the WindowServer generates and offers every repeat on time, but the events that reach `NSApplication.sendEvent:` are already thinned out. The loss happens system-side, and it correlates precisely with the app's main-thread event-dispatch latency: when latency stays under roughly one display frame (~8.3 ms at 120 Hz), all repeats arrive; once it crosses that threshold, macOS silently coalesces every second pending autorepeat (repeats are not queued up for a slow consumer — likely the same protection that prevents a frozen app from spewing buffered characters on recovery; I found no public documentation for this behavior).

With the Metal renderer that latency is structural: `VSync::MacosMetal()` provides no active pacing (`wait_for_vsync()` is a no-op, `uses_winit_throttling()` is false), so the only thing that throttles rendering is the **blocking `nextDrawable()`** call — executed on the winit event thread. Rendering plus that block keep the main thread busy ~6–10 ms of every 8.3 ms frame, so dispatch latency rides right at the OS threshold and slowly phase-drifts across it (the keyboard repeat clock and the display clock are independent), which is why the halving comes and goes unpredictably mid-hold.

This may be the root cause of #1336.

**To Reproduce**

Hard to reproduce deterministically — it depends on dispatch-latency phase drift. **A fast key repeat is likely a precondition**: I run `defaults write -g KeyRepeat -int 1` (~16.7 ms effective interval; macOS quantizes autorepeat to 60 Hz ticks, so this is also what a terminal frontend measures). With the default, much slower repeat rate the pending-event window that triggers the coalescing may never occur. What worked for me: ProMotion display at adaptive 120 Hz, any Rust file with rust-analyzer attached (though LSP/CPU load turned out to be irrelevant), hold `j`/`k` for a few seconds repeatedly; episodes typically show up within minutes. Detection is easiest with a `vim.on_key`-based recorder measuring inter-key gaps (mine auto-captured a histogram whenever the p50 gap exceeded 1.7× the burst's own p10).

**Expected behavior**

Held keys repeat at the OS-configured rate (`KeyRepeat=1`, ~16.7 ms effective) regardless of what the renderer is doing, as they do in terminal frontends on the same machine.

**Evidence (four-point bracket, one 2.4 s `l`-hold during an episode)**

| Observation point | Events | Intervals |
|---|---|---|
| CGEventTap at the WindowServer session (listen-only, post-Karabiner) | **82** | all 16.7 ms |
| `NSApplication.sendEvent:` (instrumented winit build) | **47** | 10×16.7 + 35×33.4 ms |
| `NSView.keyDown:` → winit `KeyboardInput` | **47** — identical timestamp set | — |
| Neovim (`vim.on_key`) | 47 | matches |

Zero loss inside the app: the `sendEvent:` and `keyDown:` streams are diff-identical across whole sessions. The missing events are absent from the delivered stream entirely — the HID timestamps of the survivors are 33.4 ms apart, so the intermediate events were never delivered late; they were dropped/coalesced before the run-loop dequeue.

Dispatch latency, measured as (dequeue time − NSEvent HID timestamp, same mach clock): ~6.5 ms during clean stretches, ~9.5 ms during halved stretches — the regime flips exactly with that level. Additionally, every gap bin I ever captured (16.7 / 25 / 33.4 / 41.6 / 58.3 ms) is a multiple of the 8.3 ms frame, i.e. event dequeue is frame-quantized by the busy main thread.

Ruled out with measurements: Neovim config / plugin cost (key→CursorMoved p95 ≤ 0.5 ms during episodes), rust-analyzer / CPU load (episodes at load average 1.66), Karabiner-Elements (tap sits downstream of it and sees a full stream; also reproduced with Karabiner disabled), ProMotion refresh switching (120 FPS held steady during episodes), winit's IME state machine (every `keyDown:` that arrived was emitted, IME state `Disabled` throughout), cursor animation (keys are physically missing, not late-rendered).

**Fix**

PR: [link] — switch the Metal renderer's vsync from the passive `VSync::MacosMetal()` to the CVDisplayLink-driven `VSync::MacosDisplayLink` that the OpenGL path already uses on macOS. Rendering then starts right after the vsync tick, when a drawable has just been freed, so `nextDrawable()` returns immediately and the event thread stays responsive; `displaySyncEnabled` remains on, so presentation stays aligned with refresh. With the patch, dispatch latency stays well under the threshold and I could not reproduce a single episode in extended daily use (previously: several episodes per hour), with scrolling as smooth as before.

Note that `--no-vsync` is *not* a workaround: it swaps pacing to a software timer at `g:neovide_refresh_rate` (default 60), which makes scrolling visibly choppy on a 120 Hz display.

**Desktop (please complete the following information):**
 - OS: macOS 26.5.2 (25F84), MacBook Pro, ProMotion display (adaptive 24–120 Hz)
 - Neovide Version: 0.16.2 (Homebrew), reproduced identically on a source build; code path unchanged on current `main`
 - Neovim Version: 0.12.2

**Please run `neovide --log` and paste the contents of the log file here if it exists**

Not applicable — the standard log shows nothing relevant (the loss is upstream of Neovide's keyboard handling); the data above comes from an instrumented winit build and an external event tap.
