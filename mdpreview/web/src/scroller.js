// Scrolling motions, computed ahead as trajectories and played by viewport.js
// on the compositor: hold j/k = velocity (starts on keydown, no key-repeat
// delay), d/u/f/b/gg/G = eased jumps. Wheel and trackpad scroll natively.
//
// Trajectories are sampled once per display frame. At full speed a frame moves
// a whole number of pixels and every motion comes to rest on a whole pixel, so
// text is never shown at a fractional offset while it stands still.
import * as vp from './viewport.js';

const SPEED = 1500; // px/s at full speed while j/k is held
const RAMP = 0.05; // s, time constant to reach full speed
const DECAY = 0.045; // s, time constant to stop after release
const MIN_STEP = 36; // px a single tap covers before easing out (~70px total)
const JUMP_TAU = 0.06; // s, time constant of animated jumps
const HORIZON = 120; // s, longest planned stretch of a held key

let holdDir = 0;
let holdFrom = 0; // offset where the current hold started
let jumpTarget = null;

// Full speed, rounded so that one frame moves a whole number of pixels. The
// step only changes when the refresh rate does: 1500 px/s at 120 Hz is 12.5 px,
// and plain rounding would flip between 12 and 13 with every period estimate.
let fullStep = 0;

function fullSpeed(h) {
  const exact = (SPEED * h) / 1000;
  if (Math.abs(exact - fullStep) > 1) fullStep = Math.max(1, Math.round(exact));
  return (fullStep * 1000) / h;
}

// Samples `step(x, v, dt) -> [x, v] | null` from the current state, one per
// frame, until it returns null (motion over) or reaches an end of the page,
// and plays the result.
function simulate(step) {
  const h = vp.framePeriod();
  const dt = h / 1000;
  const max = vp.maxY();
  // Planned from the handoff time on (see viewport.js).
  const th = vp.handoffTime();
  let x = vp.y(th);
  let v = vp.velocity(th);
  const xs = [x];
  for (let t = 0; t < HORIZON; t += dt) {
    const next = step(x, v, dt);
    if (!next) break;
    [x, v] = next;
    if (x <= 0 || x >= max) {
      xs.push(Math.min(Math.max(x, 0), max));
      break;
    }
    xs.push(x);
  }
  vp.play(xs, h);
}

// Exponential approach to `stopAt`, starting with velocity `v0` when it heads
// that way (critically damped join), else as a plain ease-out.
function settle(x0, v0, stopAt, tau) {
  const a = x0 - stopAt;
  const c = Math.abs(v0) < 1 || Math.sign(v0) !== Math.sign(-a) ? 0 : v0 + a / tau;
  let t = 0;
  return (x, v, dt) => {
    if (x === stopAt) return null;
    t += dt;
    const nx = stopAt + (a + c * t) * Math.exp(-t / tau);
    // Never overshoot and swing back: arriving fast just ends the motion.
    const passed = Math.sign(nx - stopAt) !== Math.sign(a);
    return passed || Math.abs(nx - stopAt) < 0.3 ? [stopAt, 0] : [nx, (nx - x) / dt];
  };
}

// Coasting to a stop from (x, v): lands on a whole pixel about v * DECAY away.
function coast(x, v) {
  const stopAt = Math.round(x + v * DECAY);
  const tau = stopAt !== x && Math.sign(stopAt - x) === Math.sign(v) ? (stopAt - x) / v : DECAY;
  let t = 0;
  return (cx, cv, dt) => {
    if (cx === stopAt) return null;
    t += dt;
    const nx = stopAt + (x - stopAt) * Math.exp(-t / tau);
    return Math.abs(nx - stopAt) < 0.3 ? [stopAt, 0] : [nx, (nx - cx) / dt];
  };
}

// Accelerates towards full speed in `dir`. With `until` set, coasts to a stop
// once the hold has covered `until` px.
function hold(dir, until = null) {
  const full = dir * fullSpeed(vp.framePeriod());
  let coasting = null;
  simulate((x, v, dt) => {
    if (!coasting && until != null && Math.abs(x - holdFrom) >= until) coasting = coast(x, v);
    if (coasting) return coasting(x, v, dt);
    let nv = v + (full - v) * (1 - Math.exp(-dt / RAMP));
    // Land exactly on full speed so the steps become constant.
    if (Math.abs(full - nv) < Math.abs(full) * 0.01) nv = full;
    return [x + nv * dt, nv];
  });
}

// The public calls record the intent at once and plan the motion at the next
// frame (see atFrame in viewport.js).

export function holdStart(dir) {
  if (holdDir === dir) return;
  jumpTarget = null;
  holdDir = dir;
  vp.atFrame(() => {
    holdFrom = vp.y(vp.handoffTime());
    hold(dir);
  });
}

export function holdEnd(dir) {
  if (!holdDir || (dir !== undefined && holdDir !== dir)) return;
  const d = holdDir;
  holdDir = 0;
  vp.atFrame(() => {
    // A tap still covers MIN_STEP before easing out.
    const th = vp.handoffTime();
    if (Math.abs(vp.y(th) - holdFrom) < MIN_STEP) hold(d, MIN_STEP);
    else simulate(coast(vp.y(th), vp.velocity(th)));
  });
}

export function jumpBy(dy) {
  const base = jumpTarget != null && vp.isMoving() ? jumpTarget : vp.y();
  jumpTo(base + dy);
}

export function jumpTo(y) {
  holdDir = 0;
  const target = Math.round(vp.clampY(y));
  jumpTarget = target;
  vp.atFrame(() => simulate(settle(vp.y(vp.handoffTime()), vp.velocity(vp.handoffTime()), target, JUMP_TAU)));
}

// Ends the motion in flight where it is headed, at once (a held key is
// released first).
export function finishNow() {
  if (holdDir) holdEnd();
  jumpTarget = null;
  vp.settle();
}

// Stops the current motion where it is by the time this reaches the screen.
export function cancel() {
  holdDir = 0;
  jumpTarget = null;
  if (vp.isMoving()) vp.atFrame(() => simulate(() => null));
}

// One "line" for scroll requests from nvim (count-prefixed j/k): about one tap.
export const LINE_STEP = 80;
