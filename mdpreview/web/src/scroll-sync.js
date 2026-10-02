// Source line <-> scroll offset mapping. Port of VSCode's
// extensions/markdown-language-features/preview-src/scroll-sync.ts (MIT).

let cachedElements = null;

export function invalidateLineCache() {
  cachedElements = null;
}

function getCodeLineElements() {
  if (!cachedElements) {
    cachedElements = [{ element: document.body, line: 0 }];
    for (const element of document.getElementsByClassName('code-line')) {
      const line = Number(element.getAttribute('data-line'));
      if (isNaN(line)) continue;
      // Code blocks: measure the visible <pre>, not a wrapper that may carry
      // extra decorations.
      if (element.tagName === 'CODE' && element.parentElement?.tagName === 'PRE') {
        cachedElements.push({ element: element.parentElement, line });
      } else if (element.tagName === 'UL' || element.tagName === 'OL') {
        // Lists are mapped through their items.
        continue;
      } else {
        cachedElements.push({ element, line });
      }
    }
  }
  return cachedElements;
}

function getElementBounds({ element }) {
  const myBounds = element.getBoundingClientRect();
  // Some code-line elements contain other code-line elements (blockquotes,
  // list items). Use the distance to the first child as the height.
  const codeLineChild = element.querySelector('.code-line');
  if (codeLineChild) {
    const childBounds = codeLineChild.getBoundingClientRect();
    const height = Math.max(1, childBounds.top - myBounds.top);
    return { top: myBounds.top, height };
  }
  return myBounds;
}

// Elements bracketing `targetLine` (0-based source line).
export function getElementsForSourceLine(targetLine) {
  const lineNumber = Math.floor(targetLine);
  const lines = getCodeLineElements();
  let previous = lines[0] || null;
  for (const entry of lines) {
    if (entry.line === lineNumber) {
      return { previous: entry, next: undefined };
    } else if (entry.line > lineNumber) {
      return { previous, next: entry };
    }
    previous = entry;
  }
  return { previous };
}

function getLineElementsAtPageOffset(offset) {
  const lines = getCodeLineElements().filter((x) => x.element !== document.body);
  if (lines.length === 0) return {};
  const position = offset - window.scrollY;
  let lo = -1;
  let hi = lines.length - 1;
  while (lo + 1 < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const bounds = getElementBounds(lines[mid]);
    if (bounds.top + bounds.height >= position) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  const hiElement = lines[hi];
  const hiBounds = getElementBounds(hiElement);
  if (hi >= 1 && hiBounds.top > position) {
    return { previous: lines[lo], next: hiElement };
  }
  if (hi > 1 && hi < lines.length && hiBounds.top + hiBounds.height > position) {
    return { previous: hiElement, next: lines[hi + 1] };
  }
  return { previous: hiElement };
}

// Page offset (px from document top) at which source `line` starts.
export function offsetForSourceLine(line) {
  if (line <= 0) return 0;
  const { previous, next } = getElementsForSourceLine(line);
  if (!previous) return null;
  const rect = getElementBounds(previous);
  const previousTop = rect.top;
  let scrollTo;
  if (next && next.line !== previous.line) {
    // Between two elements: interpolate.
    const betweenProgress = (line - previous.line) / (next.line - previous.line);
    const previousEnd = previousTop + rect.height;
    const betweenHeight = next.element.getBoundingClientRect().top - previousEnd;
    scrollTo = previousEnd + betweenProgress * betweenHeight;
  } else {
    const progressInElement = line - Math.floor(line);
    scrollTo = previousTop + rect.height * progressInElement;
  }
  return Math.max(0, window.scrollY + scrollTo);
}

// Fractional source line shown at page offset `offset`.
export function sourceLineForOffset(offset) {
  const { previous, next } = getLineElementsAtPageOffset(offset);
  if (!previous) return null;
  const previousBounds = getElementBounds(previous);
  const offsetFromPrevious = offset - window.scrollY - previousBounds.top;
  if (next) {
    const span = getElementBounds(next).top - previousBounds.top;
    const progress = span > 0 ? offsetFromPrevious / span : 0;
    return previous.line + progress * (next.line - previous.line);
  }
  const progress = offsetFromPrevious / previousBounds.height;
  return previous.line + Math.max(0, Math.min(1, progress));
}

export function elementForSourceLine(line) {
  const { previous } = getElementsForSourceLine(line);
  return previous && previous.element !== document.body ? previous.element : null;
}
