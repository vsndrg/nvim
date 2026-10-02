// Keyboard scrolling: velocity-based while a key is held (starts on keydown,
// no key-repeat delay) and eased animated jumps for page/half-page/top/bottom.
//
// Motion advances in whole display frames, not by rAF timestamps: WebKit's
// timestamps have 1 ms resolution and wander a couple of ms around the vsync a
// frame is shown at, so integrating velocity over them makes the per-frame
// steps uneven (10 vs 14 px at 120 Hz), which reads as judder. At full speed a
// frame moves a whole number of pixels: scroll offsets are integral, and a
// fractional step alternates (12, 13, 12, 13 px for 12.5).

const SPEED = 1500; // px/s at full speed while j/k is held
const RAMP = 0.05; // s, time constant to reach full speed
const DECAY = 0.045; // s, time constant to stop after release
const MIN_STEP = 36; // px a single tap covers before easing out (~70px total)
const JUMP_TAU = 0.06; // s, time constant of animated jumps

let cur = 0; // our own (fractional) scroll position while animating
let velocity = 0;
let holdDir = 0;
let releasing = false;
let travelled = 0;
let target = null;
let rafId = 0;
let lastT = null;
let onScroll = () => {};

// ------------------------------------------------------------ frame clock

const stamps = []; // rAF timestamps of the running animation
let period = 1000 / 120; // ms, refined from observed frames

// Display refresh period: the span of recent frames over the number of vsyncs
// in it. Timestamp jitter divides by the frame count, so the estimate settles
// to a few hundredths of a ms, and dropped frames count as the vsyncs they span.
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

// Seconds of display time since the previous frame, in whole frames.
function frameDt(t) {
  observeFrame(t);
  if (lastT == null) {
    lastT = t;
    return period / 1000;
  }
  const ms = t - lastT;
  lastT = t;
  return Math.min(0.05, Math.max(1, Math.round(ms / period)) * period / 1000);
}

// Full speed, rounded so that one frame moves a whole number of pixels. The
// step only changes when the refresh rate does: 1500 px/s at 120 Hz is 12.5 px,
// and plain rounding would flip between 12 and 13 with every period estimate.
let fullStep = 0;

function fullSpeed() {
  const frameS = period / 1000;
  const exact = SPEED * frameS;
  if (Math.abs(exact - fullStep) > 1) fullStep = Math.max(1, Math.round(exact));
  return fullStep / frameS;
}

// ---------------------------------------------------------------- motion

function maxY() {
  return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
}

function clamp(y) {
  return Math.min(Math.max(y, 0), maxY());
}

function frame(t) {
  const dt = frameDt(t);
  let active = false;

  if (holdDir) {
    const stopping = releasing && travelled >= MIN_STEP;
    if (stopping) {
      velocity *= Math.exp(-dt / DECAY);
    } else {
      const full = holdDir * fullSpeed();
      velocity += (full - velocity) * (1 - Math.exp(-dt / RAMP));
      // Land exactly on full speed so the steps become constant.
      if (Math.abs(full - velocity) < Math.abs(full) * 0.01) velocity = full;
    }
    const dy = velocity * dt;
    cur += dy;
    travelled += Math.abs(dy);
    if (stopping && Math.abs(velocity) < 15) {
      holdDir = 0;
      velocity = 0;
    } else {
      active = true;
    }
  } else if (target != null) {
    cur += (target - cur) * (1 - Math.exp(-dt / JUMP_TAU));
    if (Math.abs(target - cur) < 0.5) {
      cur = target;
      target = null;
    } else {
      active = true;
    }
  }

  cur = clamp(cur);
  window.scrollTo(0, Math.round(cur));
  onScroll();
  if (active) {
    rafId = requestAnimationFrame(frame);
  } else {
    rafId = 0;
    lastT = null;
  }
}

function ensureLoop() {
  if (!rafId) {
    cur = window.scrollY;
    lastT = null;
    stamps.length = 0;
    rafId = requestAnimationFrame(frame);
  }
}

export function setScrollListener(fn) {
  onScroll = fn;
}

export function isAnimating() {
  return rafId !== 0;
}

// Held key (j/k): repeated keydowns for the same direction are no-ops.
export function holdStart(dir) {
  if (holdDir === dir && !releasing) return;
  target = null;
  if (holdDir !== dir) velocity = 0;
  holdDir = dir;
  releasing = false;
  travelled = 0;
  ensureLoop();
}

export function holdEnd(dir) {
  if (dir === undefined || holdDir === dir) releasing = true;
}

export function jumpBy(dy) {
  const base = rafId && target != null ? target : window.scrollY;
  holdDir = 0;
  velocity = 0;
  target = clamp(base + dy);
  ensureLoop();
}

export function jumpTo(y) {
  holdDir = 0;
  velocity = 0;
  target = clamp(y);
  ensureLoop();
}

// Wheel/trackpad input takes over immediately.
export function cancel() {
  holdDir = 0;
  velocity = 0;
  target = null;
  if (rafId) {
    cancelAnimationFrame(rafId);
    rafId = 0;
    lastT = null;
  }
}

// One "line" for scroll requests from nvim (count-prefixed j/k): about one tap.
export const LINE_STEP = 80;
