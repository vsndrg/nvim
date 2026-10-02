// Virtual scrolling. The document never scrolls natively: #content is moved by
// a transform, and every motion is a Web Animation that WebKit hands to Core
// Animation, so frames advance in the render server at every vsync.
//
// Scrolling the document instead (scrollTo per frame, WebKit's own smooth
// keyboard scrolling, even trackpad wheel events) goes through a WebContent ->
// UI process commit per frame, and at 120 Hz ~10-15 % of those commits miss
// their vsync: a frame shows twice, the next one jumps double. A running CA
// animation keeps moving whatever the commits do. Mixing the two is not an
// option: a transform and a scroll offset are applied 0-1 frames apart, so
// handing an offset from one to the other flashes for a frame.
//
// A motion is a trajectory sampled at the display frame rate. New input
// (releasing a key, the next wheel event) replaces it with one that continues
// from the current position and velocity. The replacement only shows up a few
// frames after the frame it is planned in (rAF -> commit -> UI process ->
// render server; measured ~3 frames at 120 Hz), and until then the old motion
// keeps playing. So a new trajectory repeats the old one for HANDOFF_FRAMES
// and only then departs from it: whichever of those frames it shows up in,
// the two agree. Departing at once made the content jump back by up to 12 px
// and then forward when the new motion appeared.

const HANDOFF_FRAMES = 4;

const content = () => document.getElementById('content');

let thumb = null;
let thumbScale = 0; // thumb px per content px
let rest = 0; // offset while nothing moves (whole device pixels)
let motion = null; // { t0, h, xs, anims }
let outgoing = []; // { anims, until }: replaced motions still playing underneath
let loop = 0;
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

// Offset at time `t` (default: this frame), as Core Animation shows it.
export function y(t = now()) {
  if (!motion) return rest;
  const { xs } = motion;
  const f = (t - motion.t0) / motion.h;
  if (f <= 0) return xs[0];
  if (f >= xs.length - 1) return xs[xs.length - 1];
  const i = Math.floor(f);
  return xs[i] + (xs[i + 1] - xs[i]) * (f - i);
}

// Velocity at time `t`, px/s.
export function velocity(t = now()) {
  if (!motion) return 0;
  const { xs, h } = motion;
  const i = Math.floor((t - motion.t0) / h);
  if (i < 0 || i >= xs.length - 1) return 0;
  return ((xs[i + 1] - xs[i]) / h) * 1000;
}

// The motion being played: offsets one display frame (`h` ms) apart from t0.
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

function stopAnimations() {
  if (motion) for (const a of motion.anims) a.cancel();
  for (const o of outgoing) for (const a of o.anims) a.cancel();
  outgoing = [];
}

function dropOutgoing(t) {
  outgoing = outgoing.filter((o) => {
    if (t < o.until) return true;
    for (const a of o.anims) a.cancel();
    return false;
  });
}

// Longest keyframe segment, in frames. Core Animation stalls for a frame when
// a short segment is followed by a much longer one (measured: the frame where
// a ramp joins one long constant-speed segment shows twice, the next jumps
// double); segments of up to ~100 ms are played evenly.
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
  if (motion && t - motion.t0 >= (motion.xs.length - 1) * motion.h) {
    rest = motion.xs[motion.xs.length - 1];
    stopAnimations();
    motion = null;
  }
  notify();
  loop = motion || outgoing.length ? requestAnimationFrame(frameLoop) : 0;
}

function placeThumb(offset) {
  if (thumb) thumb.style.transform = `translateY(${offset * thumbScale}px)`;
}

// Jumps to `to` at once, dropping motions not started yet.
export function setY(to) {
  pending.length = 0;
  stopAnimations();
  motion = null;
  rest = snap(clampY(to));
  content().style.transform = `translateY(${-rest}px)`;
  placeThumb(rest);
  notify();
}

// Plays offsets `xs`, one per `h` ms from handoffTime() on (xs[0] should be
// y(handoffTime())); the last one is where it comes to rest. Until then the
// current motion goes on unchanged.
export function play(xs, h) {
  const t0 = now();
  const lead = [];
  for (let i = 0; i < HANDOFF_FRAMES; i++) lead.push(y(t0 + i * h));
  xs = lead.concat(xs);
  const max = maxY();
  xs = xs.map((x) => Math.min(Math.max(x, 0), max));
  xs[xs.length - 1] = snap(xs[xs.length - 1]);
  // The current motion keeps playing underneath until the new one surely
  // shows (the new animation is created later, so it wins once it does).
  if (motion) outgoing.push({ anims: motion.anims, until: t0 + 2 * HANDOFF_FRAMES * h });
  const end = xs[xs.length - 1];
  const idx = keyframeIndices(xs);
  const offset = (i) => i / (xs.length - 1);
  const timing = { duration: (xs.length - 1) * h, easing: 'linear' };
  const el = content();
  // The underlying style is the end state: when the CA animation finishes
  // (a few frames before JS hears about it) the layer stays put.
  el.style.transform = `translateY(${-end}px)`;
  const anims = [el.animate(idx.map((i) => ({
    transform: `translateY(${-xs[i]}px)`, offset: offset(i),
  })), timing)];
  anims[0].startTime = t0;
  // The thumb gets the same motion a frame later, in a commit of its own:
  // started in the same commit, it made the content's animation start up to
  // 8 px off at 1500 px/s (measured; alone, within ~3 px).
  requestAnimationFrame(() => {
    if (motion?.anims !== anims || !thumbScale) return;
    thumb.style.transform = `translateY(${end * thumbScale}px)`;
    const ta = thumb.animate(idx.map((i) => ({
      transform: `translateY(${xs[i] * thumbScale}px)`, offset: offset(i),
    })), timing);
    ta.startTime = t0;
    anims.push(ta);
  });
  motion = { t0, h, xs, anims };
  if (!loop) loop = requestAnimationFrame(frameLoop);
}

export function stop() {
  setY(y());
}

// ------------------------------------------------------------ scrollbar

// Content or viewport size changed.
export function relayout() {
  const vh = viewHeight();
  const total = contentHeight();
  const size = total > vh ? Math.max(24, (vh * vh) / total) : 0;
  thumb.hidden = size === 0;
  thumb.style.height = `${size}px`;
  thumbScale = size ? (vh - size) / maxY() : 0;
  if (motion) return;
  const clamped = snap(clampY(rest));
  if (clamped !== rest) setY(clamped);
  else placeThumb(rest);
}

export function init() {
  const el = content();
  thumb = document.createElement('div');
  thumb.className = 'vscroll-thumb';
  const bar = document.createElement('div');
  bar.className = 'vscroll';
  bar.appendChild(thumb);
  document.body.appendChild(bar);
  el.style.transform = 'translateY(0px)';
  relayout();

  // Dragging the thumb.
  thumb.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    thumb.setPointerCapture(e.pointerId);
    const startY = e.clientY;
    const startX = y();
    const move = (ev) => {
      if (thumbScale) setY(startX + (ev.clientY - startY) / thumbScale);
    };
    const up = () => {
      thumb.removeEventListener('pointermove', move);
      thumb.removeEventListener('pointerup', up);
    };
    thumb.addEventListener('pointermove', move);
    thumb.addEventListener('pointerup', up);
  });

  new ResizeObserver(() => relayout()).observe(el);
  window.addEventListener('resize', () => relayout());
}
