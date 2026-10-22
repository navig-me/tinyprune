import { readFile, readdir, stat } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
const origin = 'https://tinyprune.com';
const docsOrigin = 'https://docs.tinyprune.com';
const fail = message => { throw new Error(message); };
const load = path => readFile(new URL(path, root), 'utf8');
const attrs = tag => Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)].map(([, name, double, single]) => [name.toLowerCase(), double ?? single]));
const tags = (html, name) => [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, 'gi'))].map(([tag]) => attrs(tag));
const ids = html => new Set([...html.matchAll(/\bid\s*=\s*["']([^"']+)["']/g)].map(([, id]) => id));
const htmlFiles = async (directory = '') => {
  const files = [];
  for (const entry of await readdir(new URL(directory, root), { withFileTypes: true })) {
    const path = directory + entry.name;
    if (entry.isDirectory() && !['node_modules', '.git'].includes(entry.name)) files.push(...await htmlFiles(`${path}/`));
    else if (entry.isFile() && path.endsWith('.html')) files.push(path);
  }
  return files;
};
const pages = new Map(await Promise.all((await htmlFiles()).map(async path => [path, await load(path)])));
const pathForURL = url => {
  const path = decodeURIComponent(url.pathname).replace(/^\//, '');
  return !path || path.endsWith('/') ? `${path}index.html` : path;
};
const pageURL = path => new URL(path === 'index.html' ? '/' : path.replace(/index\.html$/, ''), origin);
const indexable = new Set();

for (const [path, html] of pages) {
  // Sparkle release-note documents are feed payloads, not product landing pages.
  if (path.startsWith('updates/')) continue;
  const meta = tags(html, 'meta');
  const links = tags(html, 'link');
  const noindex = meta.some(tag => /^(robots|googlebot)$/i.test(tag.name ?? '') && /\bnoindex\b/i.test(tag.content ?? ''));
  if (!/<!doctype html>/i.test(html)) fail(`${path}: missing HTML doctype`);
  if (!/<html\b[^>]*\blang=["']en["']/i.test(html)) fail(`${path}: missing English language declaration`);
  if ((html.match(/<main\b/gi) ?? []).length !== 1 || (html.match(/<h1\b/gi) ?? []).length !== 1) fail(`${path}: needs exactly one main and h1`);
  if (!meta.some(tag => tag.name === 'viewport' && tag.content?.includes('width=device-width'))) fail(`${path}: missing responsive viewport`);
  if (!/<title>[^<]+<\/title>/i.test(html) || !meta.some(tag => tag.name === 'description' && tag.content?.trim())) fail(`${path}: missing title or description`);
  if (path === '404.html' && !noindex) fail('404.html must be noindex');
  if (!noindex) {
    const expected = pageURL(path).href;
    const canonicals = links.filter(tag => tag.rel === 'canonical');
    if (canonicals.length !== 1 || canonicals[0].href !== expected) fail(`${path}: needs one self-referencing canonical ${expected}`);
    if (!meta.some(tag => tag.property === 'og:url' && tag.content === expected)) fail(`${path}: Open Graph URL must match canonical`);
    indexable.add(expected);
  }
}

// Check links and fragments in actual published HTML, including absolute same-site URLs.
for (const [path, html] of pages) {
  const references = [...html.matchAll(/\b(?:href|src|srcset)\s*=\s*["']([^"']+)["']/g)].flatMap(([, value]) => value.split(',').map(part => part.trim().split(/\s+/)[0]));
  for (const reference of references) {
    if (!reference || reference === '#') fail(`${path}: empty or placeholder reference`);
    if (/^(?:data:|mailto:|tel:)/i.test(reference)) continue;
    const url = new URL(reference, pageURL(path));
    if (!['https:', 'http:'].includes(url.protocol)) fail(`${path}: unsupported reference ${reference}`);
    if (url.origin === docsOrigin) {
      if (url.pathname !== '/') fail(`${path}: unrecognized documentation path ${reference}`);
      if (url.hash) {
        const docs = await readFile(new URL('../../docs/index.html', import.meta.url), 'utf8');
        if (!ids(docs).has(decodeURIComponent(url.hash.slice(1)))) fail(`${path}: missing documentation fragment ${reference}`);
      }
      continue;
    }
    if (url.origin !== origin) continue;
    let target = pathForURL(url);
    let info;
    try { info = await stat(new URL(target, root)); } catch { fail(`${path}: missing local target ${reference}`); }
    if (info.isDirectory()) {
      target += '/index.html';
      try { await stat(new URL(target, root)); } catch { fail(`${path}: directory has no index ${reference}`); }
    }
    if (url.hash) {
      const targetHTML = pages.get(target);
      if (!targetHTML || !ids(targetHTML).has(decodeURIComponent(url.hash.slice(1)))) fail(`${path}: missing local fragment ${reference}`);
    }
  }
}

const html = pages.get('index.html');
const links = tags(html, 'link');
const meta = tags(html, 'meta');
if (!links.some(tag => tag.rel === 'alternate' && tag.type === 'text/plain' && tag.href === `${origin}/llms.txt`)) fail('Landing head must discover llms.txt');
if (!tags(html, 'a').some(tag => tag.href === `${origin}/llms.txt` || tag.href === '/llms.txt')) fail('Landing navigation must expose the agent reference');
for (const host of [docsOrigin, 'https://github.com/navig-me/tinyprune/releases']) {
  if (!tags(html, 'a').some(tag => tag.href === `${host}/` || tag.href === host)) fail(`Landing page must link ${host}`);
}
for (const id of ['receipt', 'faq']) {
  if (!new RegExp(`id=["']${id}["'][^>]*>\\s*<[^>]+>`, 'i').test(html)) fail(`${id} needs static HTML content, not JavaScript-only rendering`);
}
if (!meta.some(tag => tag.name === 'twitter:card' && tag.content === 'summary_large_image')) fail('Landing page needs its social card');
if (/fonts\.googleapis|fonts\.gstatic|cdn\.tailwindcss/.test(html)) fail('Website must self-host fonts and styles');
const blocks = [...html.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
const nodes = blocks.flatMap(([, json]) => { const data = JSON.parse(json); return data['@graph'] ?? [data]; });
const software = nodes.find(node => node['@type'] === 'SoftwareApplication');
const website = nodes.find(node => node['@type'] === 'WebSite');
if (software?.['@id'] !== `${origin}/#software` || software?.url !== `${origin}/` || website?.url !== `${origin}/`) fail('Schema must describe the canonical website and software');
if (software.operatingSystem !== 'macOS 14 or later' || software.offers?.price !== '0' || !software.offers?.priceCurrency) fail('Software schema must reflect the free macOS release');
if (software.softwareHelp !== `${docsOrigin}/`) fail('Schema must link the published help site');
const download = new URL(software.downloadUrl);
if (download.origin !== 'https://github.com' || download.username || download.password || download.search || download.hash ||
    !/^\/navig-me\/tinyprune\/releases(?:\/tag\/v\d+\.\d+\.\d+)?\/?$/.test(download.pathname)) {
  fail('Schema downloads must stay on this repository’s macOS release channel');
}

const robots = await load('robots.txt');
if (!/^Sitemap:\s*https:\/\/tinyprune\.com\/sitemap\.xml\s*$/m.test(robots)) fail('robots.txt must discover the canonical sitemap');
if (!/^User-agent:\s*\*\s*$/m.test(robots) || !/^Allow:\s*\/\s*$/m.test(robots) || /^Disallow:\s*\/\s*$/m.test(robots)) fail('Preserve the public allow-all crawler policy');
const sitemap = await load('sitemap.xml');
if (!sitemap.includes('xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"')) fail('Sitemap needs the sitemap namespace');
const locations = [...sitemap.matchAll(/<loc>\s*([^<]+)\s*<\/loc>/g)].map(([, value]) => value.trim());
if (new Set(locations).size !== locations.length) fail('Sitemap contains duplicate URLs');
if (locations.length !== indexable.size || locations.some(url => !indexable.has(url))) fail('Sitemap must list exactly the canonical indexable product pages, excluding 404 and feed notes');

const llms = await load('llms.txt');
if (!llms.startsWith('# TinyPrune')) fail('Agent reference must identify TinyPrune');
const discoveryLinks = [...llms.matchAll(/\]\((https:\/\/[^)]+)\)/g)].map(([, url]) => new URL(url));
if (!discoveryLinks.some(url => url.origin === docsOrigin) || !discoveryLinks.some(url => url.href === `${origin}/`)) fail('Agent reference must link the official overview and docs');
const docsHTML = await readFile(new URL('../../docs/index.html', import.meta.url), 'utf8');
for (const url of discoveryLinks) {
  if (url.origin !== origin && url.origin !== docsOrigin) continue;
  const targetHTML = url.origin === docsOrigin ? docsHTML : pages.get(pathForURL(url));
  if (!targetHTML || (url.origin === docsOrigin && url.pathname !== '/')) fail(`Agent reference links unknown page ${url.href}`);
  if (url.hash && !ids(targetHTML).has(decodeURIComponent(url.hash.slice(1)))) fail(`Agent reference links missing fragment ${url.href}`);
}
const headers = await load('_headers');
if (!headers.includes(`<${origin}/llms.txt>; rel="alternate"; type="text/plain"`)) fail('Response headers must discover the agent reference');
if (!pages.has('404.html') || indexable.has(`${origin}/404.html`)) fail('Publish a real noindex 404 outside the sitemap');
const socialImage = await readFile(new URL('og.png', root));
if (socialImage.toString('hex', 0, 8) !== '89504e470d0a1a0a' || socialImage.readUInt32BE(16) !== 1200 || socialImage.readUInt32BE(20) !== 630) fail('Social image must be a 1200x630 PNG');
for (const tag of meta.filter(tag => ['og:image', 'twitter:image'].includes(tag.property ?? tag.name))) {
  if (tag.content !== `${origin}/og.png`) fail('Social image metadata must reference the published image');
}
