#!/usr/bin/env node
/* ============================================================================
 * Perchance Legacy Portal — прозрачный прокси для iOS 12 / Safari 12
 * ============================================================================
 *
 *  iPhone ──► этот сервер ──► perchance.org + *.perchance.org
 *                     │
 *                     └─ на лету переписывает JS под ES2018 и добавляет полифилы
 *
 * Почему прокси: файлы perchance.org содержат optional chaining (`?.`),
 * который Safari 12 не может даже разобрать — движок падает с SyntaxError,
 * поэтому интерфейс не появляется. Полифилом это не лечится, нужна
 * транспиляция ДО того, как код попадёт в браузер телефона.
 *
 * Запуск:  node server.js       (или двойной клик по start.bat)
 * Телефон:  http://<IP-адрес-ПК>:8443
 * ========================================================================== */

'use strict';

const http = require('http');
const https = require('https');
const http2 = require('http2');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const { transformJS, patchCSS } = require('./lib/transform.js');
const { transformHtml } = require('./lib/html.js');

/* ------------------------------------------------------------------ настройки */

const ROOT = __dirname;
const LIB = path.join(ROOT, 'lib');

const CONFIG = {
  // HTTP-порт нужен только для страницы настройки и для локальных тестов.
  httpPort: Number(process.env.LP_HTTP_PORT || 8443),
  // HTTPS должен быть именно 443: телефон открывает https://perchance.org без порта.
  httpsPort: Number(process.env.LP_HTTPS_PORT || 443),
  // dev-режим полезен для проверки на компьютере в обычном браузере:
  // perchance.org → perchance.org.localhost:8443 (Chrome резолвит *.localhost сам)
  devMode: process.env.LP_DEV === '1' || process.argv.includes('--dev'),
  // Если Cloudflare блокирует серверные запросы — можно поднимать настоящий
  // браузер (Chrome/Edge) и брать HTML из него. По умолчанию выключено.
  browserFallback: process.env.LP_BROWSER === '1',
  // Собирать заголовки «с нуля» (без Node/Electron-хвостов). Cloudflare
  // иначе присылает challenge. По умолчанию включено.
  syntheticHeaders: process.env.LP_SYNTHETIC !== '0',
  cacheDir: path.join(ROOT, 'cache'),
  verbose: process.env.LP_VERBOSE !== '0'
};

const UPSTREAM_ORIGIN = 'https://perchance.org';
const ROOT_HOST = 'perchance.org';
const UA_IOS =
  'Mozilla/5.0 (iPad; CPU OS 12_5_7 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/12.1 Mobile/15E148 Safari/604.1';

const UA_DESKTOP =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const MIME = {
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm'
};

if (!fs.existsSync(CONFIG.cacheDir)) { fs.mkdirSync(CONFIG.cacheDir, { recursive: true }); }

/* --------------------------------------------------------------- утилиты лога */

function log(...args) {
  if (!CONFIG.verbose) { return; }
  const t = new Date().toTimeString().slice(0, 8);
  console.log(`[${t}]`, ...args);
}

function localIPs() {
  const os = require('os');
  const out = [];
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const addr of ifs[name] || []) {
      if (addr.family === 'IPv4' && !addr.internal) {
        out.push({ name, address: addr.address });
      }
    }
  }
  return out;
}

/* ------------------------------------------------------------ чтение запроса */

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 50 * 1024 * 1024) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/* ------------------------------------------------------------ определение хоста */

/**
 * Приводим host к «чистому» имени без порта.
 *  - dev:  perchance.org.localhost:8443  → perchance.org.localhost
 *  - prod: perchance.org                 → perchance.org
 */
function normalizeHost(host) {
  return String(host || '').split(':')[0].toLowerCase().replace(/\.$/, '');
}

function isPerchanceHost(host) {
  const h = normalizeHost(host).replace(/\.localhost$/, '');
  if (!h) { return false; }
  return h === ROOT_HOST || h.endsWith('.' + ROOT_HOST);
}

/** Url, который уйдёт на сервер Perchance. */
function buildUpstreamUrl(req) {
  let host = normalizeHost(req.headers.host).replace(/\.localhost$/, '');
  if (!isPerchanceHost(host)) { host = ROOT_HOST; }
  let urlPath = req.url || '/';
  if (!urlPath.startsWith('/')) { urlPath = '/' + urlPath; }
  return 'https://' + host + urlPath;
}

/* ------------------------------------------------------------ HTTP-клиент up */

/**
 * Запрос к Perchance через HTTP/2.
 *
 * Важно: Cloudflare на perchance.org отдаёт 403 (managed challenge) любым
 * HTTP/1.1-запросам не из браузера, но спокойно пропускает HTTP/2 с
 * браузерными заголовками. Поэтому upstream — строго HTTP/2 (+ fallback на
 * HTTP/1.1 для остальных хостов).
 */
const H2_DROP = new Set([
  'host', 'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding',
  'upgrade', 'te', 'content-length', 'accept-encoding', 'if-none-match',
  'if-modified-since', 'proxy-authorization'
]);

const sessions = new Map();

function getSession(origin) {
  let s = sessions.get(origin);
  if (s && !s.closed && !s.destroyed) { return s; }
  s = http2.connect(origin);
  s.setMaxListeners(0);
  s.on('error', () => { sessions.delete(origin); });
  s.on('close', () => { sessions.delete(origin); });
  s.on('goaway', () => { sessions.delete(origin); });
  sessions.set(origin, s);
  return s;
}

function buildUpstreamHeaders(req, host, path, h2) {
  if (CONFIG.syntheticHeaders) {
    return buildSyntheticHeaders(req, host, path, h2);
  }
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    const key = k.toLowerCase();
    if (H2_DROP.has(key)) { continue; }
    // Заголовки, значения которых выдают Electron/Node/прокси — Cloudflare
    // по ним отличает «не браузер» и отвечает managed challenge.
    if (H2_STRIP.has(key)) { continue; }
    // Ниже эти заголовки выставляются принудительно.
    if (/^(accept|sec-.*|priority|dnt|upgrade-insecure-requests)$/.test(key)) { continue; }
    headers[key] = v;
  }
  headers['user-agent'] = UA_DESKTOP;
  headers['accept-encoding'] = 'gzip, deflate, br';
  headers['accept-language'] = 'en-US,en;q=0.9';

  // Origin/Referer приходят с адреса прокси (LAN-IP или *.localhost) — Cloudflare
  // такие запросы помечает как challenge. Переписываем на настоящий домен.
  const realOrigin = 'https://' + host;
  if (headers['origin']) { headers['origin'] = realOrigin; }
  if (headers['referer']) {
    try {
      const refPath = new URL(headers['referer']).pathname;
      headers['referer'] = realOrigin + refPath;
    } catch (e) {
      headers['referer'] = realOrigin + '/';
    }
  }

  if (h2) {
    headers['sec-ch-ua'] = '"Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"';
    headers['sec-ch-ua-mobile'] = '?0';
    headers['sec-ch-ua-platform'] = '"macOS"';
    headers['priority'] = 'u=0, i';
  }

  const p = String(path || '/').split('?')[0].toLowerCase();
  let dest = 'document';
  let accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8';
  if (/\.m?js$/.test(p)) {
    dest = 'script';
    accept = '*/*';
  } else if (/\.css$/.test(p)) {
    dest = 'style';
    accept = 'text/css,*/*;q=0.1';
  } else if (/\.(png|jpe?g|gif|webp|avif|svg|ico|bmp)$/.test(p)) {
    dest = 'image';
    accept = 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8';
  } else if (/\.(woff2?|ttf|otf|eot)$/.test(p)) {
    dest = 'font';
    accept = '*/*';
  } else if (/\/(api|__)/.test(p)) {
    dest = 'empty';
    accept = '*/*';
  }

  headers['accept'] = accept;
  headers['sec-fetch-mode'] = dest === 'document' ? 'navigate' : 'no-cors';
  headers['sec-fetch-dest'] = dest;
  headers['sec-fetch-site'] = 'same-origin';
  if (dest === 'document') {
    headers['sec-fetch-site'] = 'none';
    headers['sec-fetch-user'] = '?1';
    headers['upgrade-insecure-requests'] = '1';
  }

  return headers;
}

/** Заголовки, которые нельзя пробрасывать наверх (выдают не-браузер). */
const H2_STRIP = new Set([
  'sec-ch-ua-platform-version', 'sec-ch-ua-arch', 'sec-ch-ua-bitness',
  'sec-ch-ua-full-version', 'sec-ch-ua-full-version-list', 'sec-ch-ua-model',
  'sec-ch-ua-wow64', 'connection', 'keep-alive', 'proxy-connection',
  'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'via',
  'forwarded', 'x-real-ip', 'dnt', 'priority'
]);

/**
 * Заголовки «как у iPad-а», собранные с нуля (без Electron/Node-хвостов).
 * Именно эти запросы Cloudflare пропускает.
 */
function buildSyntheticHeaders(req, host, path, h2) {
  const headers = {
    'user-agent': UA_IOS,
    'accept-encoding': 'gzip, deflate, br',
    'accept-language': 'en-US,en;q=0.9'
  };
  const p = String(path || '/').split('?')[0].toLowerCase();
  let accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
  let dest = 'document';
  let mode = 'navigate';
  if (/\.m?js$/.test(p)) { accept = '*/*'; dest = 'script'; mode = 'no-cors'; }
  else if (/\.css$/.test(p)) { accept = 'text/css,*/*;q=0.1'; dest = 'style'; mode = 'no-cors'; }
  else if (/\.(png|jpe?g|gif|webp|avif|svg|ico|bmp)$/.test(p)) {
    accept = 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8';
    dest = 'image'; mode = 'no-cors';
  } else if (/\.(woff2?|ttf|otf|eot)$/.test(p)) { accept = '*/*'; dest = 'font'; mode = 'no-cors'; }
  else if (/\/(api|__)/.test(p)) { accept = '*/*'; dest = 'empty'; mode = 'cors'; }

  headers['accept'] = accept;
  if (h2) {
    headers['sec-fetch-dest'] = dest;
    headers['sec-fetch-mode'] = mode;
    headers['sec-fetch-site'] = dest === 'document' ? 'none' : 'same-origin';
    if (dest === 'document') {
      headers['sec-fetch-user'] = '?1';
      headers['upgrade-insecure-requests'] = '1';
    }
  }

  // Cookies пользователя не отправляем — сессия (логин) живёт на клиенте,
  // а для публичных страниц они не нужны.
  if (req.headers.cookie) {
    // Оставляем только безопасные (без сессии) cookie, если понадобится.
  }
  return headers;
}

function fetchUpstreamH1(urlStr, req, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const headers = buildUpstreamHeaders(req, u.host, u.pathname, false);
    if (body && body.length) { headers['content-length'] = String(body.length); }
    const up = https.request(u, { method: req.method, headers }, (upRes) => {
      resolve({ statusCode: upRes.statusCode, headers: upRes.headers, stream: upRes });
    });
    up.on('error', reject);
    up.setTimeout(30000, () => up.destroy(new Error('upstream timeout')));
    if (req.method !== 'GET' && req.method !== 'HEAD' && body && body.length) { up.write(body); }
    up.end();
  });
}

function fetchUpstream(urlStr, req, body) {
  const u = new URL(urlStr);
  if (u.protocol !== 'https:') { return fetchUpstreamH1(urlStr, req, body); }

  return new Promise((resolve, reject) => {
    let settled = false;
    const fail = (err) => { if (!settled) { settled = true; reject(err); } };

    let session;
    try {
      session = getSession(u.origin);
    } catch (e) {
      return fetchUpstreamH1(urlStr, req, body).then(resolve, reject);
    }

    const headers = buildUpstreamHeaders(req, u.host, u.pathname, true);
    headers[':method'] = req.method;
    headers[':path'] = (u.pathname || '/') + (u.search || '');
    // ВАЖНО: не задавать :authority и :scheme вручную — Node формирует их сам,
    // а explicit :authority вызывает 403 (managed challenge) от Cloudflare.
    if (process.env.LP_DUMP === '1') {
      log('UPSTREAM HEADERS', urlStr, JSON.stringify(headers));
    }

    // Cloudflare ожидает content-length для не-GET запросов; для GET/HEAD он
    // при одном пустом теле вообще не нужен.
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      headers['content-length'] = String((body && body.length) || 0);
    }

    let stream;
    try {
      stream = session.request(headers, { endStream: !(body && body.length) });
    } catch (e) {
      sessions.delete(u.origin);
      return fetchUpstreamH1(urlStr, req, body).then(resolve, reject);
    }

    stream.on('response', (hd) => {
      settled = true;
      const outHeaders = {};
      for (const k of Object.keys(hd)) {
        if (k.startsWith(':')) { continue; }
        const v = hd[k];
        outHeaders[k] = Array.isArray(v) ? v : String(v);
      }
      if (hd[':status']) { outHeaders[':status'] = hd[':status']; }
      resolve({
        statusCode: hd[':status'],
        headers: outHeaders,
        stream
      });
    });
    stream.on('error', (e) => {
      sessions.delete(u.origin);
      fail(e);
    });
    // если сервер не ответил вовсе
    stream.setTimeout && stream.setTimeout(30000, () => fail(new Error('upstream timeout')));

    if (body && body.length) { stream.end(body); }
  });
}


function decompress(buf, encoding) {
  if (!buf || !buf.length || !encoding) { return buf; }
  const enc = String(encoding).toLowerCase().trim();
  try {
    if (enc === 'gzip' || enc === 'x-gzip') { return zlib.gunzipSync(buf); }
    if (enc === 'deflate') { return zlib.inflateSync(buf); }
    if (enc === 'br') { return zlib.brotliDecompressSync(buf); }
    if (enc === 'zstd' && zlib.zstdDecompressSync) { return zlib.zstdDecompressSync(buf); }
  } catch (e) {
    log('decompress failed (' + enc + '):', e.message);
  }
  return buf;
}

/* ------------------------------------------------------------ заголовки вниз */

// Заголовки, которые не должны проходить к клиенту как есть.
const DROP_RESPONSE_HEADERS = new Set([
  'content-security-policy',
  'content-security-policy-report-only',
  'cross-origin-embedder-policy',
  'cross-origin-embedder-policy-report-only',
  'cross-origin-opener-policy',
  'cross-origin-opener-policy-report-only',
  'cross-origin-resource-policy',
  'cf-mitigated',
  'cf-ray',
  'nel',
  'report-to',
  'reporting-endpoints',
  'expect-ct',
  'strict-transport-security',
  'alt-svc',
  'content-encoding',
  'content-length',
  'transfer-encoding',
  'connection',
  'keep-alive',
  'set-cookie',
  'server-timing',
  'link'
]);

/* ------------------------------------------------------ Service Worker заглушка */

const SW_SHIM = `/* legacy-portal sw shim */
self.addEventListener("install",function(e){self.skipWaiting()});
self.addEventListener("activate",function(e){e.waitUntil(self.registration.unregister())});
`;

/* ----------------------------------------------------------------- обработчики */

const STATIC_FILES = {
  '/__legacy/polyfills.js': { file: 'polyfills.js', mime: MIME['.js'] },
  '/__legacy/legacy.js': { file: 'legacy.js', mime: MIME['.js'] },
  '/__legacy/compat.css': { file: 'compat.css', mime: MIME['.css'] },
  '/__legacy/sw.js': { file: null, mime: MIME['.js'], inline: SW_SHIM },
  // Ядро для iOS-приложения: тот же трансформер, но без Node.
  '/__legacy/babel.min.js': { file: 'babel.min.js', mime: MIME['.js'] },
  '/__legacy/core-js-bundle.js': { file: 'core-js-bundle.js', mime: MIME['.js'] },
  '/__legacy/transform-web.js': { file: 'web/transform-web.js', mime: MIME['.js'] },
  '/__legacy/selftest.html': { file: 'web/selftest.html', mime: MIME['.html'] },
  // Логика транспайлера для iOS-приложения (тот же файл кладётся в бандл).
  '/__legacy/transform.js': { file: 'web/transform-web.js', mime: MIME['.js'] },
  '/__legacy/ca.crt': { cert: 'ca.crt', mime: 'application/x-x509-ca-cert' },
  '/ca.crt': { cert: 'ca.crt', mime: 'application/x-x509-ca-cert' },
  '/__legacy/ping': { file: null, mime: MIME['.json'], inline: '{"ok":true,"portal":"perchance-ios12"}' }
};

function serveStatic(req, res, entry) {
  if (entry.cert) {
    const p = path.join(CERT_DIR, entry.cert);
    if (!fs.existsSync(p)) {
      res.writeHead(404, { 'content-type': MIME['.txt'] });
      return res.end('Сертификат ещё не создан. Запусти make-cert.bat');
    }
    const b = fs.readFileSync(p);
    res.writeHead(200, {
      'content-type': entry.mime,
      'content-disposition': 'attachment; filename="perchance-legacy-portal-ca.crt"',
      'content-length': String(b.length)
    });
    return res.end(req.method === 'HEAD' ? undefined : b);
  }
  const content = entry.inline !== undefined
    ? Buffer.from(entry.inline, 'utf8')
    : fs.readFileSync(path.join(LIB, entry.file));
  res.writeHead(200, {
    'content-type': entry.mime,
    'cache-control': 'no-cache, max-age=0',
    'access-control-allow-origin': '*'
  });
  res.end(req.method === 'HEAD' ? undefined : content);
}

async function handle(req, res) {
  const urlPath = (req.url || '/').split('?')[0];

  if (STATIC_FILES[urlPath]) {
    return serveStatic(req, res, STATIC_FILES[urlPath]);
  }
  if (urlPath === '/__legacy/' || urlPath === '/__legacy') {
    res.writeHead(200, { 'content-type': MIME['.html'] });
    return res.end('<h1>Perchance Legacy Portal</h1><p>Сервер работает. Откройте <a href="/welcome">/welcome</a>.</p>');
  }

  // По IP-адресу (http://192.168.x.x:8443/) показываем инструкцию по настройке,
  // а не сайт: именно этот адрес человек набирает на телефоне первым.
  if (urlPath === '/' && !isPerchanceHost(req.headers.host)) {
    const html = Buffer.from(setupPage(req), 'utf8');
    res.writeHead(200, { 'content-type': MIME['.html'], 'content-length': String(html.length) });
    return res.end(html);
  }

  // В корне прокси (localhost:8443/) нет смысла показывать «генератор welcome» —
  // ведём на главную Perchance так же, как это делает сам сайт.
  if (urlPath === '/__legacy/status') {
    return sendJSON(res, 200, statusInfo());
  }

  const body = await readBody(req);
  let upstreamUrl = buildUpstreamUrl(req);

  let up;
  try {
    up = await fetchUpstream(upstreamUrl, req, body);
  } catch (err) {
    log('upstream error', upstreamUrl, err.message);
    res.writeHead(502, { 'content-type': MIME['.html'] });
    return res.end('<h1>502 — Perchance недоступен</h1><pre>' +
      escapeHtml(String(err.message)) + '</pre>');
  }

  let status = up.statusCode || 502;
  let headers = up.headers;
  let stream = up.stream;

  // Cloudflare challenge: если включён браузерный режим — пробуем через браузер,
  // иначе честно сообщаем пользователю.
  if (headers['cf-mitigated'] === 'challenge') {
    stream.resume();
    log('CF CHALLENGE for', upstreamUrl);
    if (process.env.LP_DEBUG_CF === '1') {
      try {
        require('fs').appendFileSync(
          require('path').join(ROOT, 'cf-debug.log'),
          JSON.stringify({
            url: upstreamUrl,
            headers: req.headers,
            upstream: headers
          }) + '\n');
      } catch (e) {}
    }
    if (CONFIG.browserFallback && /text\/html/.test(String(headers['content-type'] || ''))) {
      try {
        const { fetchPage } = require('./lib/browser.js');
        const page = await fetchPage(upstreamUrl, 45000);
        if (page && page.status === 200 && !/Just a moment|Performing security verification/i.test(page.title + page.html.slice(0, 2000))) {
          const out = Buffer.from(transformHtml(page.html, {
            devMode: CONFIG.devMode,
            devPort: CONFIG.httpPort
          }), 'utf8');
          res.writeHead(200, {
            'content-type': MIME['.html'],
            'content-length': String(out.length),
            'cache-control': 'no-store',
            'x-legacy-portal': 'browser'
          });
          return res.end(out);
        }
      } catch (e) {
        log('browser fallback failed:', e.message);
      }
    }
    res.writeHead(503, { 'content-type': MIME['.html'] });
    return res.end(cfBlockPage(upstreamUrl));
  }

  const contentType = String(headers['content-type'] || '').toLowerCase();

  const isHtml = contentType.includes('text/html');
  const isJS = /(javascript|ecmascript)/.test(contentType) || /\.m?js(\?|$)/i.test(upstreamUrl);
  const isCSS = contentType.includes('text/css');
  const isWorkerScript = rawWorkers(urlPath);
  const mustTransform = isJS || isCSS || isHtml || isWorkerScript;

  const outHeaders = {};
  for (const [k, v] of Object.entries(headers)) {
    if (k.startsWith(':')) { continue; }
    if (DROP_RESPONSE_HEADERS.has(k)) { continue; }
    if (k === 'location') { continue; }
    if (k === 'content-disposition') { continue; }
    outHeaders[k] = v;
  }

  // Location: абсолютные https://perchance.org/... надо приземлить на прокси.
  if (headers.location) {
    outHeaders.location = String(headers.location).replace(
      /^https:\/\/([a-z0-9.-]*perchance\.org)/i, 'http://' + (req.headers.host || ROOT_HOST)
    );
  }

  // Set-Cookie: убираем Domain=.perchance.org, чтобы cookie работали и на http-адресе прокси.
  const setCookie = headers['set-cookie'];
  if (setCookie) {
    outHeaders['set-cookie'] = (Array.isArray(setCookie) ? setCookie : [setCookie]).map((c) =>
      c.replace(/;\s*domain=[^;]+/gi, '').replace(/;\s*secure/gi, ''));
  }

  // --- Нетрансформируемые ответы (картинки, шрифты, большие видео) — потоком.
  if (!mustTransform || status >= 300) {
    res.writeHead(status, sanitizeHead(outHeaders));
    if (req.method === 'HEAD') { stream.resume(); return res.end(); }
    stream.on('data', (c) => res.write(c));
    stream.on('end', () => res.end());
    stream.on('error', () => { try { res.destroy(); } catch (e) {} });
    return;
  }

  const chunks = [];
  await new Promise((resolve, reject) => {
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', resolve);
    stream.on('error', reject);
  });
  const buf = decompress(Buffer.concat(chunks), headers['content-encoding']);

  let outBuf = buf;

  // Service Worker оболочки — отключаем (иначе он будет отдавать непереписанные файлы)
  if (isWorkerScript) {
    outBuf = Buffer.from(SW_SHIM, 'utf8');
  } else if (isJS) {
    const src = buf.toString('utf8');
    const sourceType = /\.mjs(\?|$)/i.test(upstreamUrl) ? 'module' : 'script';
    const result = transformJS(src, { sourceType });
    outBuf = Buffer.from(result.code, 'utf8');
    if (!result.ok) {
      log('transpile failed:', upstreamUrl, result.error.slice(0, 160));
    }
  } else if (isCSS) {
    outBuf = Buffer.from(patchCSS(buf.toString('utf8')), 'utf8');
  } else if (isHtml) {
    outBuf = Buffer.from(transformHtml(buf.toString('utf8'), {
      devMode: CONFIG.devMode,
      devPort: CONFIG.httpPort
    }), 'utf8');
  }

  // Кеширующие заголовки могут отдать телефону старую нетранспилированную копию.
  delete outHeaders['etag'];
  delete outHeaders['last-modified'];
  outHeaders['cache-control'] = 'no-store';
  outHeaders['content-length'] = String(outBuf.length);
  outHeaders['x-legacy-portal'] = '1';

  if (CONFIG.verbose && (isHtml || isJS)) {
    log(req.method, status, upstreamUrl.slice(0, 100),
      isJS ? '→ ' + (outBuf.length / 1024).toFixed(0) + 'KB' : '');
  }

  res.writeHead(status, sanitizeHead(outHeaders));
  if (req.method === 'HEAD') { return res.end(); }
  res.end(outBuf);
}

function sanitizeHead(h) {
  const out = {};
  for (const [k, v] of Object.entries(h)) {
    if (v === undefined || v === null) { continue; }
    if (k.startsWith(':')) { continue; }
    out[k] = v;
  }
  return out;
}

function sendJSON(res, status, obj) {
  const b = Buffer.from(JSON.stringify(obj, null, 2), 'utf8');
  res.writeHead(status, { 'content-type': MIME['.json'], 'content-length': String(b.length) });
  res.end(b);
}

function statusInfo() {
  return {
    portal: 'perchance-ios12',
    time: new Date().toISOString(),
    config: {
      httpPort: CONFIG.httpPort,
      httpsPort: CONFIG.httpsPort,
      devMode: CONFIG.devMode
    },
    ips: localIPs()
  };
}

/** Service worker по путям вроде /sw.js, /service-worker.js, /api/sw */
function rawWorkers(p) {
  return /(^|\/)(sw|service-worker|serviceworker)\.js$/i.test(p);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function cfBlockPage(url) {
  return `<!doctype html><meta charset="utf-8"><title>Perchance: проверка Cloudflare</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<body style="font:16px/1.5 -apple-system,system-ui;padding:20px;max-width:720px;margin:auto">
<h2>Cloudflare не пустил прокси</h2>
<p>Запрос к <code>${escapeHtml(String(url))}</code> вернул проверку Cloudflare.
Такое бывает, когда Cloudflare поднял уровень защиты для сети прокси-сервера.</p>
<p><b>Что делать:</b></p>
<ol>
  <li>Проверь на компьютере: <code>node diag.js</code> — если HTML отдаёт 403, значит блокирует именно сеть, а не прокси.</li>
  <li>Переключи сеть/VPN на компьютере и перезапусти сервер.</li>
  <li>Если на iPhone <code>https://perchance.org</code> открывается нормально, а через прокси нет — попробуй другой компьютер или мобильный интернет.</li>
</ol>
<p><a href="/__legacy/status">Статус прокси</a></p>
</body>`;
}

/* --------------------------------------------------------------------- сервер */

function createServer() {
  const server = http.createServer((req, res) => {
    res.setHeader('access-control-allow-origin', req.headers.origin || '*');
    res.setHeader('access-control-allow-credentials', 'true');
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
    handle(req, res).catch((err) => {
      log('handler error:', err && err.stack ? err.stack : err);
      try {
        res.writeHead(500, { 'content-type': MIME['.html'] });
        res.end('<h1>500</h1><pre>' + escapeHtml(String(err && err.message || err)) + '</pre>');
      } catch (e) {}
    });
  });
  server.keepAliveTimeout = 65000;
  server.headersTimeout = 70000;
  return server;
}

const CERT_DIR = path.join(ROOT, 'certs');
const HTTPS2 = (() => {
  try {
    return !!fs.readFileSync(path.join(CERT_DIR, 'key.pem')) &&
      !!fs.readFileSync(path.join(CERT_DIR, 'cert.pem'));
  } catch (e) { return false; }
})();

function startHTTPS() {
  const keyPath = path.join(ROOT, 'certs', 'key.pem');
  const certPath = path.join(ROOT, 'certs', 'cert.pem');
  if (!fs.existsSync(keyPath) || !fs.existsSync(certPath)) {
    console.log('  HTTPS не запущен: нет certs/cert.pem (запусти make-cert.bat)');
    return null;
  }
  const server = http2.createSecureServer({
    key: fs.readFileSync(keyPath),
    cert: fs.readFileSync(certPath),
    allowHTTP1: true
  }, (req, res) => {
    handle(req, res).catch((err) => {
      log('https handler error:', err && err.message);
      try { res.writeHead(500); res.end('500'); } catch (e) {}
    });
  });
  server.on('error', (e) => {
    if (e.code === 'EACCES') {
      console.log('');
      console.log('  !!! Порт ' + CONFIG.httpsPort + ' требует прав администратора.');
      console.log('      Закрой сервер и запусти start.bat правой кнопкой → «Запуск от имени администратора».');
      console.log('      Либо задай LP_HTTPS_PORT=8444 и открывай https://IP:8444 (так iPhone тоже умеет).');
      console.log('');
    } else if (e.code === 'EADDRINUSE') {
      console.log('  !!! Порт ' + CONFIG.httpsPort + ' уже занят. Задай LP_HTTPS_PORT=8444');
    } else {
      console.error(e);
    }
  });
  server.listen(CONFIG.httpsPort, '0.0.0.0', () => {
    const ip = safeLanIP();
    log(`HTTPS: https://${ip}:${CONFIG.httpsPort}/`);
  });
  return server;
}

function safeLanIP() {
  try { return require('./lib/dns.js').lanIPv4(); } catch (e) { return '127.0.0.1'; }
}

function startDNS() {
  try {
    const dnsSrv = require('./lib/dns.js');
    dnsSrv.start({
      log: (m) => log(m),
      onReady: ({ ip }) => {
        console.log('  DNS:   ' + ip + ' (для iPhone: Wi-Fi → DNS → Вручную)');
      }
    });
  } catch (e) {
    console.log('  DNS-сервер не запущен: ' + e.message);
  }
}

/** Страница настройки: открывается на телефоне, чтобы скачать CA и увидеть адреса. */
function setupPage(req) {
  const ip = safeLanIP();
  const httpsPort = CONFIG.httpsPort === 443 ? '' : ':' + CONFIG.httpsPort;
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Perchance для iOS 12 — настройка</title>
<style>
 body{font:17px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:20px;background:#f6f6f6;color:#111}
 h1{font-size:22px;margin:0 0 6px} .card{background:#fff;border-radius:14px;padding:16px;margin:12px 0;box-shadow:0 1px 4px rgba(0,0,0,.08)}
 .step{display:flex;gap:10px;margin:10px 0} .n{flex:0 0 26px;height:26px;border-radius:13px;background:#2b6cb0;color:#fff;text-align:center;font-weight:700;line-height:26px}
 code{background:#eef;padding:2px 6px;border-radius:5px;font-size:15px;word-break:break-all}
 a.btn{display:block;text-align:center;background:#2b6cb0;color:#fff;text-decoration:none;padding:14px;border-radius:12px;font-weight:600;margin-top:10px}
 .ok{color:#18794e;font-weight:600} .warn{color:#b45309}
</style></head><body>
<h1>Perchance для iOS 12</h1>
<p>Прокси работает на компьютере <b>${ip}</b>.</p>

<div class="card">
 <div class="step"><div class="n">1</div><div>Установи корневой сертификат:
   <a class="btn" href="/__legacy/ca.crt">Скачать сертификат (ca.crt)</a>
   Safari спросит «Разрешить профиль» → Разрешить.</div></div>
 <div class="step"><div class="n">2</div><div>Настройки → Основные → VPN и управление устройством → <b>Perchance Legacy Portal CA</b> → Установить.</div></div>
 <div class="step"><div class="n">3</div><div>Настройки → Основные → Об устройстве → <b>Доверие сертификатам</b> → включи «Perchance Legacy Portal CA».</div></div>
 <div class="step"><div class="n">4</div><div>Настройки → Wi-Fi → (i) у своей сети → <b>Настройка DNS → Вручную</b> → добавь <code>${ip}</code>.</div></div>
 <div class="step"><div class="n">5</div><div>Открой в Safari <a href="https://perchance.org${httpsPort}/">https://perchance.org</a>${httpsPort ? ' (порт ' + CONFIG.httpsPort + ')' : ''}</div></div>
</div>

<div class="card">
 <p class="ok">Если шаги 1–4 выполнены — Perchance должен открываться как обычно, только интерфейс будет совместим с iOS 12.</p>
 <p class="warn">Когда прокси выключен, верни DNS на «Автоматически», иначе интернет на телефоне перестанет работать.</p>
</div>
</body></html>`;
}

function main() {
  // Быстрая самопроверка транспиляции
  const probe = transformJS('const a = o?.b ?? 1; class X { #p = 1; }', {});
  if (!probe.ok) {
    console.error('Babel не работает:', probe.error);
    console.error('Проверь наличие файлов lib/babel.min.js и lib/transform.js');
    process.exit(1);
  }

  const server = createServer();
  server.listen(CONFIG.httpPort, '0.0.0.0', () => {
    const ip = safeLanIP();
    console.log('');
    console.log('  === Perchance для iOS 12 — локальный прокси ===');
    console.log('');
    console.log('  Настройка на iPhone: открой в Safari');
    console.log('      http://' + ip + ':' + CONFIG.httpPort + '/');
    console.log('  (там кнопка скачать сертификат и пошаговая инструкция)');
    console.log('');
    if (CONFIG.devMode) { console.log('  DEV-режим: perchance.org → perchance.org.localhost'); }
    console.log('  Остановка: Ctrl+C');
    console.log('');
  });
  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      console.error(`Порт ${CONFIG.httpPort} занят. Закрой другой экземпляр или задай LP_HTTP_PORT=8445`);
    } else {
      console.error(e);
    }
    process.exit(1);
  });

  startHTTPS();
  startDNS();

  const stopAll = () => {
    console.log('\nОстановлено.');
    try { require('./lib/browser.js').shutdown(); } catch (e) {}
    process.exit(0);
  };
  process.on('SIGINT', stopAll);
  process.on('SIGTERM', stopAll);
}

main();


