// Writes website/stats.json with the total number of installer downloads from GitHub Releases.
// Counts every .dmg asset: direct downloads and the Homebrew cask, which installs from the same release files.
// Run at deploy time. On any failure it writes nothing, and the page simply omits the figure.
import { writeFile } from 'node:fs/promises';

const repo = process.env.GITHUB_REPOSITORY || 'navig-me/tinyprune';
const headers = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

let total = 0;
let releases = 0;
for (let page = 1; ; page += 1) {
  const response = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}`, { headers });
  if (!response.ok) throw new Error(`GitHub releases request failed: ${response.status}`);
  const batch = await response.json();
  for (const release of batch) {
    if (release.draft) continue;
    releases += 1;
    for (const asset of release.assets) if (asset.name.endsWith('.dmg')) total += asset.download_count;
  }
  if (batch.length < 100) break;
}

const stats = { downloads: total, releases, updatedAt: new Date().toISOString() };

// Shields.io "endpoint" badge for the GitHub README, so the badge and the website always show the same number.
const badge = { schemaVersion: 1, label: 'downloads', message: total.toLocaleString('en-US'), color: '4a1f3d', namedLogo: 'apple' };
await writeFile(new URL('../badge.json', import.meta.url), `${JSON.stringify(badge)}\n`);
await writeFile(new URL('../stats.json', import.meta.url), `${JSON.stringify(stats)}\n`);
console.log(`Wrote website/stats.json: ${total} DMG downloads across ${releases} releases`);
