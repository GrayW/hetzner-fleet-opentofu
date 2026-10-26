#!/usr/bin/env node
// Bakes web/data/hetzner-data.json into web/index.html and writes web/dist/index.html.
// The page itself never fetches anything: the data is part of the file.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const MARKER = '/*__LIVE_DATA__*/null';

const html = await readFile(path.join(root, 'index.html'), 'utf8');
if (html.split(MARKER).length !== 2) {
  throw new Error(`index.html must contain ${MARKER} exactly once`);
}

let data;
try {
  data = JSON.parse(await readFile(path.join(root, 'data', 'hetzner-data.json'), 'utf8'));
} catch (e) {
  throw new Error(`Couldn't read web/data/hetzner-data.json (run refresh-data.mjs first): ${e.message}`);
}

// Keep the JSON from ever closing the script tag or breaking the JS string rules.
const json = JSON.stringify(data)
  .replace(/</g, '\\u003c')
  .replace(/\u2028/g, '\\u2028')
  .replace(/\u2029/g, '\\u2029');

const out = html.replace(MARKER, () => `/*__LIVE_DATA__*/${json}`);
await mkdir(path.join(root, 'dist'), { recursive: true });
await writeFile(path.join(root, 'dist', 'index.html'), out);
console.log(`Built web/dist/index.html (${(out.length / 1024).toFixed(0)} KB, data from ${data.generatedAt}).`);
