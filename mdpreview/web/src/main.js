// Preview page runtime: receives messages from nvim (through Neovide's
// webview bridge) and reports user interaction back.
import morphdom from 'morphdom';
import DOMPurify from 'dompurify';
import { render } from './render.js';
import {
  invalidateLineCache, offsetForSourceLine, sourceLineForOffset, elementForSourceLine,
} from './scroll-sync.js';
import { fillCached, keepStaleDiagram, renderPending, setMermaidMode } from './mermaid.js';
import { find, findNext, clearFind, reapplyFind, hasFind } from './find.js';
import * as scroller from './scroller.js';
import { LINE_STEP } from './scroller.js';

const content = () => document.getElementById('content');

const state = {
  text: null,
  mode: null,
  // Last editor-driven scroll target (0-based fractional line); re-applied
  // after layout changes (images, diagrams) while the preview follows nvim.
  followLine: null,
  cursorLine: null,
  // Scroll events before this timestamp are echoes of programmatic scrolls.
  suppressScrollUntil: 0,
  // nvim gave the webview the keyboard (preview window is current): handle
  // scrolling keys here instead of replaying them in nvim.
  ownKeys: false,
};

function post(msg) {
  const handler = window.webkit?.messageHandlers?.neovide;
  if (handler) {
    handler.postMessage(JSON.stringify(msg));
  } else {
    console.log('[mdpreview →nvim]', JSON.stringify(msg));
  }
}

// ---------------------------------------------------------------- rendering

function setBase(docDir) {
  if (!docDir) return;
  let base = document.querySelector('base');
  if (!base) {
    base = document.createElement('base');
    document.head.prepend(base);
  }
  const href = 'file://' + encodeURI(docDir.endsWith('/') ? docDir : docDir + '/');
  if (base.getAttribute('href') !== href) base.setAttribute('href', href);
}

function buildFragment(text) {
  const html = render(text);
  const frag = DOMPurify.sanitize(html, {
    RETURN_DOM_FRAGMENT: true,
    ADD_ATTR: ['target', 'data-line', 'data-mermaid'],
    ADD_TAGS: ['semantics', 'annotation'],
  });
  const wrapper = document.createElement('div');
  wrapper.appendChild(frag);
  fillCached(wrapper);
  return wrapper;
}

function update(text, { full = false } = {}) {
  state.text = text;
  const root = content();
  const next = buildFragment(text);
  const findActive = hasFind();
  if (findActive) {
    // Marks are not part of the rendered markup; drop them so the diff is
    // minimal, then put them back.
    for (const m of root.querySelectorAll('mark.find-match')) {
      m.replaceWith(document.createTextNode(m.textContent));
    }
    root.normalize();
  }
  if (full) {
    root.replaceChildren(...next.childNodes);
  } else {
    morphdom(root, next, {
      childrenOnly: true,
      onBeforeElUpdated(fromEl, toEl) {
        if (fromEl.isEqualNode(toEl)) return false;
        return keepStaleDiagram(fromEl, toEl);
      },
    });
  }
  invalidateLineCache();
  if (findActive) reapplyFind(root);
  markActiveLine();
  refollow();
  renderPending(root, () => {
    invalidateLineCache();
    markActiveLine();
    refollow();
  });
}

// ------------------------------------------------------------- scroll sync

function scrollToY(y, behavior = 'instant') {
  state.suppressScrollUntil = performance.now() + (behavior === 'smooth' ? 600 : 80);
  window.scrollTo({ top: y, behavior });
}

function followEditor(line) {
  state.followLine = line;
  const y = offsetForSourceLine(line);
  if (y != null && Math.abs(y - window.scrollY) > 1) scrollToY(y);
}

function refollow() {
  if (state.followLine != null) followEditor(state.followLine);
}

function markActiveLine() {
  for (const el of document.querySelectorAll('.code-active-line')) {
    el.classList.remove('code-active-line');
  }
  if (state.cursorLine == null) return;
  const el = elementForSourceLine(state.cursorLine);
  el?.classList.add('code-active-line');
}

let scrollQueued = false;
window.addEventListener('scroll', () => {
  if (scrollQueued) return;
  scrollQueued = true;
  requestAnimationFrame(() => {
    scrollQueued = false;
    const echo = performance.now() < state.suppressScrollUntil;
    // A user scroll (wheel/keys) detaches the preview from the editor
    // position until nvim scrolls again.
    if (!echo) state.followLine = null;
    const line = sourceLineForOffset(window.scrollY);
    if (line != null) post({ type: 'scrolled', line, echo });
  });
}, { passive: true });

// Late-loading images shift the layout under a followed position.
document.addEventListener('load', (e) => {
  if (e.target.tagName === 'IMG') {
    invalidateLineCache();
    refollow();
  }
}, true);
window.addEventListener('resize', () => {
  invalidateLineCache();
  refollow();
});

const page = () => window.innerHeight;
const fullPage = () => page() - 2 * LINE_STEP;

// Wheel/trackpad scrolling takes over from keyboard animations.
window.addEventListener('wheel', () => scroller.cancel(), { passive: true });

// Scroll requests from nvim (its mappings run when the webview lacks focus).
function scrollAction(action, n = 1) {
  state.followLine = null;
  switch (action) {
    case 'line':
      scroller.jumpBy(n * LINE_STEP);
      break;
    case 'halfpage':
      scroller.jumpBy(n * page() / 2);
      break;
    case 'page':
      scroller.jumpBy(n * fullPage());
      break;
    case 'top':
      scroller.jumpTo(0);
      break;
    case 'bottom':
      scroller.jumpTo(Infinity);
      break;
    case 'toline':
      scroller.cancel();
      scrollToY(offsetForSourceLine(n) ?? 0, 'instant');
      // Not an echo: nvim needs this position to return to the code.
      state.suppressScrollUntil = 0;
      break;
  }
}

// --------------------------------------------------------------- theming

function applyTheme({ name, mode, vars }) {
  const html = document.documentElement;
  html.dataset.theme = name;
  html.dataset.mode = mode;
  // Drop vars from a previous colorscheme theme.
  for (const prop of [...html.style]) {
    if (prop.startsWith('--')) html.style.removeProperty(prop);
  }
  if (vars) {
    for (const [k, v] of Object.entries(vars)) html.style.setProperty(k, v);
  }
  if (state.mode !== mode) {
    const first = state.mode == null;
    state.mode = mode;
    setMermaidMode(mode);
    // Diagrams are themed at render time: rebuild them for the new mode.
    if (!first && state.text != null) update(state.text, { full: true });
  }
}

// ---------------------------------------------------------- input / mouse

function lineAtEvent(e) {
  const el = e.target.closest?.('.code-line');
  if (el) {
    const base = Number(el.dataset.line);
    const pre = el.querySelector(':scope > pre');
    // Inside a fenced block: resolve the exact source line.
    if (pre && pre.contains(e.target)) {
      const style = getComputedStyle(pre);
      const lineHeight = parseFloat(style.lineHeight) || 20;
      const top = pre.getBoundingClientRect().top + parseFloat(style.paddingTop) - pre.scrollTop;
      const row = Math.max(0, Math.floor((e.clientY - top) / lineHeight));
      const rows = (pre.textContent.match(/\n/g) || []).length;
      return base + 1 + Math.min(row, Math.max(0, rows - 1));
    }
    return base;
  }
  const line = sourceLineForOffset(window.scrollY + e.clientY);
  return line == null ? 0 : Math.floor(line);
}

function selectionText() {
  const sel = window.getSelection();
  return sel && !sel.isCollapsed ? sel.toString() : '';
}

function releaseFocus(key) {
  // nvim hands the keyboard back explicitly (ownKeys) when appropriate.
  state.ownKeys = false;
  scroller.holdEnd();
  window.getSelection()?.removeAllRanges();
  post(key ? { type: 'blur', key } : { type: 'blur' });
}

document.addEventListener('click', (e) => {
  if (e.button !== 0) return;
  const a = e.target.closest('a');
  if (a) {
    e.preventDefault();
    const href = a.getAttribute('href') ?? '';
    if (href.startsWith('#')) {
      const id = decodeURIComponent(href.slice(1));
      const target = document.getElementById(id) ?? document.getElementsByName(id)[0];
      if (target) {
        state.followLine = null;
        scrollToY(target.getBoundingClientRect().top + window.scrollY - 8, 'smooth');
      }
    } else if (href) {
      post({ type: 'link', href });
    }
    releaseFocus();
    return;
  }
  const copyButton = e.target.closest('.copy-button');
  if (copyButton) {
    const code = copyButton.parentElement.querySelector('pre code, pre');
    post({ type: 'copy', text: code?.textContent ?? '' });
    copyButton.classList.add('copied');
    setTimeout(() => copyButton.classList.remove('copied'), 1200);
    releaseFocus();
    return;
  }
  const checkbox = e.target.closest('input.task-list-item-checkbox');
  if (checkbox) {
    // The source is the truth: let nvim flip the box and re-render.
    e.preventDefault();
    const item = checkbox.closest('.task-list-item');
    post({ type: 'toggleTask', line: Number(item?.dataset.line ?? lineAtEvent(e)) });
    releaseFocus();
    return;
  }
  if (e.detail > 1) return; // part of a double click
  if (selectionText()) return; // keep focus: user is selecting text
  post({ type: 'click', line: lineAtEvent(e) });
  releaseFocus();
});

document.addEventListener('dblclick', (e) => {
  if (e.target.closest('a, .copy-button, input')) return;
  post({ type: 'dblclick', line: lineAtEvent(e) });
  releaseFocus();
});

// Translate a DOM key event into nvim key notation, so a key pressed while
// the webview had focus is replayed in nvim instead of being lost.
const SPECIAL_KEYS = {
  Enter: 'CR', Backspace: 'BS', Tab: 'Tab', Delete: 'Del', Escape: 'Esc',
  ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
  Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown', ' ': 'Space',
};

function nvimKey(e) {
  let key = SPECIAL_KEYS[e.key];
  if (!key && /^F\d+$/.test(e.key)) key = e.key;
  const special = key != null;
  if (!key) {
    if (e.key.length !== 1) return null;
    key = e.key === '<' ? 'lt' : e.key === '\\' ? 'Bslash' : e.key;
  }
  const mods = (e.ctrlKey ? 'C-' : '') + (e.altKey ? 'M-' : '') + (e.metaKey ? 'D-' : '') +
    (e.shiftKey && special ? 'S-' : '');
  if (mods || special || key === 'lt' || key === 'Bslash') return `<${mods}${key}>`;
  return key;
}

// Keys the preview handles itself while it has keyboard focus (nvim hands
// focus to the webview whenever the preview window is current). Everything
// else is replayed in nvim.
let pendingG = 0; // timestamp of a lone g

function postFindResult(r) {
  post({ type: 'findResult', ...r });
}

// Letter keys by physical position, so scrolling works in any keyboard layout.
function layoutFreeKey(e) {
  if (/^Key[A-Z]$/.test(e.code)) {
    return e.shiftKey ? e.code[3] : e.code[3].toLowerCase();
  }
  return e.key;
}

function handlePreviewKey(e) {
  const key = layoutFreeKey(e);
  // "gg" needs both presses within the mapping timeout; any other key in
  // between (routed to nvim by Neovide) leaves a stale g behind.
  const gPending = pendingG && performance.now() - pendingG < 1000;
  pendingG = 0;
  if (gPending && key === 'g') {
    scroller.jumpTo(0);
    return true;
  }
  switch (key) {
    case 'j':
    case 'ArrowDown':
      state.followLine = null;
      scroller.holdStart(1);
      return true;
    case 'k':
    case 'ArrowUp':
      state.followLine = null;
      scroller.holdStart(-1);
      return true;
    case 'd':
      scroller.jumpBy(page() / 2);
      return true;
    case 'u':
      scroller.jumpBy(-page() / 2);
      return true;
    case 'f':
    case 'PageDown':
      scroller.jumpBy(fullPage());
      return true;
    case 'b':
    case 'PageUp':
      scroller.jumpBy(-fullPage());
      return true;
    case 'G':
    case 'End':
      scroller.jumpTo(Infinity);
      return true;
    case 'Home':
      scroller.jumpTo(0);
      return true;
    case 'g':
      pendingG = performance.now();
      return true;
    case 'n':
      postFindResult(findNext(content(), false));
      return true;
    case 'N':
      postFindResult(findNext(content(), true));
      return true;
    case 'Escape':
      clearFind(content());
      window.getSelection()?.removeAllRanges();
      return true;
  }
  return false;
}

document.addEventListener('keydown', (e) => {
  if (['Shift', 'Control', 'Alt', 'Meta', 'CapsLock'].includes(e.key)) return;
  const cmdOnly = e.metaKey && !e.ctrlKey && !e.altKey;
  if (cmdOnly && e.key.toLowerCase() === 'c') {
    e.preventDefault();
    const text = selectionText();
    if (text) post({ type: 'copy', text });
    return;
  }
  if (cmdOnly && e.key.toLowerCase() === 'a') {
    e.preventDefault();
    const range = document.createRange();
    range.selectNodeContents(content());
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    return;
  }
  e.preventDefault();
  const plain = !e.ctrlKey && !e.altKey && !e.metaKey;
  if (state.ownKeys && plain && handlePreviewKey(e)) return;
  // Focus came from a mouse selection: Esc just hands the keyboard back.
  const replay = e.key === 'Escape' && !state.ownKeys ? undefined : nvimKey(e);
  releaseFocus(replay ?? undefined);
}, true);

document.addEventListener('keyup', (e) => {
  const key = layoutFreeKey(e);
  if (key === 'j' || key === 'J' || key === 'ArrowDown') scroller.holdEnd(1);
  if (key === 'k' || key === 'K' || key === 'ArrowUp') scroller.holdEnd(-1);
}, true);

// A lost keyup (focus moved mid-hold) must not leave the page scrolling.
window.addEventListener('blur', () => scroller.holdEnd());

// Diagnostics: frame pacing of a 1 s held-key scroll (`:MdPreview bench`).
function bench() {
  const gaps = [];
  let last = performance.now();
  const start = last;
  scroller.jumpTo(0);
  setTimeout(() => {
    scroller.holdStart(1);
    const tick = (t) => {
      gaps.push(t - last);
      last = t;
      if (t - start < 1300) {
        requestAnimationFrame(tick);
      } else {
        scroller.holdEnd(1);
        const g = gaps.slice(2).sort((a, b) => a - b);
        const mean = g.reduce((a, b) => a + b, 0) / g.length;
        post({
          type: 'benchResult',
          fps: Math.round(1000 / mean),
          median: +g[g.length >> 1].toFixed(2),
          p95: +g[Math.floor(g.length * 0.95)].toFixed(2),
          max: +g[g.length - 1].toFixed(2),
          frames: g.length,
        });
      }
    };
    last = performance.now();
    requestAnimationFrame(tick);
  }, 300);
}

// ------------------------------------------------------------ dispatcher

function receive(msg) {
  if (typeof msg === 'string') msg = JSON.parse(msg);
  switch (msg.type) {
    case 'update':
      setBase(msg.docDir);
      if (msg.text !== state.text) update(msg.text);
      if (msg.topline != null) followEditor(msg.topline);
      if (msg.cursor != null) {
        state.cursorLine = msg.cursor;
        markActiveLine();
      }
      break;
    case 'theme':
      applyTheme(msg);
      break;
    case 'follow':
      followEditor(msg.line);
      break;
    case 'cursor':
      state.cursorLine = msg.line;
      markActiveLine();
      break;
    case 'bench':
      bench();
      break;
    case 'ownKeys':
      state.ownKeys = !!msg.enabled;
      pendingG = 0;
      if (!state.ownKeys) scroller.holdEnd();
      break;
    case 'activeLine':
      document.documentElement.classList.toggle('show-active-line', !!msg.enabled);
      break;
    case 'scroll':
      scrollAction(msg.action, msg.n);
      break;
    case 'find': {
      const r = find(content(), msg.query, msg.backwards);
      post({ type: 'findResult', ...r });
      break;
    }
    case 'findNext': {
      const r = findNext(content(), msg.backwards);
      post({ type: 'findResult', ...r });
      break;
    }
    case 'clearFind':
      clearFind(content());
      break;
  }
}

window.nvimPreview = { receive };
// Neovide's webview bridge delivers messages as JSON strings.
window.neovideReceive = (message) => receive(JSON.parse(message));

document.addEventListener('DOMContentLoaded', () => post({ type: 'ready' }));
