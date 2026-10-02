// Per-vsync probe for the preview's scroll smoothness, injected into Neovide with
// DYLD_INSERT_LIBRARIES (the ad-hoc signed build has no hardened runtime).
//
// At every display-link tick it logs where WebKit's RenderView layer sits in the UI
// process, i.e. which scroll position had been committed by that vsync. A frame whose
// commit missed its vsync shows up as a 0 step followed by a double one. SIGHUP toggles
// recording; stopping writes "<timestamp>\t<y>" rows to $PROBE_OUT. See ../../CLAUDE.md.
//
//   clang -dynamiclib -fobjc-arc -framework AppKit -framework QuartzCore probe.m -o probe.dylib
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <signal.h>

@interface MDProbe : NSObject
@property NSMutableArray<NSString *> *rows;
@property BOOL recording;
@property (weak) NSView *web;
@end

static MDProbe *probe;

static NSView *findWeb(NSView *v) {
  if ([NSStringFromClass([v class]) containsString:@"WebView"]) return v;
  for (NSView *s in v.subviews) { NSView *r = findWeb(s); if (r) return r; }
  return nil;
}

static CALayer *findRV(CALayer *l) {
  if ([l.name hasPrefix:@"RenderView"]) return l;
  for (CALayer *s in l.sublayers) { CALayer *r = findRV(s); if (r) return r; }
  return nil;
}

@implementation MDProbe
- (void)tick:(CADisplayLink *)link {
  if (!self.recording) return;
  NSView *web = self.web;
  if (!web) {
    for (NSWindow *w in NSApp.windows) { NSView *v = findWeb(w.contentView); if (v) { self.web = v; web = v; break; } }
    if (!web) return;
  }
  CALayer *root = web.layer;
  CALayer *rv = findRV(root);
  if (!rv) return;
  CALayer *pr = root.presentationLayer ?: root;
  CALayer *rp = rv.presentationLayer ?: rv;
  CGPoint p = [rp convertPoint:CGPointZero toLayer:pr];
  [self.rows addObject:[NSString stringWithFormat:@"%.6f\t%.2f", link.timestamp, p.y]];
}
@end

__attribute__((constructor)) static void init(void) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    probe = [MDProbe new];
    probe.rows = [NSMutableArray new];
    NSView *anyView = NSApp.windows.firstObject.contentView;
    for (NSWindow *w in NSApp.windows) if (w.contentView.frame.size.width > 600) anyView = w.contentView;
    CADisplayLink *link = [anyView displayLinkWithTarget:probe selector:@selector(tick:)];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    signal(SIGHUP, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
      if (probe.recording) {
        probe.recording = NO;
        NSString *out = [NSProcessInfo.processInfo.environment objectForKey:@"PROBE_OUT"];
        [[probe.rows componentsJoinedByString:@"\n"] writeToFile:out atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [probe.rows removeAllObjects];
      } else {
        probe.web = nil;
        probe.recording = YES;
      }
    });
    dispatch_resume(src);
    (void)CFBridgingRetain(src);
  });
}
