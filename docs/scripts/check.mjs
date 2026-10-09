import { access, readFile } from 'node:fs/promises';

const read = (name) => readFile(new URL(`../${name}`, import.meta.url), 'utf8');
const html = await read('index.html');
const required = [
  '<!doctype html>',
  '<title>TinyPrune docs: automatic file cleanup rules for macOS</title>',
  '<link rel="canonical" href="https://docs.tinyprune.com/">',
  '<link rel="icon" type="image/svg+xml" href="/favicon.svg">',
  'property="og:image" content="https://tinyprune.com/og.png"',
  'name="twitter:card"',
  'assets/tinyprune-plum.svg',
  'id="install"',
  'id="safety"',
  'id="faq"',
  'id="updates"',
  'https://github.com/navig-me/tinyprune',
];

for (const value of required) {
  if (!html.includes(value)) throw new Error(`docs/index.html is missing ${value}`);
}

const description = html.match(/<meta name="description" content="([^"]*)"/)?.[1];
if (!description || description.length < 120 || description.length > 160) {
  throw new Error(`meta description must be 120-160 characters, got ${description?.length}`);
}

if ((html.match(/<main>/g) ?? []).length !== 1) throw new Error('docs must contain one main landmark');
if ((html.match(/<h1[ >]/g) ?? []).length !== 1) throw new Error('docs must contain exactly one h1');
if (!html.includes('<meta name="viewport"')) throw new Error('docs must declare a viewport');
if (/[—–]/.test(html)) throw new Error('docs must not contain em or en dashes');

const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
if (blocks.length === 0) throw new Error('docs must include JSON-LD');
const types = [];
for (const [, json] of blocks) {
  const data = JSON.parse(json);
  for (const node of data['@graph'] ?? [data]) types.push(node['@type']);
  for (const node of data['@graph'] ?? [data]) {
    if (node['@type'] !== 'FAQPage') continue;
    for (const q of node.mainEntity) {
      if (!html.includes(`<h3>${q.name}</h3>`)) throw new Error(`FAQ question is not visible on the page: ${q.name}`);
    }
  }
}
for (const type of ['TechArticle', 'FAQPage']) {
  if (!types.includes(type)) throw new Error(`JSON-LD is missing ${type}`);
}

const robots = await read('robots.txt');
if (!/^Sitemap: https:\/\/docs\.tinyprune\.com\/sitemap\.xml$/m.test(robots)) throw new Error('robots.txt must list the sitemap');
for (const bot of ['GPTBot', 'ClaudeBot', 'PerplexityBot', 'Google-Extended', 'CCBot']) {
  if (!robots.includes(`User-agent: ${bot}`)) throw new Error(`robots.txt is missing ${bot}`);
}
if (!(await read('sitemap.xml')).includes('<loc>https://docs.tinyprune.com/</loc>')) throw new Error('sitemap.xml must list the docs URL');
const llms = await read('llms.txt');
if (!llms.startsWith('# TinyPrune') || !llms.includes('https://tinyprune.com')) throw new Error('llms.txt must describe TinyPrune and link the site');

// Resources must stay local: no remote fonts, framework/CDN scripts, or styles.
const css = await read('styles.css');
const js = await read('app.js');
const sources = [html, css, js];
const remoteAssets = [
  ...html.matchAll(/<(?:script|img|use|link)\b[^>]*(?:src|href)="(https?:\/\/[^"]+)"/g),
].map(match => match[1]).filter(url => ![
  'https://docs.tinyprune.com/',
].includes(url));
if (remoteAssets.length) throw new Error(`Docs resources must be local: ${remoteAssets.join(', ')}`);
if (sources.some(source => /(?:fonts\.googleapis\.com|fonts\.gstatic\.com|use\.typekit\.net|cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)/i.test(source))) {
  throw new Error('Docs must not use external font or CDN hosts');
}
for (const [, url] of css.matchAll(/url\(\s*['"]?([^'")\s]+)['"]?\s*\)/g)) {
  if (/^https?:\/\//.test(url)) throw new Error(`CSS asset must be local: ${url}`);
}
const assets = new Set([
  ...[...html.matchAll(/(?:src|href)="([^"#]+)(?:#[^"]*)?"/g)].map(match => match[1]),
  ...[...css.matchAll(/url\(\s*['"]?([^'")\s]+)['"]?\s*\)/g)].map(match => match[1]),
  ...[...js.matchAll(/['"`](assets\/[^'"`#]+)(?:#[^'"`]*)?['"`]/g)].map(match => match[1]),
].filter(path => !/^(?:https?:|mailto:|data:)/.test(path)));
for (const asset of assets) {
  try {
    await access(new URL(`../${asset.replace(/^\//, '')}`, import.meta.url));
  } catch {
    throw new Error(`Local asset does not exist: ${asset}`);
  }
}
const sprite = await read('assets/icons.svg');
const symbols = new Set([...sprite.matchAll(/<symbol\b[^>]*id="([^"]+)"/g)].map(match => match[1]));
const referenced = new Set([
  ...[...sources.join('\n').matchAll(/assets\/icons\.svg#([a-z][a-z0-9-]*)/g)].map(match => match[1]),
  ...[...js.matchAll(/icon\('([a-z][a-z0-9-]*)'\)/g)].map(match => match[1]),
]);
for (const symbol of referenced) {
  if (!symbols.has(symbol)) throw new Error(`Referenced Phosphor symbol does not exist: ${symbol}`);
}
console.log('TinyPrune docs checks passed');
