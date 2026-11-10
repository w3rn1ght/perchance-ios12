#!/usr/bin/env node
/* ============================================================================
 * probe.js — с какого адреса Cloudflare пускает на perchance.org
 * ----------------------------------------------------------------------------
 * Cloudflare отдаёт 403 (managed challenge) любым не-браузерным HTTP/1.1
 * запросам и, в зависимости от сети, может блокировать и HTTP/2.
 * Этот скрипт пробует:
 *   1) HTTP/2 напрямую
 *   2) HTTP/2 через HTTP-прокси (если задан LP_UPSTREAM_PROXY)
 *   3) HTTP/1.1 напрямую (для сравнения)
 *
 * Запуск:  node probe.js
 * Пример:  set LP_UPSTREAM_PROXY=http://127.0.0.1:1080  &&  node probe.js
 *          (для прокси с COONECT; поддерживаются http(s):// прокси)
 * ========================================================================== */

'use strict';

const http2 = require('http2');
const https = require('https');
const net = require('net');
const tls = require('tls');
const { URL } = require('url');

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const TARGETS = ['https://perchance.org/welcome', 'https://perchance.org/'];

const COMMON = {
  'user-agent': UA,
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'en-US,en;q=0.9',
  'accept-encoding': 'gzip, deflate, br',
  'sec-ch-ua': '"Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"',
  'sec-ch-ua-mobile': '?0',
  'sec-ch-ua-platform': '"macOS"',
  'sec-fetch-dest': 'document',
  'sec-fetch-mode': 'navigate',
  'sec-fetch-site': 'none',
  'sec-fetch-user': '?1',
  'upgrade-insecure-requests': '1',
  'priority': 'u=0, i'
};

/* ------------------------------------------------------------------ direct H2 */
function h2Direct(url) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const client = http2.connect(u.origin);
    const timer = setTimeout(() => { try { client.destroy(); } catch (e) {} resolve({ ok: false, err: 'timeout' }); }, 20000);
    client.on('error', (e) => { clearTimeout(timer); resolve({ ok: false, err: e.message }); });
    const req = client.request(Object.assign({ ':method': 'GET', ':path': u.pathname + u.search }, COMMON));
    let status = 0, mitigated = '';
    req.on('response', (hd) => { status = hd[':status']; mitigated = hd['cf-mitigated'] || ''; });
    req.resume();
    req.on('end', () => { clearTimeout(timer); client.close(); resolve({ ok: status === 200, status, mitigated }); });
    req.on('error', (e) => { clearTimeout(timer); resolve({ ok: false, err: e.message }); });
  });
}

/* ------------------------------------------------------- H2 через HTTP-прокси */
function h2ViaProxy(proxyUrl, targetUrl) {
  return new Promise((resolve) => {
    const p = new URL(proxyUrl);
    const u = new URL(targetUrl);
    const socket = net.connect(Number(p.port || 80), p.hostname, () => {
      socket.write(`CONNECT ${u.hostname}:443 HTTP/1.1\r\nHost: ${u.hostname}:443\r\n\r\n`);
    });
    let head = Buffer.alloc(0);
    const onData = (chunk) => {
      head = Buffer.concat([head, chunk]);
      const idx = head.indexOf('\r\n\r\n');
      if (idx < 0) { return; }
      socket.removeListener('data', onData);
      const first = head.slice(0, idx).toString().split('\r\n')[0];
      if (!/\s200\s/.test(first)) { resolve({ ok: false, err: 'proxy CONNECT: ' + first }); return; }
      const rest = head.slice(idx + 4);
      const tlsSock = tls.connect({ socket, servername: u.hostname, ALPNProtocols: ['h2'] }, () => {
        const client = http2.connect(u.origin, { createConnection: () => tlsSock });
        const req = client.request(Object.assign({ ':method': 'GET', ':path': u.pathname }, COMMON));
        let status = 0, mitigated = '';
        req.on('response', (hd) => { status = hd[':status']; mitigated = hd['cf-mitigated'] || ''; });
        req.resume();
        req.on('end', () => { client.close(); resolve({ ok: status === 200, status, mitigated }); });
        req.on('error', (e) => resolve({ ok: false, err: e.message }));
      });
      tlsSock.on('error', (e) => resolve({ ok: false, err: 'tls: ' + e.message }));
      if (rest.length) { tlsSock.unshift && tlsSock.unshift(rest); }
    };
    socket.on('data', onData);
    socket.on('error', (e) => resolve({ ok: false, err: 'proxy: ' + e.message }));
    setTimeout(() => resolve({ ok: false, err: 'timeout' }), 25000);
  });
}

/* -------------------------------------------------------------- direct H1.1 */
function h1Direct(url) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const r = https.request(u, { method: 'GET', headers: COMMON }, (res) => {
      res.resume();
      resolve({ ok: res.statusCode === 200, status: res.statusCode, mitigated: res.headers['cf-mitigated'] || '' });
    });
    r.on('error', (e) => resolve({ ok: false, err: e.message }));
    r.setTimeout(20000, () => r.destroy(new Error('timeout')));
    r.end();
  });
}

/* ---------------------------------------------------------------------- main */
(async () => {
  const proxy = process.env.LP_UPSTREAM_PROXY || '';

  console.log('');
  console.log('Cloudflare probe — perchance.org');
  console.log('Прокси (LP_UPSTREAM_PROXY):', proxy || '—');
  console.log('');

  for (const t of TARGETS) {
    const a = await h2Direct(t);
    const b = proxy ? await h2ViaProxy(proxy, t) : null;
    const c = t.endsWith('/') ? await h1Direct(t) : null;
    console.log(t);
    console.log('  HTTP/2  напрямую :', fmt(a));
    if (b) { console.log(`  HTTP/2  через ${proxy} :`, fmt(b)); }
    if (c) { console.log('  HTTP/1.1 напрямую:', fmt(c)); }
    console.log('');
  }

  console.log('Если HTTP/2 напрямую = 200 — прокси заработает без настроек.');
  console.log('Если везде 403/challenge — нужен «чистый» IP или браузер-прокладка.');
  console.log('');
})();

function fmt(r) {
  if (!r) { return 'пропущено'; }
  if (r.ok) { return '200 OK'; }
  if (r.status) { return r.status + (r.mitigated ? ' (cf-mitigated=' + r.mitigated + ')' : ''); }
  return 'ошибка: ' + r.err;
}
