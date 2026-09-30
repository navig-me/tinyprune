import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const required = [
  '<!doctype html>',
  '<title>TinyPrune documentation</title>',
  'id="safety"',
  'id="updates"',
  'https://github.com/navig-me/tinyprune',
];

for (const value of required) {
  if (!html.includes(value)) throw new Error(`docs/index.html is missing ${value}`);
}

if ((html.match(/<main>/g) ?? []).length !== 1) throw new Error('docs must contain one main landmark');
if (!html.includes('<meta name="viewport"')) throw new Error('docs must declare a viewport');
