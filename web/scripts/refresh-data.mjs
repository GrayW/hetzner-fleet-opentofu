#!/usr/bin/env node
// Collects Hetzner prices and availability, ECB exchange rates and Hetzner Object Storage
// pricing into web/data/hetzner-data.json for build.mjs to bake into the page.
//
// Design rule: fail loudly. If anything looks wrong, exit non-zero so the workflow stops
// before deploying and the previously published site (the last good one) stays up.
//
// Needs Node 20+ (built-in fetch) and no npm packages.
// Usage: HCLOUD_TOKEN=<read-only token> node web/scripts/refresh-data.mjs

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const API = 'https://api.hetzner.cloud/v1';
const ECB_URL = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml';
const OS_URL = 'https://www.hetzner.com/storage/object-storage/';

// The repo's defaults. If these can't be priced, something is badly wrong.
export const DEFAULT_TYPE = 'cpx22';
export const DEFAULT_LOCATION = 'nbg1';
const HOURS_PER_MONTH = 744; // Hetzner's own figure for a month of TB-hours

export class DataError extends Error {}
const fail = msg => { throw new DataError(msg); };
const round = (n, dp = 4) => Math.round(n * 10 ** dp) / 10 ** dp;
const num = (v, what) => {
  const n = Number(v);
  if (v === null || v === undefined || v === '' || !Number.isFinite(n) || n < 0) {
    fail(`${what}: expected a non-negative number, got ${JSON.stringify(v)}`);
  }
  return n;
};
const parseJson = (text, what) => {
  try { return JSON.parse(text); } catch { return fail(`${what}: response was not valid JSON`); }
};

/* ---------- Parsers (pure, unit-tested) ---------- */

export function parseServerTypes(types) {
  const out = {};
  for (const t of types) {
    if (t.deprecated === true) continue;
    const prices = {};
    for (const p of t.prices ?? []) {
      const where = `server type ${t.name} @ ${p.location}`;
      prices[p.location] = {
        monthly: round(num(p.price_monthly?.net, `${where} monthly net price`)),
        hourly: round(num(p.price_hourly?.net, `${where} hourly net price`), 6),
      };
    }
    if (Object.keys(prices).length === 0) continue;
    out[t.name] = {
      description: t.description, cores: t.cores, memory: t.memory, disk: t.disk,
      cpuType: t.cpu_type, architecture: t.architecture, prices,
    };
  }
  if (Object.keys(out).length < 5) fail(`server types: only ${Object.keys(out).length} usable types found, expected more`);
  const d = out[DEFAULT_TYPE]?.prices[DEFAULT_LOCATION];
  if (!d || !(d.monthly > 0)) fail(`server types: no price for the default ${DEFAULT_TYPE} in ${DEFAULT_LOCATION}`);
  return out;
}

export function parsePricing(json) {
  const p = json?.pricing ?? fail('pricing: response has no "pricing" object');
  const warnings = [];
  if (p.currency && p.currency !== 'EUR') {
    fail(`pricing: the token's project bills in ${p.currency}, but this script expects EUR. Use a token from a EUR project.`);
  }
  if (!p.currency) warnings.push('pricing.currency was missing, so EUR is assumed');
  let ipv4 = null;
  const entry = (p.primary_ips ?? []).find(x => x.type === 'ipv4');
  if (entry) {
    ipv4 = {};
    for (const pr of entry.prices ?? []) {
      ipv4[pr.location] = { monthly: round(num(pr.price_monthly?.net, `IPv4 ${pr.location} monthly net price`)) };
    }
    if (Object.keys(ipv4).length === 0) ipv4 = null;
  }
  if (!ipv4) warnings.push('no IPv4 price found, so the estimate will leave it out');
  return { ipv4, warnings };
}

export function parseEcb(xml) {
  const date = /<Cube\s+time=['"](\d{4}-\d{2}-\d{2})['"]/.exec(xml)?.[1] ?? fail('ECB rates: no date found in the feed');
  const values = {};
  for (const m of xml.matchAll(/<Cube\s+currency=['"]([A-Z]{3})['"]\s+rate=['"]([\d.]+)['"]/g)) {
    const rate = num(m[2], `ECB rate for ${m[1]}`);
    if (rate <= 0) fail(`ECB rate for ${m[1]} is zero`);
    values[m[1]] = rate;
  }
  if (!values.USD) fail('ECB rates: USD is missing');
  if (Object.keys(values).length < 10) fail(`ECB rates: only ${Object.keys(values).length} currencies found, expected about 30`);
  return { date, base: 'EUR', values };
}

export function parseObjectStoragePage(html) {
  const text = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;|&#160;/g, ' ')
    .replace(/&euro;|&#8364;/g, '€')
    .replace(/\s+/g, ' ');
  const grab = (re, what) => {
    const m = re.exec(text);
    if (!m) fail(`Object Storage page: couldn't find the ${what}. Its wording or currency may have changed, so check the page and update the patterns.`);
    return num(m[1], what);
  };
  const baseMonthly = grab(/base price of\s*€\s*([\d.]+)\s*per month/i, 'monthly base price (in €)');
  const baseHourly = grab(/billed hourly at\s*€\s*([\d.]+)\s*per hour/i, 'hourly base price');
  const storagePerTbHour = grab(/Storage:\s*€\s*([\d.]+)\s*per hour[\s\S]{0,40}?TB-hour/i, 'extra storage price');
  const egressPerTb = grab(/Egress traffic:\s*€\s*([\d.]+)\s*per hour[\s\S]{0,40}?per TB/i, 'extra traffic price');
  const includedStorageTb = grab(/includes\s*([\d.]+)\s*TB of storage/i, 'included storage');
  const includedEgressTb = grab(/and\s*([\d.]+)\s*TB of egress/i, 'included traffic');
  const locSection = /available in the following locations:\s*([^.]*)\./i.exec(text)?.[1]
    ?? fail('Object Storage page: couldn\u2019t find the list of locations');
  const locations = [...locSection.matchAll(/\(([A-Z]{3}\d)\)/g)].map(m => m[1].toLowerCase());
  if (locations.length === 0) fail('Object Storage page: no location codes found');
  if (!(baseMonthly > 0.5 && baseMonthly < 100)) fail(`Object Storage page: base price ${baseMonthly} looks wrong`);
  if (baseHourly > baseMonthly) fail('Object Storage page: hourly price is higher than the monthly price');
  return {
    locations, baseMonthly, includedStorageTb, includedEgressTb,
    storagePerTbMonth: round(storagePerTbHour * HOURS_PER_MONTH, 2),
    egressPerTb,
    source: OS_URL,
  };
}

/* ---------- Collection ---------- */

export async function fetchAllServerTypes(get, auth) {
  const all = [];
  let page = 1;
  for (let guard = 0; page && guard < 20; guard++) {
    const json = parseJson(await get(`${API}/server_types?per_page=50&page=${page}`, auth), 'server types');
    if (!Array.isArray(json.server_types)) fail('server types: response has no "server_types" array');
    all.push(...json.server_types);
    page = json.meta?.pagination?.next_page ?? null;
  }
  return all;
}

// `get(url, headers)` returns the response body as text; injected so tests need no network.
export async function collect(get, token, now = new Date()) {
  if (!token) fail('HCLOUD_TOKEN is not set');
  const auth = { Authorization: `Bearer ${token}` };
  const [types, pricingText, ecbXml, osHtml] = await Promise.all([
    fetchAllServerTypes(get, auth),
    get(`${API}/pricing`, auth),
    get(ECB_URL),
    get(OS_URL, { 'Accept-Language': 'en' }),
  ]);
  const serverTypes = parseServerTypes(types);
  const { ipv4, warnings } = parsePricing(parseJson(pricingText, 'pricing'));
  const live = {
    generatedAt: now.toISOString(),
    currency: 'EUR',
    vatIncluded: false,
    serverTypes,
    ipv4,
    objectStorage: parseObjectStoragePage(osHtml),
    rates: parseEcb(ecbXml),
  };
  return { live, warnings };
}

async function getText(url, headers = {}) {
  let last;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return await res.text();
    } catch (e) {
      last = e;
      await new Promise(r => setTimeout(r, 2000 * attempt));
    }
  }
  return fail(`GET ${url} failed: ${last.message}`); // never logs headers, so the token stays out of logs
}

async function main() {
  const { live, warnings } = await collect(getText, process.env.HCLOUD_TOKEN);
  warnings.forEach(w => console.log(`::warning::${w}`));
  const out = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'data', 'hetzner-data.json');
  await mkdir(path.dirname(out), { recursive: true });
  await writeFile(out, JSON.stringify(live, null, 2) + '\n');
  console.log(`Wrote ${out}: ${Object.keys(live.serverTypes).length} server types, ` +
    `${Object.keys(live.rates.values).length} currencies (ECB ${live.rates.date}), ` +
    `Object Storage in ${live.objectStorage.locations.join(', ')}.`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(e => {
    console.error(`::error::${e instanceof DataError ? e.message : e.stack}`);
    process.exit(1);
  });
}
