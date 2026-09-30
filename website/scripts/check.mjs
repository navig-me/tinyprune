import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const required = [
  '<!doctype html>',
  '<title>TinyPrune — File lifetimes for your Mac</title>',
  'https://docs.tinyprune.com',
  'https://github.com/navig-me/tinyprune',
];

for (const value of required) {
  if (!html.includes(value)) throw new Error(`website/index.html is missing ${value}`);
}

if ((html.match(/<main>/g) ?? []).length !== 1) throw new Error('website must contain one main landmark');
if (!html.includes('<meta name="viewport"')) throw new Error('website must declare a viewport');
