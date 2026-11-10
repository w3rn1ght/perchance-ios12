/* ============================================================================
 * html.js — переписывание HTML-ответов
 * ----------------------------------------------------------------------------
 * 1) вставляет полифилы/рантайм/CSS-фолбэки ДО скриптов сайта;
 * 2) вырезает Content-Security-Policy (иначе наши скрипты и eval запрещены);
 * 3) транспилирует inline-<script> (в них у Perchance тоже есть ?. и ??);
 * 4) (dev-режим) подменяет домены на *.localhost, чтобы можно было тестировать
 *    локально в обычном браузере.
 * ========================================================================== */

'use strict';

const { transformJS } = require('./transform.js');

const HEAD_INJECT =
  '<script src="/__legacy/polyfills.js"></script>' +
  '<script src="/__legacy/legacy.js"></script>' +
  '<link rel="stylesheet" href="/__legacy/compat.css">';

/** Быстрая проверка: есть ли в коде синтаксис новее ES2018. */
const NEEDS_TRANSPILE = /\?\.|\?\?|\|\|=|&&=|#[A-Za-z_$][\w$]*\s*[=(;]|static\s*\{/;

const JS_TYPES = /^(|text\/javascript|application\/javascript|application\/x-javascript|module|text\/ecmascript|application\/ecmascript)$/i;

function isJavascriptType(type) {
  if (!type) { return true; }
  return JS_TYPES.test(type.trim());
}

function transformHtml(html, opts) {
  const options = opts || {};
  let out = html;

  // --- CSP meta: без этого браузер заблокирует наши скрипты и eval сайта
  out = out.replace(/<meta[^>]+http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>/gi, '');

  // --- inline-скрипты
  out = replaceScripts(out);

  // --- dev-режим: домены → *.localhost
  if (options.devMode && options.devPort) {
    out = devRewrite(out, options.devPort);
  }

  // --- вставка наших скриптов
  out = injectHead(out);

  return out;
}

function replaceScripts(html) {
  return html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi, (m, attrs, body) => {
    if (/\bsrc\s*=/i.test(attrs)) { return m; }

    const typeMatch = /\btype\s*=\s*["']?([^"'\s>]+)/i.exec(attrs);
    const type = typeMatch ? typeMatch[1] : '';
    if (!isJavascriptType(type)) { return m; }

    if (!body || !NEEDS_TRANSPILE.test(body)) { return m; }

    const isModule = /^module$/i.test(type);
    const res = transformJS(body, { sourceType: isModule ? 'module' : 'script' });
    if (!res.ok) { return m; } // не смогли — пусть идёт как есть
    return `<script${attrs}>${res.code}</script>`;
  });
}

function injectHead(html) {
  // после <head ...>, иначе после <html ...>, иначе в начало
  const headRe = /<head\b[^>]*>/i;
  if (headRe.test(html)) {
    return html.replace(headRe, (m) => m + HEAD_INJECT);
  }
  const htmlRe = /<html\b[^>]*>/i;
  if (htmlRe.test(html)) {
    return html.replace(htmlRe, (m) => m + '<head>' + HEAD_INJECT + '</head>');
  }
  return HEAD_INJECT + html;
}

/** Только для локальной отладки в Chrome/Edge: perchance.org → perchance.org.localhost:8443 */
function devRewrite(text, port) {
  const suffix = 'perchance.org.localhost:' + port;
  return text
    // 1) полные URL: https://x.perchance.org → http://x.perchance.org.localhost:PORT
    //    (в т.ч. шаблонные строки вида https://${id}.perchance.org)
    .replace(/https:\/\/([^\s"'`<>()]*?)perchance\.org(?![\w.:-]*localhost)/gi,
      (m, pre) => 'http://' + pre + suffix)
    // 2) остальные упоминания домена (сравнения origin и т.п.)
    .replace(/perchance\.org(?![\w.:-]*localhost)/g, suffix);
}

module.exports = { transformHtml, HEAD_INJECT };
