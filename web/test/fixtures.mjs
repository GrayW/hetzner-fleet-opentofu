// FIXTURES ONLY. The shapes follow Hetzner's API as best recalled and the page text follows
// the Object Storage FAQ, but every number here is made up. These prove the parsing code is
// consistent with itself, not that Hetzner's real responses match. Check a real run.

export const LOCS = ['fsn1', 'nbg1', 'hel1', 'ash', 'hil', 'sin'];
export const EU = ['fsn1', 'nbg1', 'hel1'];

const price = m => ({
  price_monthly: { net: String(m), gross: String(m * 1.19) },
  price_hourly: { net: String(m / 730), gross: '0' },
});
const type = (name, locs, m, extra = {}) => ({
  name, description: name.toUpperCase(), cores: 2, memory: 4, disk: 80,
  cpu_type: 'shared', architecture: 'x86', deprecated: false,
  prices: locs.map(location => ({ location, ...price(m) })), ...extra,
});

export const typesPage1 = {
  server_types: [type('cpx22', LOCS, 10), type('cx23', EU, 5), type('cpx32', LOCS, 20), type('ccx13', LOCS, 12), type('cax11', EU, 4)],
  meta: { pagination: { page: 1, next_page: 2 } },
};
export const typesPage2 = {
  server_types: [type('old1', LOCS, 1, { deprecated: true }), type('cpx42', LOCS, 40)],
  meta: { pagination: { page: 2, next_page: null } },
};

export const pricing = {
  pricing: {
    currency: 'EUR', vat_rate: '19.00',
    primary_ips: [
      { type: 'ipv4', prices: LOCS.map(location => ({ location, ...price(0.5) })) },
      { type: 'ipv6', prices: LOCS.map(location => ({ location, ...price(0) })) },
    ],
  },
};

export const ecb = `<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<Cube><Cube time='2026-10-23'>
<Cube currency='USD' rate='1.2500'/><Cube currency='JPY' rate='160.00'/><Cube currency='GBP' rate='0.8000'/>
<Cube currency='CHF' rate='0.9500'/><Cube currency='SEK' rate='11.0000'/><Cube currency='NOK' rate='11.5000'/>
<Cube currency='DKK' rate='7.4600'/><Cube currency='PLN' rate='4.2500'/><Cube currency='CZK' rate='25.0000'/>
<Cube currency='AUD' rate='1.6000'/><Cube currency='CAD' rate='1.4000'/><Cube currency='SGD' rate='1.5000'/>
</Cube></Cube></gesmes:Envelope>`;

// Wording copied from the FAQ on hetzner.com/storage/object-storage, wrapped in markup.
export const osPage = `<html><head><script>var x = "€ 99.99 per month";</script></head><body>
<h3>Frequently asked questions</h3>
<div><p><strong>What locations will Object Storage be available?</strong></p>
<p>Currently, Object Storage is available in the following locations: Falkenstein, DE (FSN1), Helsinki, FI (HEL1), and Nuremberg, DE (NBG1).&nbsp;</p>
<p>We charge a base price of € 6.49 per month, excl. VAT per month for using Object Storage. This base price includes 1 TB of storage (up to 744 TB-hours) and 1 TB of egress traffic.</p>
<p>The base price is billed hourly at € 0.0104 per hour, excl. VAT (capped at € 6.49 per month, excl. VAT per month).</p>
<ul><li>Storage: € 0.0087 per hour, excl. VAT per TB-hour.</li>
<li>Egress traffic: € 1.0000 per hour, excl. VAT per TB.</li></ul></div></body></html>`;

// A fake network: maps URLs to response bodies.
export const fakeGet = (overrides = {}) => async url => {
  if (url in overrides) return overrides[url];
  if (url.includes('/server_types') && url.includes('page=1')) return JSON.stringify(typesPage1);
  if (url.includes('/server_types') && url.includes('page=2')) return JSON.stringify(typesPage2);
  if (url.endsWith('/pricing')) return JSON.stringify(pricing);
  if (url.includes('ecb.europa.eu')) return ecb;
  if (url.includes('hetzner.com/storage/object-storage')) return osPage;
  throw new Error(`unexpected URL in test: ${url}`);
};
