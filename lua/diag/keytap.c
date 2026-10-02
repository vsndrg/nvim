// keytap: session-level key event logger for the cursor-lag investigation.
//
// Logs every h/j/k/l keyDown seen by the WindowServer session (a listen-only
// CGEventTap), with wall-clock time, monotonic gap since the previous event,
// and the autorepeat flag. This observes the event stream *upstream* of
// Neovide: post-Karabiner, pre-app-dispatch. Comparing these gaps against
// Neovide's --log keyboard trace and nvim's cursor-lag.log locates where
// every second autorepeat disappears during an episode.
//
// Build:  cc -O2 -o ~/.local/state/nvim/keytap keytap.c \
//             -framework ApplicationServices -framework CoreFoundation
// Run:    ~/.local/state/nvim/keytap | tee -a ~/.local/state/nvim/keytap.log
//
// The terminal app running it needs Input Monitoring permission
// (System Settings -> Privacy & Security). Without it the tap fails to
// create and the tool says so instead of silently logging nothing.

#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <sys/time.h>

static uint64_t prev_ts = 0; // CGEventTimestamp is nanoseconds since boot
static CFMachPortRef g_tap = NULL;

static const char *keyname(int64_t keycode) {
    switch (keycode) {
    case 4:  return "h";
    case 38: return "j";
    case 40: return "k";
    case 37: return "l";
    default: return NULL;
    }
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        // Re-enable: listen-only taps can still be disabled by the system.
        CGEventTapEnable(g_tap, true);
        fprintf(stderr, "keytap: tap was disabled (%u), re-enabled\n", type);
        return event;
    }
    if (type != kCGEventKeyDown)
        return event;

    int64_t keycode =
        CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const char *name = keyname(keycode);
    if (!name)
        return event;

    int64_t is_repeat =
        CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat);
    uint64_t ts = CGEventGetTimestamp(event);
    double gap_ms = prev_ts ? (double)(ts - prev_ts) / 1e6 : 0.0;
    prev_ts = ts;

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);

    // "!!" marks gaps in the degraded band so episodes are easy to spot.
    printf("%02d:%02d:%02d.%03d  %s  repeat=%lld  gap=%7.1f ms%s\n",
           tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000), name,
           (long long)is_repeat, gap_ms,
           (is_repeat && gap_ms > 25.0 && gap_ms < 60.0) ? "  !!" : "");
    fflush(stdout);
    return event;
}

int main(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                             kCGEventTapOptionListenOnly, mask, tap_callback,
                             NULL);
    if (!g_tap) {
        fprintf(stderr,
                "keytap: failed to create event tap.\n"
                "Grant Input Monitoring to your terminal app in\n"
                "System Settings -> Privacy & Security -> Input Monitoring,\n"
                "then run again.\n");
        return 1;
    }

    CFRunLoopSourceRef source =
        CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);
    fprintf(stderr, "keytap: logging h/j/k/l keyDowns (Ctrl-C to stop)\n");
    CFRunLoopRun();
    return 0;
}
