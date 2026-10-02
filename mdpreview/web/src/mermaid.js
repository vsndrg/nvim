// Lazy mermaid rendering with an SVG cache keyed by (source hash, mode), so
// re-renders on every keystroke never flash diagrams that did not change.

// Resolved at load time: once a <base> pointing at the document directory is
// installed, relative URLs no longer reach dist/.
const MERMAID_URL = new URL('mermaid.min.js', document.currentScript?.src ?? location.href).href;

const cache = new Map(); // `${mode}:${hash}` -> svg
let loading = null;
let mode = 'light';
let counter = 0;

// Never probe window.mermaid before loading: a heading "Mermaid" gets
// id="mermaid" and named element access makes window.mermaid that element.
function loadMermaid() {
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = MERMAID_URL;
      script.onload = () => resolve(window.mermaid);
      script.onerror = () => reject(new Error('failed to load mermaid.min.js'));
      document.head.appendChild(script);
    });
  }
  return loading;
}

export function setMermaidMode(newMode) {
  mode = newMode;
}

// Called before morphdom: fill placeholders whose SVG is already cached so the
// incoming DOM equals what is on screen.
export function fillCached(root) {
  for (const block of root.querySelectorAll('[data-mermaid]')) {
    const svg = cache.get(`${mode}:${block.dataset.mermaid}`);
    if (svg) {
      block.innerHTML = svg;
      block.classList.add('mermaid-rendered');
    }
  }
}

// morphdom hook: keep the previous diagram on screen while a changed source is
// being rendered (avoids flicker while typing inside a mermaid fence).
export function keepStaleDiagram(fromEl, toEl) {
  if (fromEl.dataset?.mermaid && toEl.dataset?.mermaid &&
      fromEl.classList.contains('mermaid-rendered') &&
      !toEl.classList.contains('mermaid-rendered')) {
    fromEl.dataset.mermaid = toEl.dataset.mermaid;
    fromEl.dataset.line = toEl.dataset.line;
    fromEl.dataset.pending = '1';
    fromEl.dataset.source = toEl.querySelector('.mermaid-source')?.textContent ?? '';
    return false;
  }
  return true;
}

export async function renderPending(root, onDone) {
  const blocks = [...root.querySelectorAll('[data-mermaid]')]
    .filter((b) => !b.classList.contains('mermaid-rendered') || b.dataset.pending);
  if (blocks.length === 0) return;
  let mermaid;
  try {
    mermaid = await loadMermaid();
  } catch (e) {
    console.error(e);
    return;
  }
  mermaid.initialize({
    startOnLoad: false,
    theme: mode === 'dark' ? 'dark' : 'default',
    securityLevel: 'strict',
  });
  for (const block of blocks) {
    const hash = block.dataset.mermaid;
    const source = block.dataset.pending
      ? block.dataset.source
      : block.querySelector('.mermaid-source')?.textContent ?? '';
    const key = `${mode}:${hash}`;
    let svg = cache.get(key);
    if (!svg) {
      try {
        const result = await mermaid.render(`mermaid-${++counter}`, source);
        svg = result.svg;
        cache.set(key, svg);
      } catch (e) {
        // Keep the last good diagram while the source is mid-edit.
        if (!block.classList.contains('mermaid-rendered')) {
          block.innerHTML = `<pre class="mermaid-error">${String(e.message ?? e)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')}</pre>`;
        }
        block.classList.add('mermaid-stale');
        continue;
      }
    }
    // The block may have been retargeted by a newer update meanwhile.
    if (block.dataset.mermaid !== hash) continue;
    block.innerHTML = svg;
    block.classList.add('mermaid-rendered');
    block.classList.remove('mermaid-stale');
    delete block.dataset.pending;
    delete block.dataset.source;
  }
  onDone?.();
}
