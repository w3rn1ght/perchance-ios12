'use strict';
// Временный инструмент: HTTP/2 запрос с браузерными заголовками (обходит CF managed challenge).
const http2 = require('http2');
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

function get(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const client = http2.connect(u.origin);
    client.on('error', reject);
    const req = client.request({
      ':method': 'GET',
      ':path': u.pathname + u.search,
      'user-agent': UA,
      'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'accept-language': 'en-US,en;q=0.9',
      'accept-encoding': 'gzip, deflate',
      'sec-ch-ua': '"Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"',
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"macOS"',
      'sec-fetch-dest': 'document',
      'sec-fetch-mode': 'navigate',
      'sec-fetch-site': 'none',
      'sec-fetch-user': '?1',
      'upgrade-insecure-requests': '1'
    });
    let status = 0;
    let headers = {};
    const chunks = [];
    req.on('response', (h) => { status = h[':status']; headers = h; });
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      client.close();
      let buf = Buffer.concat(chunks);
      const enc = String(headers['content-encoding'] || '').toLowerCase();
      try {
        if (enc.includes('gzip')) buf = zlib.gunzipSync(buf);
        else if (enc.includes('deflate')) buf = zlib.inflateSync(buf);
        else if (enc.includes('br')) buf = zlib.brotliDecompressSync(buf);
      } catch (e) { reject(e); return; }
      if ([301, 302, 303, 307, 308].includes(status) && headers.location && redirects > 0) {
        resolve(get(new URL(headers.location, url).href, redirects - 1));
        return;
      }
      resolve({ status, headers, body: buf });
    });
    req.end();
  });
}

(async () => {
  const url = process.argv[2];
  const out = process.argv[3];
  const r = await get(url);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, r.body);
  console.log('status', r.status, 'len', r.body.length, 'ctype', r.headers['content-type'], '->', out);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
