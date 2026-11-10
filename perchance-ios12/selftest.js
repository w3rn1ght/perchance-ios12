#!/usr/bin/env node
/* ============================================================================
 * selftest.js — проверяет, что прокси реально «чинит» код под Safari 12
 * ----------------------------------------------------------------------------
 * Запускать при работающем server.js:
 *    node selftest.js                 (проверит http://127.0.0.1:8443)
 *    node selftest.js 8443
 * ========================================================================== */

'use strict';

const http = require('http');

const PORT = Number(process.argv[2] || process.env.LP_HTTP_PORT || 8443);
const HOST = '127.0.0.1';

function req(path, hostHeader, extra) {
  return new Promise((resolve, reject) => {
    const r = http.request({
      host: HOST,
      port: PORT,
      path,
      method: 'GET',
      headers: Object.assign({
        host: hostHeader,
        'user-agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_7 like Mac OS X) ' +
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1',
        accept: '*/*'
      }, extra || {})
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    r.on('error', reject);
    r.setTimeout(60000, () => r.destroy(new Error('timeout')));
    r.end();
  });
}

// Синтаксис, который Safari 12 умеет даже разобрать.
// ВАЖНО: паттерны написаны так, чтобы НЕ ловить CSS в JS-строках
// (например `background:#fff` — это не приватное поле, а цвет),
// а также текст внутри строк и шаблонов (комментарии вида "type??").
//
// Ложные срабатывания в `perchance-engine.js` (а не настоящий синтаксис):
//   `(${x}).match(/…/)?.` — это внутри шаблонной строки, которую Perchance
//   потом eval'ит; Babel её не трогает, а сам движок исполняет уже
//   транспилированный текст, поэтому Safari 12 до этого `?.` не доходит.
const BAD_SYNTAX = [
  [/\?\.[A-Za-z_$[(]/, 'optional chaining  ?.'],
  [/[A-Za-z0-9_$)\]]\s*\?\?\s*[A-Za-z0-9_$(["'\-]/, 'nullish coalescing  ??'],
  [/\|\|=[^=]/, 'logical assignment  ||='],
  [/[A-Za-z0-9_$)\]]\s*&&=[^=]/, 'logical assignment  &&='],
  [/\?\?=[^=]/, 'logical assignment  ??='],
  // приватное поле только в начале строки (чтобы не ловить цвета `#fff`)
  [/^[ \t]+#[A-Za-z_$][\w$]*\s*(?:=(?!=)|;)/m, 'private class field  #x'],
  [/\bstatic\s*\{/, 'class static block']
];
/**
 * Грубая проверка «здесь начинается регулярка»: перед `/` не должно быть
 * значения (идентификатор, число, `)`, `]`).
 */
function isRegexStart(src, i) {
  let j = i - 1;
  while (j >= 0 && /\s/.test(src[j])) { j--; }
  if (j < 0) { return true; }
  const p = src[j];
  if (/[A-Za-z0-9_$)\]]/.test(p)) { return false; }
  // `return /re/` и подобные ключевые слова
  if (/[A-Za-z_$]/.test(p)) { return true; }
  return true;
}

/**
 * Оставляет только участки, которые браузер реально парсит как код:
 * строки, шаблоны, регулярки и комментарии заменяются пробелами.
 * Иначе `"type??"` или `/([!?.]+)/g` дают ложные срабатывания.
 */
function codeOnly(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {
      while (i < n && src[i] !== '\n') { out += ' '; i++; }
      continue;
    }
    if (c === '/' && d === '*') {
      out += '  '; i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) { out += ' '; i++; }
      out += '  '; i += 2;
      continue;
    }
    // Регулярное выражение: `/…/flags` — в коде может содержать `?.`, `??`,
    // `#`, и это не синтаксис JS.
    if (c === '/' && isRegexStart(src, i)) {
      i++;
      out += ' ';
      let inClass = false;
      while (i < n) {
        const ch = src[i];
        if (ch === '\\') { out += '  '; i += 2; continue; }
        if (ch === '\n') { break; }
        if (ch === '[') { inClass = true; }
        else if (ch === ']') { inClass = false; }
        else if (ch === '/' && !inClass) { i++; out += ' '; break; }
        out += ' ';
        i++;
      }
      while (i < n && /[a-z]/i.test(src[i])) { out += ' '; i++; }
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      const quote = c;
      out += ' '; i++;
      while (i < n) {
        if (src[i] === '\\') { out += '  '; i += 2; continue; }
        out += (quote === '`' && src[i] === '\n') ? '\n' : ' ';
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

function scan(text) {
  const code = codeOnly(text);
  const found = [];
  for (const [re, label] of BAD_SYNTAX) {
    const m = re.exec(code);
    if (m) {
      const around = code.slice(Math.max(0, m.index - 40), m.index + 40).replace(/\n/g, ' ');
      found.push(label + '  →  …' + around.replace(/\s+/g, ' ') + '…');
    }
  }
  return found;
}

function ok(v) { return v ? 'OK  ' : 'FAIL'; }

(async () => {
  let failed = 0;
  console.log(`\nПроверяю прокси на http://${HOST}:${PORT}\n`);

  // 1. служебные файлы
  const poly = await req('/__legacy/polyfills.js', 'perchance.org');
  console.log(`  [${ok(poly.status === 200 && poly.body.includes('__legacyPortalPolyfills'))}] polyfills.js (${(poly.body.length / 1024).toFixed(0)} KB)`);
  if (poly.status !== 200) { failed++; }

  const css = await req('/__legacy/compat.css', 'perchance.org');
  console.log(`  [${ok(css.status === 200)}] compat.css`);

  // 2. HTML страницы
  const html = await req('/welcome', 'perchance.org');
  const injected = html.body.includes('/__legacy/polyfills.js');
  console.log(`  [${ok(html.status === 200 && injected)}] HTML /welcome: статус ${html.status}, полифилы ${injected ? 'вставлены' : 'НЕ вставлены'}`);
  if (html.status !== 200 || !injected) { failed++; }
  if (html.body.length < 2000) { console.log('     (ответ подозрительно короткий: ' + html.body.length + ' байт)'); }

  // 3. главный виновник — appExtras.js
  const js = await req('/lib/appExtras.js', 'perchance.org');
  const jsBad = scan(js.body);
  console.log(`  [${ok(js.status === 200 && jsBad.length === 0)}] appExtras.js: ${(js.body.length / 1024).toFixed(0)} KB, современного синтаксиса: ${jsBad.length}`);
  for (const b of jsBad) { console.log('     ' + b); }
  if (jsBad.length) { failed++; }

  // 4. движок генераторов
  const m = /perchance-engine-[a-f0-9]+\.js/.exec(html.body);
  if (m) {
    const eng = await req('/lib/' + m[0], 'perchance.org');
    const engBad = scan(eng.body);
    console.log(`  [${ok(eng.status === 200 && engBad.length === 0)}] ${m[0]}: ${(eng.body.length / 1024).toFixed(0)} KB, современного синтаксиса: ${engBad.length}`);
    for (const b of engBad) { console.log('     ' + b); }
    if (engBad.length) { failed++; }
  }

  // 5. CSS
  const pageCss = /href="([^"]+\.css[^"]*)"/.exec(html.body);
  if (pageCss) {
    const c = await req(pageCss[1], 'perchance.org');
    console.log(`  [${ok(c.status === 200)}] CSS ${pageCss[1].slice(0, 60)} (${(c.body.length / 1024).toFixed(0)} KB)`);
  }

  // 6. поддомен генератора (iframe вывода)
  const sub = /https:\/\/([a-f0-9]+)\.perchance\.org\/welcome/.exec(html.body);
  if (sub) {
    const iframe = await req('/welcome', sub[1] + '.perchance.org');
    const injected2 = iframe.body.includes('/__legacy/polyfills.js');
    console.log(`  [${ok(iframe.status === 200 && injected2)}] iframe ${sub[1]}.perchance.org: ${iframe.status}, полифилы ${injected2 ? 'вставлены' : 'НЕ вставлены'}`);
    if (iframe.status !== 200 || !injected2) { failed++; }
  }

  console.log('');
  if (failed === 0) {
    console.log('  ИТОГ: всё в порядке — сервер отдаёт код, совместимый с Safari 12.\n');
    process.exit(0);
  } else {
    console.log(`  ИТОГ: проблем: ${failed}. Смотри сообщения выше.\n`);
    process.exit(1);
  }
})().catch((e) => {
  console.error('\nНе удалось подключиться к прокси:', e.message);
  console.error('Сначала запусти: node server.js\n');
  process.exit(1);
});
