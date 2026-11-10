#!/usr/bin/env node
/* ============================================================================
 * diag.js — проверка сети: может ли этот компьютер достать perchance.org
 * ----------------------------------------------------------------------------
 * Запуск:  node diag.js
 * Покажет статус, заголовки Cloudflare и подсказку, если включён IPv6.
 * ========================================================================== */

'use strict';

const http = require('http');
const https = require('https');
const dns = require('dns');
const { transformJS, patchCSS } = require('./lib/transform.js');

const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

function get(url, opts) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(u, {
      headers: Object.assign({ 'user-agent': UA, accept: '*/*' }, opts || {})
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.setTimeout(20000, () => req.destroy(new Error('timeout')));
    req.end();
  });
}

async function check(label, url, opts) {
  try {
    const r = await get(url, opts);
    const cf = r.headers['cf-mitigated'] || '-';
    console.log(`  ${label.padEnd(22)} ${r.status}  cf-mitigated=${cf}  ${(r.body.length / 1024).toFixed(0)}KB`);
    return r;
  } catch (e) {
    console.log(`  ${label.padEnd(22)} ОШИБКА: ${e.message}`);
    return null;
  }
}

(async () => {
  console.log('');
  console.log('=== 1. DNS ===');
  await new Promise((resolve) => {
    dns.lookup('perchance.org', { all: true }, (err, addrs) => {
      if (err) { console.log('  ОШИБКА DNS:', err.message); return resolve(); }
      for (const a of addrs) { console.log(`  perchance.org → ${a.address} (IPv${a.family})`); }
      resolve();
    });
  });

  console.log('');
  console.log('=== 2. Обращения к perchance.org ===');
  await check('HTML /welcome', 'https://perchance.org/welcome');
  const lib = await check('appExtras.js', 'https://perchance.org/lib/appExtras.js');
  await check('поддомен генератора', 'https://a257cd3ebbfff8e014d264b056e5727d.perchance.org/welcome');

  console.log('');
  console.log('=== 3. Локальная транспиляция (Babel) ===');
  const t0 = Date.now();
  const probe = transformJS('const a = o?.b ?? 1; class X { #p = 1; }', {});
  console.log(`  Babel: ${probe.ok ? 'OK' : 'ОШИБКА: ' + probe.error} (${Date.now() - t0} мс)`);
  console.log(`  CSS:   inset → ${patchCSS('a{inset:0}').trim()}`);

  console.log('');
  console.log('=== 4. Итог ===');
  if (lib && lib.status === 200) {
    console.log('  Узлы Perchance доступны (статика отдаётся).');
    console.log('  Если HTML страницы всё равно отдаёт 403/challenge —');
    console.log('  это защита Cloudflare от «не-браузеров», понадобится другой подход (см. README).');
  } else {
    console.log('  Сервер не может получить файлы с perchance.org.');
    console.log('  Проверь интернет, VPN/прокси и IPv6 (см. README).');
  }
  console.log('');
})().catch((e) => {
  console.error('diag error:', e);
  process.exit(1);
});
