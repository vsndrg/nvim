// Keyboard scrolling: velocity-based while a key is held (starts on keydown,
// no key-repeat delay) and eased animated jumps for page/half-page/top/bottom.

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
let lastT = 0;
let onScroll = () => {};

function maxY() {
  return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
}

function clamp(y) {
  return Math.min(Math.max(y, 0), maxY());
}

function frame(t) {
  const dt = Math.min(0.05, (t - lastT) / 1000);
  lastT = t;
  let active = false;

  if (holdDir) {
    const stopping = releasing && travelled >= MIN_STEP;
    if (stopping) {
      velocity *= Math.exp(-dt / DECAY);
    } else {
      velocity += (holdDir * SPEED - velocity) * (1 - Math.exp(-dt / RAMP));
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
  window.scrollTo(0, cur);
  onScroll();
  rafId = active ? requestAnimationFrame(frame) : 0;
}

function ensureLoop() {
  if (!rafId) {
    cur = window.scrollY;
    lastT = performance.now();
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
  }
}

// One "line" for scroll requests from nvim (count-prefixed j/k): about one tap.
export const LINE_STEP = 80;
