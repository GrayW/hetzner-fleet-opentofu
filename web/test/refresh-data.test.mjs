import test from 'node:test';
import assert from 'node:assert/strict';
import {
  collect, parseEcb, parseObjectStoragePage, parsePricing, parseServerTypes, DataError,
} from '../scripts/refresh-data.mjs';
import { ecb, fakeGet, osPage, pricing, typesPage1, typesPage2 } from './fixtures.mjs';

const rejectsData = (fn, re) => assert.throws(fn, e => e instanceof DataError && re.test(e.message));

test('ECB: parses date and rates', () => {
  const r = parseEcb(ecb);
  assert.equal(r.date, '2026-10-23');
  assert.equal(r.values.USD, 1.25);
  assert.equal(Object.keys(r.values).length, 12);
});
test('ECB: fails without a date, without USD, or with too few currencies', () => {
  rejectsData(() => parseEcb(ecb.replace(/time='[^']+'/, '')), /no date/);
  rejectsData(() => parseEcb(ecb.replace(/<Cube currency='USD'[^>]*>/, '')), /USD is missing/);
  rejectsData(() => parseEcb("<Cube time='2026-10-23'><Cube currency='USD' rate='1.2'/></Cube>"), /only 1 currencies/);
});

test('Object Storage page: parses prices, quota and locations; ignores script text', () => {
  const o = parseObjectStoragePage(osPage);
  assert.deepEqual(o.locations, ['fsn1', 'hel1', 'nbg1']);
  assert.equal(o.baseMonthly, 6.49);
  assert.equal(o.includedStorageTb, 1);
  assert.equal(o.includedEgressTb, 1);
  assert.equal(o.storagePerTbMonth, 6.47); // 0.0087 * 744
  assert.equal(o.egressPerTb, 1);
});
test('Object Storage page: fails loudly if wording or currency changes', () => {
  rejectsData(() => parseObjectStoragePage(osPage.replace('base price of €', 'base price of $')), /monthly base price/);
  rejectsData(() => parseObjectStoragePage(osPage.replace('available in the following locations', 'live in')), /locations/);
  rejectsData(() => parseObjectStoragePage(osPage.replace('Egress traffic', 'Outgoing traffic')), /extra traffic/);
});

test('server types: drops deprecated ones and requires the default type', () => {
  const all = [...typesPage1.server_types, ...typesPage2.server_types];
  const t = parseServerTypes(all);
  assert.ok(t.cpx22 && t.cpx42);
  assert.equal(t.old1, undefined);
  assert.equal(t.cpx22.prices.nbg1.monthly, 10);
  assert.equal(t.cx23.prices.ash, undefined); // EU only in the fixture
  rejectsData(() => parseServerTypes(all.filter(x => x.name !== 'cpx22')), /default cpx22/);
  rejectsData(() => parseServerTypes(all.slice(0, 2)), /usable types/);
});
test('server types: a missing price is an error, not a zero', () => {
  const broken = structuredClone(typesPage1.server_types);
  delete broken[0].prices[0].price_monthly;
  rejectsData(() => parseServerTypes([...broken, ...typesPage2.server_types]), /monthly net price/);
});

test('pricing: refuses a non-EUR project and warns when IPv4 is missing', () => {
  rejectsData(() => parsePricing({ pricing: { ...pricing.pricing, currency: 'USD' } }), /bills in USD/);
  const { ipv4, warnings } = parsePricing({ pricing: { currency: 'EUR', primary_ips: [] } });
  assert.equal(ipv4, null);
  assert.match(warnings.join(), /IPv4/);
  assert.equal(parsePricing(pricing).ipv4.nbg1.monthly, 0.5);
});

test('collect: follows pagination and assembles the output', async () => {
  const { live, warnings } = await collect(fakeGet(), 'token', new Date('2026-10-26T17:00:00Z'));
  assert.equal(live.generatedAt, '2026-10-26T17:00:00.000Z');
  assert.ok(live.serverTypes.cpx42, 'page 2 was fetched');
  assert.deepEqual(warnings, []);
  assert.equal(live.rates.values.USD, 1.25);
  assert.equal(live.objectStorage.baseMonthly, 6.49);
});
test('collect: fails without a token, and when any source breaks', async () => {
  await assert.rejects(collect(fakeGet(), ''), /HCLOUD_TOKEN/);
  const bad = fakeGet({ 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml': '<html>oops</html>' });
  await assert.rejects(collect(bad, 'token'), /ECB/);
});
