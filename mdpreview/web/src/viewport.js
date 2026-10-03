// Scroll position of the preview. The document scrolls natively (trackpad,
// momentum, scrollbar, find, anchors); keyboard motions are played by Core
// Animation on top of it.
//
// Scrolling the document from the page (scrollTo per frame, and likewise
// WebKit's own keyboard scrolling) is a WebContent -> UI process commit per
// frame, and at 120 Hz ~10-15 % of those miss their vsync: a frame shows
// twice, the next one jumps double. So a keyboard motion leaves the scroll
// position alone and moves #content by an offset k, animated with a Web
// Animation that WebKit hands to Core Animation: the render server advances
// it at every vsync, whatever the commits do.
//
// When the motion is over, k is folded into the scroll position: scrollBy(k)
// and dropping the transform in one rendering update are applied together
// (measured: no flash). Not while a native scroll is in flight, though: a
// scroll from the page makes WebKit hold back the trackpad's deltas until the
// commit carrying it is applied (measured: the trackpad stalled for ~5 frames,
// then caught up in one step). Until the scroll ends, the content just stays
// offset by k.
//
// The native scrollbar shows the scroll position, so while a motion plays the
// scroll position follows it in whole pixels every frame, and <body> is moved
// back by the distance c scrolled so far, in the same rendering update: the
// content stays where the animation puts it, whenever that commit lands.
//
// A keyboard motion is a trajectory sampled at the display frame rate. New
// input (releasing a key) replaces it with one that continues from the current
// position and velocity. The replacement only shows up a few frames after the
// frame it is planned in (rAF -> commit -> UI process -> render server;
// measured ~4 frames at 120 Hz), and until then the old motion keeps playing.
// So a new trajectory repeats the old one for HANDOFF_FRAMES and only then
// departs from it: whichever of those frames it shows up in, the two agree.
// The old animation is also kept underneath for a few frames: removing it
// takes effect in the commit, the new one only from a later frame (measured:
// cancelling both in one commit showed a stall and a 33 px jump).

const HANDOFF_FRAMES = 4;

const content = () => document.getElementById('content');

let k = 0; // offset of #content from the scroll position while nothing plays
let c = 0; // distance scrolled along with the motions, <body> moved back by it
let motion = null; // { t0, h, xs, ks, anim }: xs page offsets, ks = xs - (scrollY - c)
let outgoing = []; // { anim, until }: replaced motions still playing underneath
let loop = 0;
let scrolling = false; // a native scroll is in flight (until its scrollend)
let ownY = 0; // scroll position our own scrolls left
const listeners = [];

// ------------------------------------------------------------ frame clock

const stamps = [];
let period = 1000 / 120; // ms, refined from observed frames

// Display refresh period: the span of recent frames over the number of vsyncs
// in it. WebKit's rAF timestamps have 1 ms resolution and jitter; that error
// divides by the frame count, and dropped frames count as the vsyncs they span.
function observeFrame(t) {
  stamps.push(t);
  if (stamps.length > 121) stamps.shift();
  if (stamps.length < 9) return;
  let vsyncs = 0;
  for (let i = 1; i < stamps.length; i++) {
    vsyncs += Math.max(1, Math.round((stamps[i] - stamps[i - 1]) / period));
  }
  period = Math.min(50, Math.max(4, (stamps[stamps.length - 1] - stamps[0]) / vsyncs));
}

export function framePeriod() {
  return period;
}

// This frame's time: what animations started now are timed from.
export const now = () => document.timeline.currentTime ?? performance.now();

// Time from which a motion planned now may depart from the current one.
export function handoffTime() {
  return now() + HANDOFF_FRAMES * period;
}

// ---------------------------------------------------------------- geometry

export function viewHeight() {
  return window.innerHeight;
}

export function contentHeight() {
  return content()?.offsetHeight ?? 0;
}

export function maxY() {
  return Math.max(0, contentHeight() - viewHeight());
}

export function clampY(y) {
  return Math.min(Math.max(y, 0), maxY());
}

// Resting offsets sit on whole device pixels, or text would rest blurred.
function snap(y) {
  const dpr = window.devicePixelRatio || 1;
  return Math.round(y * dpr) / dpr;
}

// Offset of `el` from the top of the content (independent of the transform).
export function pageTop(el) {
  return el.getBoundingClientRect().top - content().getBoundingClientRect().top;
}

// ----------------------------------------------------------------- state

function kAt(t) {
  if (!motion) return k;
  const { ks } = motion;
  const f = (t - motion.t0) / motion.h;
  if (f <= 0) return ks[0];
  if (f >= ks.length - 1) return ks[ks.length - 1];
  const i = Math.floor(f);
  return ks[i] + (ks[i + 1] - ks[i]) * (f - i);
}

// Page offset shown at time `t` (default: this frame).
export function y(t = now()) {
  return window.scrollY - c + kAt(t);
}

// Velocity at time `t`, px/s.
export function velocity(t = now()) {
  if (!motion) return 0;
  const { ks, h } = motion;
  const i = Math.floor((t - motion.t0) / h);
  if (i < 0 || i >= ks.length - 1) return 0;
  return ((ks[i + 1] - ks[i]) / h) * 1000;
}

// The motion being played: page offsets one display frame (`h` ms) apart.
export function plan() {
  return motion ? { xs: motion.xs, h: motion.h, t0: motion.t0 } : null;
}

export function onChange(fn) {
  listeners.push(fn);
}

function notify() {
  for (const fn of listeners) fn();
}

// Motions are planned inside a frame callback, right before WebKit commits,
// so that `now()` is the time of the frame the commit belongs to.
const pending = [];
let pendingFrame = 0;

function runPending() {
  pendingFrame = 0;
  for (const fn of pending.splice(0)) fn();
}

export function atFrame(fn) {
  pending.push(fn);
  if (!pendingFrame) pendingFrame = requestAnimationFrame(runPending);
}

export function isMoving() {
  return motion != null || pending.length > 0;
}

// ------------------------------------------------------------- rendering

function dropOutgoing(t) {
  outgoing = outgoing.filter((o) => {
    if (t < o.until) return true;
    o.anim.cancel();
    return false;
  });
}

function setK(value) {
  k = value;
  content().style.transform = value ? `translateY(${-value}px)` : '';
}

function setC(value) {
  c = value;
  document.body.style.transform = value ? `translateY(${value}px)` : '';
}

// Scrolls by `dy` from the page, telling these scrolls from native ones.
// Returns the distance actually scrolled (the page end clamps it).
function scrollOwn(dy) {
  const before = window.scrollY;
  window.scrollBy(0, dy);
  ownY = window.scrollY;
  return ownY - before;
}

// Drops the motion's animations; the content rests at offset `k`.
function finish() {
  motion?.anim.cancel();
  for (const o of outgoing) o.anim.cancel();
  outgoing = [];
  motion = null;
}

function fold() {
  if (!k && !c) return;
  scrollOwn(k - c);
  setK(0);
  setC(0);
}

// Brings the scroll position (and so the scrollbar) to where the motion is
// at time `t`.
function follow(t) {
  const d = Math.round(kAt(t) - c);
  if (d) setC(c + scrollOwn(d));
}

// Longest keyframe segment, in frames. Core Animation holds each segment's
// start for ~0.1 % of its length (measured: a 20 s constant-speed segment
// froze for 3 frames at its start, a 120 s one for 14), so a held key's long
// stretch is cut into segments short enough for that to stay far below a frame.
const MAX_SEGMENT = 12;

// Drops samples that linear interpolation between their neighbours already
// reproduces, keeping segments at most MAX_SEGMENT frames long.
function keyframeIndices(xs) {
  const keep = [0];
  for (let i = 1; i < xs.length - 1; i++) {
    const a = keep[keep.length - 1];
    const predicted = xs[a] + ((xs[i + 1] - xs[a]) * (i - a)) / (i + 1 - a);
    if (Math.abs(predicted - xs[i]) > 0.01 || i - a >= MAX_SEGMENT) keep.push(i);
  }
  if (xs.length > 1) keep.push(xs.length - 1);
  return keep;
}

function frameLoop(t) {
  observeFrame(t);
  dropOutgoing(t);
  if (motion && t - motion.t0 >= (motion.ks.length - 1) * motion.h) {
    k = motion.ks[motion.ks.length - 1];
    finish();
    if (!scrolling) fold();
  } else if (motion && !scrolling) {
    follow(t);
  }
  notify();
  loop = motion || outgoing.length ? requestAnimationFrame(frameLoop) : 0;
}

// Jumps to `to` at once, dropping motions not started yet.
export function setY(to) {
  pending.length = 0;
  finish();
  setK(0);
  setC(0);
  window.scrollTo(0, snap(clampY(to)));
  ownY = window.scrollY;
  notify();
}

// Plays offsets `xs`, one per `h` ms from handoffTime() on (xs[0] should be
// y(handoffTime())); the last one is where it comes to rest. Until then the
// current motion goes on unchanged.
export function play(xs, h) {
  const t0 = now();
  const max = maxY();
  const lead = [];
  for (let i = 0; i < HANDOFF_FRAMES; i++) lead.push(y(t0 + i * h));
  xs = lead.concat(xs).map((x) => Math.min(Math.max(x, 0), max));
  xs[xs.length - 1] = snap(xs[xs.length - 1]);
  const s = window.scrollY - c;
  const ks = xs.map((x) => x - s);
  // The current motion keeps playing underneath until the new one surely
  // shows (the new animation is created later, so it wins once it does).
  if (motion) outgoing.push({ anim: motion.anim, until: t0 + 2 * HANDOFF_FRAMES * h });
  const idx = keyframeIndices(ks);
  // The underlying style is the end state: when the CA animation finishes
  // (a few frames before JS hears about it) the layer stays put.
  setK(ks[ks.length - 1]);
  const anim = content().animate(idx.map((i) => ({
    transform: `translateY(${-ks[i]}px)`, offset: i / (ks.length - 1),
  })), { duration: (ks.length - 1) * h, easing: 'linear' });
  anim.startTime = t0;
  motion = { t0, h, xs, ks, anim };
  if (!loop) loop = requestAnimationFrame(frameLoop);
}

export function init() {
  window.addEventListener('scroll', () => {
    if (window.scrollY !== ownY) scrolling = true;
    notify();
  }, { passive: true });
  window.addEventListener('scrollend', () => {
    scrolling = false;
    if (!motion) fold();
  });
}
