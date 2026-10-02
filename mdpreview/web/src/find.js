// In-preview search: wraps matches in <mark class="find-match"> and cycles
// through them. Re-applied after every content update.
import * as vp from './viewport.js';

let query = '';
let current = -1;

function clearMarks(root) {
  for (const mark of root.querySelectorAll('mark.find-match')) {
    const parent = mark.parentNode;
    parent.replaceChild(document.createTextNode(mark.textContent), mark);
    parent.normalize();
  }
}

function collectMatches(root, needle) {
  // Smartcase, like vim with 'smartcase'.
  const caseSensitive = needle !== needle.toLowerCase();
  const n = caseSensitive ? needle : needle.toLowerCase();
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const p = node.parentElement;
      if (!p || p.closest('script, style, svg, .katex-mathml, .mermaid-source')) {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const hits = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const hay = caseSensitive ? node.data : node.data.toLowerCase();
    let i = hay.indexOf(n);
    while (i !== -1) {
      hits.push({ node, index: i });
      i = hay.indexOf(n, i + n.length);
    }
  }
  return hits;
}

function applyMarks(root) {
  clearMarks(root);
  if (!query) return [];
  const hits = collectMatches(root, query);
  // Wrap from the end so earlier offsets in the same node stay valid.
  const marks = [];
  for (let k = hits.length - 1; k >= 0; k--) {
    const { node, index } = hits[k];
    const range = document.createRange();
    range.setStart(node, index);
    range.setEnd(node, index + query.length);
    const mark = document.createElement('mark');
    mark.className = 'find-match';
    range.surroundContents(mark);
    marks.unshift(mark);
  }
  return marks;
}

function focusMatch(marks, index) {
  marks.forEach((m) => m.classList.remove('current'));
  if (marks.length === 0) return;
  current = ((index % marks.length) + marks.length) % marks.length;
  const mark = marks[current];
  mark.classList.add('current');
  vp.setY(vp.pageTop(mark) + (mark.offsetHeight - vp.viewHeight()) / 2);
}

function firstVisibleIndex(marks, backwards) {
  const top = 0;
  const bottom = window.innerHeight;
  if (!backwards) {
    const i = marks.findIndex((m) => m.getBoundingClientRect().top >= top);
    return i === -1 ? 0 : i;
  }
  for (let i = marks.length - 1; i >= 0; i--) {
    if (marks[i].getBoundingClientRect().bottom <= bottom) return i;
  }
  return marks.length - 1;
}

// Returns { total, index } for status reporting.
export function find(root, newQuery, backwards) {
  query = newQuery;
  const marks = applyMarks(root);
  focusMatch(marks, firstVisibleIndex(marks, backwards));
  return { total: marks.length, index: current + 1 };
}

export function findNext(root, backwards) {
  const marks = [...root.querySelectorAll('mark.find-match')];
  if (marks.length === 0) return { total: 0, index: 0 };
  focusMatch(marks, current + (backwards ? -1 : 1));
  return { total: marks.length, index: current + 1 };
}

export function clearFind(root) {
  query = '';
  current = -1;
  clearMarks(root);
}

// After the DOM was rebuilt: restore marks without moving the viewport.
export function reapplyFind(root) {
  if (!query) return;
  const marks = applyMarks(root);
  if (marks.length === 0) return;
  current = Math.min(Math.max(current, 0), marks.length - 1);
  marks[current].classList.add('current');
}

export function hasFind() {
  return query !== '';
}
