// Markdown -> HTML pipeline. Mirrors GitHub's flavour plus the VSCode preview
// extras (KaTeX, source-line mapping for scroll sync).
import MarkdownIt from 'markdown-it';
import taskLists from 'markdown-it-task-lists';
import footnote from 'markdown-it-footnote';
import alerts from 'markdown-it-github-alerts';
import { full as emoji } from 'markdown-it-emoji';
import frontMatter from 'markdown-it-front-matter';
import anchor from 'markdown-it-anchor';
import GithubSlugger from 'github-slugger';
import katexPlugin from '@vscode/markdown-it-katex';
import katex from 'katex';
import hljs from 'highlight.js';
import * as yaml from 'js-yaml';

// Mermaid sources are rendered asynchronously; the synchronous pass only emits
// a placeholder keyed by a hash of the source (see mermaid.js).
export function hashString(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(36);
}

const md = new MarkdownIt({
  html: true,
  linkify: true,
  typographer: false,
  breaks: false,
});

md.use(taskLists, { enabled: true, label: true });
md.use(footnote);
md.use(alerts);
md.use(emoji);
md.use(frontMatter, () => {});
md.use(katexPlugin.default ?? katexPlugin, { enableBareBlocks: true, throwOnError: false });

let slugger = new GithubSlugger();
md.use(anchor, {
  slugify: (s) => slugger.slug(s),
  tabIndex: false,
  permalink: anchor.permalink.linkInsideHeader({
    class: 'anchor',
    placement: 'before',
    symbol: '<span class="octicon octicon-link" aria-hidden="true"></span>',
    space: false,
  }),
});

// Source map: every block token with a line range gets data-line (0-based),
// exactly like VSCode's pluginSourceMap. Scroll sync keys off .code-line.
md.core.ruler.push('source_line', (state) => {
  for (const token of state.tokens) {
    if (token.map && token.nesting >= 0 && token.type !== 'inline') {
      token.attrSet('data-line', String(token.map[0]));
      token.attrJoin('class', 'code-line');
    }
  }
});

const escapeHtml = md.utils.escapeHtml;

function lineAttrs(token) {
  const line = token.attrGet('data-line');
  return line == null ? '' : ` data-line="${line}"`;
}

function highlight(code, lang) {
  if (lang && hljs.getLanguage(lang)) {
    try {
      return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
    } catch {
      // fall through to plain text
    }
  }
  return escapeHtml(code);
}

md.renderer.rules.fence = (tokens, idx) => {
  const token = tokens[idx];
  const info = token.info ? md.utils.unescapeAll(token.info).trim() : '';
  const lang = info.split(/\s+/)[0].toLowerCase();
  const code = token.content;
  const la = lineAttrs(token);

  if (lang === 'mermaid') {
    const hash = hashString(code);
    return `<div class="code-line mermaid-block"${la} data-mermaid="${hash}">` +
      `<pre class="mermaid-source">${escapeHtml(code)}</pre></div>\n`;
  }
  if (lang === 'math') {
    let html;
    try {
      html = katex.renderToString(code, { displayMode: true, throwOnError: false });
    } catch (e) {
      html = `<pre class="katex-error">${escapeHtml(String(e))}</pre>`;
    }
    return `<div class="code-line math-block"${la}>${html}</div>\n`;
  }
  const cls = lang ? ` class="hljs language-${escapeHtml(lang)}"` : ' class="hljs"';
  return `<div class="code-line highlight"${la}><pre><code${cls}>${highlight(code, lang)}</code></pre>` +
    `<button class="copy-button" type="button" title="Copy" aria-label="Copy"></button></div>\n`;
};

md.renderer.rules.code_block = (tokens, idx) => {
  const token = tokens[idx];
  return `<div class="code-line highlight"${lineAttrs(token)}><pre><code class="hljs">` +
    `${escapeHtml(token.content)}</code></pre>` +
    `<button class="copy-button" type="button" title="Copy" aria-label="Copy"></button></div>\n`;
};

// GitHub alerts plugin ignores token attrs; re-add the source line.
const alertOpen = md.renderer.rules.alert_open;
md.renderer.rules.alert_open = (tokens, idx, ...rest) => {
  const html = alertOpen(tokens, idx, ...rest);
  return html.replace(/^<div class="([^"]*)"/, `<div class="$1 code-line"${lineAttrs(tokens[idx])}`);
};

// GitHub renders YAML front matter as a table.
function frontMatterValue(v) {
  if (v === null || v === undefined) return '';
  if (Array.isArray(v)) {
    return `<table><tbody><tr>${v.map((x) => `<td>${frontMatterValue(x)}</td>`).join('')}</tr></tbody></table>`;
  }
  if (typeof v === 'object') return frontMatterTable(v);
  return escapeHtml(String(v));
}

function frontMatterTable(obj) {
  const keys = Object.keys(obj);
  return '<table><thead><tr>' + keys.map((k) => `<th>${escapeHtml(k)}</th>`).join('') +
    '</tr></thead><tbody><tr>' + keys.map((k) => `<td>${frontMatterValue(obj[k])}</td>`).join('') +
    '</tr></tbody></table>';
}

md.renderer.rules.front_matter = (tokens, idx) => {
  const token = tokens[idx];
  let data;
  try {
    data = yaml.load(token.meta);
  } catch (e) {
    return `<pre class="code-line front-matter-error"${lineAttrs(token)}>${escapeHtml(String(e.message))}</pre>\n`;
  }
  if (!data || typeof data !== 'object') return '';
  return `<div class="code-line front-matter"${lineAttrs(token)}>${frontMatterTable(data)}</div>\n`;
};

export function render(text) {
  slugger = new GithubSlugger();
  return md.render(text, {});
}
