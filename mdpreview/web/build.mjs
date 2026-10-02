// Builds the preview page into dist/:
//   index.html, preview.js, preview.css, fonts/*, mermaid.min.js
//   dev.html + fixture.js (standalone page for checking the renderer in a browser)
import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, 'dist');
const tmp = path.join(root, '.build');
const nm = (p) => path.join(root, 'node_modules', p);

fs.rmSync(dist, { recursive: true, force: true });
fs.mkdirSync(dist, { recursive: true });
fs.mkdirSync(tmp, { recursive: true });

// github-markdown-css switches palettes with prefers-color-scheme. Turn each
// media block into an explicit [data-theme=github][data-mode=…] rule so the
// palette is chosen by nvim, not by the OS.
function githubCss() {
  const css = fs.readFileSync(nm('github-markdown-css/github-markdown.css'), 'utf8');
  const re = /@media \(prefers-color-scheme: (dark|light)\) \{\s*\.markdown-body, \[data-theme="(?:dark|light)"\] \{([\s\S]*?)\n  \}\n\}/g;
  let palettes = '';
  const base = css.replace(re, (_, mode, body) => {
    palettes += `html[data-theme="github"][data-mode="${mode}"] .markdown-body {${body}\n}\n`;
    return '';
  });
  if (!palettes.includes('"dark"') || !palettes.includes('"light"')) {
    throw new Error('github-markdown-css layout changed: palette blocks not found');
  }
  return base + '\n' + palettes;
}
fs.writeFileSync(path.join(tmp, 'github.css'), githubCss());

fs.writeFileSync(path.join(tmp, 'entry.css'), [
  `@import "${nm('katex/dist/katex.css')}";`,
  `@import "${path.join(tmp, 'github.css')}";`,
  `@import "${path.join(root, 'themes/themes.css')}";`,
  `@import "${path.join(root, 'themes/preview.css')}";`,
].join('\n'));

await esbuild.build({
  entryPoints: { preview: path.join(root, 'src/main.js') },
  bundle: true,
  format: 'iife',
  target: 'safari16',
  minify: true,
  sourcemap: 'linked',
  outdir: dist,
  logLevel: 'warning',
});

await esbuild.build({
  entryPoints: { preview: path.join(tmp, 'entry.css') },
  bundle: true,
  minify: true,
  outdir: dist,
  loader: { '.woff2': 'file', '.woff': 'file', '.ttf': 'file' },
  assetNames: 'fonts/[name]',
  logLevel: 'warning',
});

fs.copyFileSync(nm('mermaid/dist/mermaid.min.js'), path.join(dist, 'mermaid.min.js'));

const page = (extra = '') => `<!DOCTYPE html>
<html lang="en" data-theme="github" data-mode="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Markdown Preview</title>
<link rel="stylesheet" href="preview.css">
</head>
<body>
<article id="content" class="markdown-body"></article>
<script src="preview.js"></script>
${extra}</body>
</html>
`;

fs.writeFileSync(path.join(dist, 'index.html'), page());

// Dev page: feeds test/kitchen-sink.md and picks the theme from the URL hash,
// e.g. dev.html#vscode-light.
const fixturePath = path.join(root, '..', 'test', 'kitchen-sink.md');
fs.writeFileSync(path.join(dist, 'fixture.js'),
  `window.__fixture = ${JSON.stringify(fs.readFileSync(fixturePath, 'utf8'))};\n` +
  `window.__fixtureDir = ${JSON.stringify(path.dirname(fixturePath))};\n`);
fs.writeFileSync(path.join(dist, 'dev.html'), page(`<script src="fixture.js"></script>
<script>
  const [name, mode] = (location.hash.slice(1) || 'github-dark').split('-');
  nvimPreview.receive({ type: 'theme', name, mode });
  nvimPreview.receive({ type: 'update', text: window.__fixture, docDir: window.__fixtureDir });
</script>
`));

console.log('mdpreview: built', path.relative(process.cwd(), dist) || dist);
