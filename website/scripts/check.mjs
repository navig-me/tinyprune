import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const required = [
  '<!DOCTYPE html>',
  '<title>TinyPrune',
  'Give your files',
  'https://docs.tinyprune.com',
  'https://github.com/navig-me/tinyprune',
  'https://github.com/navig-me/tinyprune/releases',
  'https://www.googletagmanager.com/gtag/js?id=G-EERWCSKWF4',
  "gtag('config', 'G-EERWCSKWF4');",
  "posthog.init('phc_vYjj5JDjp63ZvmcVwko2Fd73Ks68Dmkz36z8vKGPNppD'",
  "posthog.capture(name, { label: label, href: href })",
];

for (const value of required) {
  if (!html.includes(value)) throw new Error(`website/index.html is missing ${value}`);
}

if ((html.match(/<main[\s>]/g) ?? []).length !== 1) throw new Error('website must contain one main landmark');
if (!html.includes('<meta content="width=device-width') && !html.includes('<meta name="viewport"')) throw new Error('website must declare a viewport');
if (html.includes('href="#"') && html.match(/href="#"/g).length > 1) throw new Error('website has placeholder links');

const description = html.match(/<meta name="description" content="([^"]*)"/)?.[1];
if (!description) throw new Error('website must describe its product for search results');
for (const tag of [
  '<link rel="canonical" href="https://tinyprune.com/"/>',
  'property="og:url" content="https://tinyprune.com/"',
  'property="og:image" content="https://tinyprune.com/og.png"',
  'name="twitter:card" content="summary_large_image"',
]) {
  if (!html.includes(tag)) throw new Error(`website metadata is missing ${tag}`);
}
const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
const nodes = blocks.flatMap(([, json]) => {
  const data = JSON.parse(json);
  return data['@graph'] ?? [data];
});
if (!nodes.some((node) => node['@type'] === 'SoftwareApplication' && node['@id'] === 'https://tinyprune.com/#software')) {
  throw new Error('website must describe its software in JSON-LD');
}
const robots = await readFile(new URL('../robots.txt', import.meta.url), 'utf8');
if (!robots.includes('Sitemap: https://tinyprune.com/sitemap.xml')) throw new Error('robots.txt must link the sitemap');
const sitemap = await readFile(new URL('../sitemap.xml', import.meta.url), 'utf8');
if (!sitemap.includes('<loc>https://tinyprune.com/</loc>')) throw new Error('sitemap must list the canonical landing URL');
const llms = await readFile(new URL('../llms.txt', import.meta.url), 'utf8');
if (!llms.startsWith('# TinyPrune') || !llms.includes('https://docs.tinyprune.com/')) throw new Error('llms.txt must identify the product and link its documentation');
const socialImage = await readFile(new URL('../og.png', import.meta.url));
if (socialImage.toString('hex', 0, 8) !== '89504e470d0a1a0a' || socialImage.readUInt32BE(16) !== 1200 || socialImage.readUInt32BE(20) !== 630) {
  throw new Error('social image must be a 1200x630 PNG');
}
