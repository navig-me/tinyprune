import { readFile } from 'node:fs/promises';

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
