import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const required = [
  '<!doctype html>',
  '<title>TinyPrune | File lifetimes for macOS</title>',
  'assets/tinyprune-plum.svg',
  'assets/overview.png',
  'assets/upcoming-inspector.png',
  'assets/rule-editor.png',
  'https://docs.tinyprune.com',
  'https://github.com/navig-me/tinyprune',
  'https://www.googletagmanager.com/gtag/js?id=G-EERWCSKWF4',
  "gtag('config', 'G-EERWCSKWF4');",
  "posthog.init('phc_vYjj5JDjp63ZvmcVwko2Fd73Ks68Dmkz36z8vKGPNppD'",
  'data-ph-event="cta_clicked"',
  'posthog.capture(target.getAttribute',
];

for (const value of required) {
  if (!html.includes(value)) throw new Error(`website/index.html is missing ${value}`);
}

if ((html.match(/<main>/g) ?? []).length !== 1) throw new Error('website must contain one main landmark');
if (!html.includes('<meta name="viewport"')) throw new Error('website must declare a viewport');
if (/[—–]/.test(html)) throw new Error('website must not contain em or en dashes');
