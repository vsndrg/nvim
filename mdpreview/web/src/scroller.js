// Scrolling motions, computed ahead as trajectories and played by viewport.js
// on the compositor: holding j/k/d/u/f/b = velocity (starts on keydown, no
// key-repeat delay), gg/G = eased jumps. Wheel and trackpad scroll natively.
//
// Trajectories are sampled once per display frame. At full speed a frame moves
// a whole number of pixels and every motion comes to rest on a whole pixel, so
// text is never shown at a fractional offset while it stands still.
import * as vp from './viewport.js';

const SPEED = 600; // px/s at full speed while j/k is held
const RAMP = 0.005; // s, time constant to reach full speed
const DECAY = 0.005; // s, time constant to stop after release
const MIN_STEP = 36; // px a single tap covers before easing out (~55px total)
const STEP_TIME = 0.25; // s a held d/u/f/b takes per step (half page / page)
const JUMP_TAU = 0.06; // s, time constant of animated jumps
const HORIZON = 120; // s, longest planned stretch of a held key

// The key being held: { dir, step }, step null for j/k. A d/u/f/b tap lands
// exactly `step` px past `base`.
let held = null;
let holdFrom = 0; // offset where the current hold started
let jumpTarget = null;

// Full speed, rounded so that one frame moves a whole number of pixels. The
// step only changes when the refresh rate does: a speed that lands near a half
// pixel per frame (1500 px/s at 120 Hz is 12.5 px) would otherwise flip between
// two steps with every period estimate.
const fullSteps = new Map(); // speed -> px per frame

function fullSpeed(speed, h) {
  const exact = (speed * h) / 1000;
  let step = fullSteps.get(speed) ?? 0;
  if (Math.abs(exact - step) > 1) fullSteps.set(speed, (step = Math.max(1, Math.round(exact))));
  return (step * 1000) / h;
}

const holdSpeed = (step) => (step == null ? SPEED : step / STEP_TIME);

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
  const toward = Math.abs(v0) >= 1 && Math.sign(v0) === Math.sign(-a);
  // Too fast for `tau` to stop in time (a held d released near its step): a
  // plain exponential from v0 still lands without overshooting.
  if (toward && Math.abs(a) < Math.abs(v0) * tau) tau = -a / v0;
  const c = toward ? v0 + a / tau : 0;
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

// Accelerates towards `speed` in `dir`. With `until` set, coasts to a stop
// once the hold has covered `until` px.
function hold(dir, speed, until = null) {
  const full = dir * fullSpeed(speed, vp.framePeriod());
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

// `step` is the distance a tap covers (d/u/f/b), null for j/k. Key repeats
// of the held key change nothing.
export function holdStart(dir, step = null) {
  if (held && held.dir === dir && held.step === step) return;
  // Taps in quick succession add up like jumps do.
  const base = jumpTarget != null && vp.isMoving() ? jumpTarget : null;
  const h = (held = { dir, step, base });
  jumpTarget = null;
  vp.atFrame(() => {
    holdFrom = vp.y(vp.handoffTime());
    h.base ??= holdFrom;
    hold(dir, holdSpeed(step));
  });
}

export function holdEnd(dir) {
  if (!held || (dir !== undefined && held.dir !== dir)) return;
  const h = held;
  held = null;
  vp.atFrame(() => {
    const th = vp.handoffTime();
    const x = vp.y(th);
    if (h.step != null) {
      // Released short of its step: finish it, exactly.
      const target = Math.round(vp.clampY(h.base + h.dir * h.step));
      if ((target - x) * h.dir > 0) {
        jumpTarget = target;
        simulate(settle(x, vp.velocity(th), target, JUMP_TAU));
        return;
      }
    } else if (Math.abs(x - holdFrom) < MIN_STEP) {
      // A tap still covers MIN_STEP before easing out.
      hold(h.dir, SPEED, MIN_STEP);
      return;
    }
    simulate(coast(x, vp.velocity(th)));
  });
}

export function jumpBy(dy) {
  const base = jumpTarget != null && vp.isMoving() ? jumpTarget : vp.y();
  jumpTo(base + dy);
}

export function jumpTo(y) {
  held = null;
  const target = Math.round(vp.clampY(y));
  jumpTarget = target;
  vp.atFrame(() => simulate(settle(vp.y(vp.handoffTime()), vp.velocity(vp.handoffTime()), target, JUMP_TAU)));
}

// Ends the motion in flight where it is headed, at once (a held key is
// released first).
export function finishNow() {
  if (held) holdEnd();
  jumpTarget = null;
  vp.settle();
}

// Stops the current motion where it is by the time this reaches the screen.
export function cancel() {
  held = null;
  jumpTarget = null;
  if (vp.isMoving()) vp.atFrame(() => simulate(() => null));
}

// One "line" for scroll requests from nvim (count-prefixed j/k): about one tap.
export const LINE_STEP = 80;
