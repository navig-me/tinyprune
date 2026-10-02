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
