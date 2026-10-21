import { access, readFile, readdir } from 'node:fs/promises';

const origin = 'https://docs.tinyprune.com';
const root = new URL('../', import.meta.url);
const read = name => readFile(new URL(name, root), 'utf8');
const fail = message => { throw new Error(message); };
// This checker deliberately targets our static HTML, not arbitrary browser HTML.
const decode = text => text.replace(/&(amp|lt|gt|quot|apos|#39|#x27|nbsp);/g, (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", '#39': "'", '#x27': "'", nbsp: ' ' })[entity]);
const text = html => decode(html.replace(/<(?:script|style)\b[^>]*>[\s\S]*?<\/(?:script|style)>/gi, '').replace(/<[^>]*>/g, '')).replace(/\s+/g, ' ').trim();
const attrs = tag => Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)].map(([, key, doubleQuoted, singleQuoted]) => [key.toLowerCase(), decode(doubleQuoted ?? singleQuoted)]));
const tags = (html, name) => [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, 'gi'))].map(match => attrs(match[0]));
const meta = (html, name) => tags(html, 'meta').find(tag => tag.name === name || tag.property === name)?.content;
const canonical = html => tags(html, 'link').find(tag => tag.rel === 'canonical')?.href;
const ids = html => [...html.matchAll(/\bid=["']([^"']+)["']/g)].map(match => match[1]);
const pages = new Map();
async function collect(directory = '') {
  for (const entry of await readdir(new URL(directory || './', root), { withFileTypes: true })) {
    const name = `${directory}${entry.name}`;
    if (entry.isDirectory() && !['node_modules', '.git'].includes(entry.name)) await collect(`${name}/`);
    else if (entry.isFile() && name.endsWith('.html')) pages.set(name, await read(name));
  }
}
await collect();
const html = pages.get('index.html');
if (!html) fail('Missing documentation home');
const pageURL = name => new URL(name === 'index.html' ? '/' : name.replace(/index\.html$/, ''), `${origin}/`).href;
const indexable = new Set();
for (const [name, page] of pages) {
  if (!/^<!doctype html>/i.test(page)) fail(`${name}: missing HTML doctype`);
  if (!/<html\b[^>]*lang="en"/.test(page)) fail(`${name}: missing document language`);
  if (tags(page, 'main').length !== 1 || tags(page, 'h1').length !== 1) fail(`${name}: requires one main landmark and one h1`);
  if (!meta(page, 'viewport')) fail(`${name}: missing viewport`);
  if (!/<title>[^<]+<\/title>/.test(page)) fail(`${name}: missing title`);
  if (ids(page).length !== new Set(ids(page)).size) fail(`${name}: duplicate HTML id`);
  const noindex = /\bnoindex\b/i.test(meta(page, 'robots') || '');
  if (name === '404.html') {
    if (!noindex || canonical(page)) fail('404.html must be noindex and must not canonicalize to a real page');
  } else {
    if (noindex) fail(`${name}: documentation must be indexable`);
    const url = pageURL(name);
    if (canonical(page) !== url || meta(page, 'og:url') !== url) fail(`${name}: canonical and og:url must match ${url}`);
    const description = meta(page, 'description');
    if (!description || description.length < 120 || description.length > 160) fail(`${name}: meta description must be 120-160 characters`);
    for (const property of ['og:title', 'og:description', 'og:image', 'twitter:card', 'twitter:title', 'twitter:description', 'twitter:image']) {
      if (!meta(page, property)) fail(`${name}: missing ${property}`);
    }
    indexable.add(url);
  }
}
// Top-level 404.html opts Cloudflare Pages out of its default SPA fallback.
if (!pages.has('404.html')) fail('Missing top-level 404.html; nonexistent paths must not serve the guide as HTTP 200');

// Resolve every local resource and link, including absolute docs URLs and SVG fragments.
const fileCache = new Map(pages);
async function checkURL(raw, base, source) {
  const url = new URL(decode(raw), base);
  if (url.origin !== origin) return; // No network calls; external availability is a separate deploy smoke.
  const pathname = decodeURIComponent(url.pathname);
  const name = pathname.slice(1) + (pathname.endsWith('/') ? 'index.html' : '');
  try { await access(new URL(name, root)); } catch { fail(`${source}: missing local target ${url.href}`); }
  if (url.hash && /\.(?:html|svg)$/.test(name)) {
    if (!fileCache.has(name)) fileCache.set(name, await read(name));
    if (!ids(fileCache.get(name)).includes(decodeURIComponent(url.hash.slice(1)))) fail(`${source}: missing fragment ${url.href}`);
  }
}
for (const [name, page] of pages) {
  const base = pageURL(name);
  const markup = page.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
  for (const match of markup.matchAll(/<(?:a|link|img|use|script)\b[^>]*>/gi)) {
    const tag = attrs(match[0]);
    const target = tag.href ?? tag.src;
    if (target) await checkURL(target, base, name);
  }
  for (const tag of tags(page, 'script')) if (tag.src) await checkURL(tag.src, base, name);
  const article = page.match(/<article\b[^>]*>([\s\S]*?)<\/article>/)?.[1] || '';
  for (const match of article.matchAll(/<h[23]\b[^>]*>/g)) {
    if (!attrs(match[0]).id) fail(`${name}: article headings require static IDs, not JavaScript-only anchors`);
  }
  const remote = [...page.matchAll(/<(?:script|img|use|link)\b[^>]*>/g)].map(match => attrs(match[0])).filter(tag => tag.src || tag.href);
  for (const tag of remote) {
    const target = tag.src || tag.href;
    if (/^https?:/.test(target) && !['canonical', 'alternate'].includes(tag.rel)) fail(`${name}: resource must be local: ${target}`);
  }
}
const requiredSections = ['start', 'install', 'safety', 'rules', 'preview', 'templates', 'agents', 'finder', 'cli', 'updates', 'cross-platform', 'faq'];
for (const id of requiredSections) if (!ids(html).includes(id)) fail(`Missing legacy guide anchor #${id}`);
// Preserve previously copied JS-generated subheading links as static HTML.
for (const id of ['download-or-use-homebrew', 'open-tinyprune', 'first-run', 'build-from-source', 'items-go-to-trash', 'keep-wins', 'very-broad-folders', 'pause-and-settings', 'activity-and-restoring-items', 'exporting-and-importing-rule-configuration', 'old-node-modules', 'exit-codes', 'manage-rules-as-code', 'template-table']) {
  if (!ids(html).includes(id)) fail(`Missing legacy deep link #${id}`);
}
const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
const nodes = blocks.flatMap(([, json]) => { const data = JSON.parse(json); return data['@graph'] || [data]; });
for (const type of ['TechArticle', 'FAQPage']) if (!nodes.some(node => node['@type'] === type)) fail(`Missing ${type} JSON-LD`);
for (const node of nodes) {
  if (node['@type'] === 'TechArticle') {
    if (node.url !== canonical(html)) fail('Article URL must match the canonical');
    for (const part of node.hasPart || []) await checkURL(part.url, `${origin}/`, 'JSON-LD hasPart');
  }
  if (node['@type'] === 'FAQPage') {
    const faq = html.match(/<section id="faq"[^>]*>([\s\S]*?)<\/section>/)?.[1] || '';
    const visible = new Map([...faq.matchAll(/<h3\b[^>]*>([\s\S]*?)<\/h3>\s*<p>([\s\S]*?)<\/p>/g)].map(([, question, answer]) => [text(question), text(answer)]));
    if (visible.size !== node.mainEntity.length) fail('FAQ schema and visible question counts differ');
    for (const question of node.mainEntity) {
      if (visible.get(question.name) !== text(question.acceptedAnswer.text)) fail(`FAQ schema differs from visible answer: ${question.name}`);
    }
  }
}
const robots = await read('robots.txt');
if (!/^Sitemap: https:\/\/docs\.tinyprune\.com\/sitemap\.xml$/m.test(robots)) fail('robots.txt must list the docs sitemap');
const groups = robots.replace(/#.*$/gm, '').split(/\n\s*\n/).filter(group => /User-agent:/i.test(group));
for (const bot of ['*', 'GPTBot', 'ClaudeBot', 'PerplexityBot', 'Google-Extended', 'CCBot']) {
  const group = groups.find(group => group.split('\n').some(line => line.trim() === `User-agent: ${bot}`));
  if (!group || !/^Allow:\s*\/$/m.test(group) || /^Disallow:\s*\S/m.test(group)) fail(`Preserve existing allow policy for ${bot}`);
}
const sitemap = await read('sitemap.xml');
if (!sitemap.includes('xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"')) fail('Missing sitemap namespace');
const locations = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => decode(match[1]));
if (locations.length !== new Set(locations).size || locations.length !== indexable.size) fail('Sitemap must list each indexable HTML page exactly once');
for (const location of locations) {
  if (!indexable.has(location)) fail(`Sitemap lists a noncanonical or nonindexable page: ${location}`);
  await checkURL(location, `${origin}/`, 'sitemap.xml');
}
const llms = await read('llms.txt');
if (!llms.startsWith('# TinyPrune') || !llms.includes('https://tinyprune.com')) fail('llms.txt must describe TinyPrune and link the site');
for (const [, target] of llms.matchAll(/\]\((https?:\/\/[^\s)]+)\)/g)) await checkURL(target, `${origin}/`, 'llms.txt');
if (!tags(html, 'link').some(tag => tag.rel === 'alternate' && tag.href === `${origin}/llms.txt`)) fail('Discover llms.txt from the HTML head');

const css = await read('styles.css');
const js = await read('app.js');
for (const source of [html, css, js]) {
  if (/(?:fonts\.googleapis\.com|fonts\.gstatic\.com|use\.typekit\.net|cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)/i.test(source)) fail('Docs must not use external font or CDN hosts');
}
for (const [, target] of css.matchAll(/url\(\s*['"]?([^'")\s]+)['"]?\s*\)/g)) {
  if (/^https?:/.test(target)) fail(`CSS asset must be local: ${target}`);
  await checkURL(target, `${origin}/styles.css`, 'styles.css');
}
const sprite = await read('assets/icons.svg');
const symbols = new Set(tags(sprite, 'symbol').map(tag => tag.id));
for (const [, symbol] of js.matchAll(/icon\('([a-z][a-z0-9-]*)'\)/g)) if (!symbols.has(symbol)) fail(`Unknown dynamic icon: ${symbol}`);
for (const [, target] of js.matchAll(/['"`](assets\/[^'"`]+)['"`]/g)) {
  if (!target.includes('${')) await checkURL(target, `${origin}/`, 'app.js');
}
console.log('TinyPrune docs checks passed (HTML, static anchors, schema, discovery, local resources, and 404 contract)');
