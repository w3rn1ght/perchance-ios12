/* ============================================================================
 * transform-web.js — тот же трансформер, но без Node (для iOS-приложения)
 * ----------------------------------------------------------------------------
 * Отличия от lib/transform.js:
 *   • нет fs/crypto — кеш делает нативная часть приложения;
 *   • Babel берётся из глобальной переменной `Babel` (babel.min.js);
 *   • источники и приёмники — строки.
 *
 * Используется:
 *   — в WKWebView/JSContext внутри приложения Perchance.app;
 *   — в браузерной отладке (см. web/selftest.html).
 *
 * Экспорт: window.PCTransform = { transformJS, transformHTML, patchCSS, VERSION }
 * ========================================================================== */
(function (global) {
  'use strict';

  var VERSION = '1.0.0';

  function rewriteScheme(text, scheme) {
    if (!scheme || !text) { return text; }
    var out = text.replace(/https:\/\/([a-z0-9.-]*perchance\.org)/gi,
      function (m, host) { return scheme + '://' + host; });
    // Протокол-относительные ссылки: //host/perchance.org. Lookbehind в Safari 12
    // нет, поэтому проверяем предыдущий символ вручную.
    out = out.replace(/(^|[^:\w])\/\/([a-z0-9.-]*perchance\.org)/gi,
      function (m, pre, host) { return pre + scheme + '://' + host; });
    return out;
  }

  /* ------------------------------------------------------------------ JS ---- */

  /** Код, который Safari 12 не разберёт даже синтаксически. */
  var NEEDS_TRANSPILE = /\?\.|\?\?|\|\|=|&&=|#[A-Za-z_$][\w$]*\s*[=(;]|static\s*\{/;

  /**
   * Правки внутри СТРОК, из которых Perchance собирает код в рантайме.
   *
   * Движок Perchance формирует текст функции (`finalFunctionBody`) и компилирует
   * его через `new Function(...)`. Babel такой текст не видит: для него это
   * обычный строковый литерал. Внутри обёртки есть `?.[1]` (optional chaining,
   * Safari 13.1+), из-за чего на iOS 12 КАЖДЫЙ вызов генератора падал с
   * SyntaxError — именно это и показывало «(syntax error)» вместо текста.
   *
   * Патчим ровно два места в исходнике (точное совпадение), чтобы Babel потом
   * не пришлось угадывать: `match(...)?.[1]` → `(match(...)||[])[1]`.
   */
  var RUNTIME_STRING_PATCHES = [
    ['e.stack.toString().match(/<anonymous>:([0-9]+):[0-9]/)?.[1]',
     '(e.stack.toString().match(/<anonymous>:([0-9]+):[0-9]/)||[])[1]'],
    ['e.stack.toString().match(/> Function:([0-9]+):[0-9]/)?.[1]',
     '(e.stack.toString().match(/> Function:([0-9]+):[0-9]/)||[])[1]'],
    ['import.meta.url', '(document.currentScript?document.currentScript.src:location.href)'],
    ['import.meta', '{}']
  ];

  function patchRuntimeStrings(code) {
    if (!code) { return code; }
    var out = code;
    for (var i = 0; i < RUNTIME_STRING_PATCHES.length; i++) {
      var from = RUNTIME_STRING_PATCHES[i][0];
      if (out.indexOf(from) !== -1) {
        out = out.split(from).join(RUNTIME_STRING_PATCHES[i][1]);
      }
    }
    return out;
  }

  function targetPresets() {
    return [[
      'env',
      {
        targets: { safari: '12' },
        modules: false,
        bugfixes: true,
        loose: true,
        useBuiltIns: false
      }
    ]];
  }

  /**
   * @param {string} code
   * @param {{filename?:string, sourceType?:'script'|'module', force?:boolean}} opts
   * @returns {{ok:boolean, code:string, skipped?:boolean, error?:string}}
   */
  function transformJS(code, opts) {
    opts = opts || {};
    if (!code) { return { ok: true, code: '', skipped: true }; }
    if (!opts.force && !NEEDS_TRANSPILE.test(code)) {
      // Нового синтаксиса нет — не тратим время на Babel.
      return { ok: true, code: code, skipped: true };
    }
    if (!global.Babel || typeof global.Babel.transform !== 'function') {
      return { ok: false, code: rewriteScheme(code, opts.scheme), error: 'Babel не загружен' };
    }
    try {
      var out = global.Babel.transform(patchRuntimeStrings(code), {
        presets: targetPresets(),
        // sourceType: 'unambiguous' — Babel сам определяет module vs script.
        // Без него ES-модули (например editors.bundle.min.js с import.meta) падают
        // и приложение получает исходный, непереписанный файл → «(syntax error)».
        sourceType: 'unambiguous',
        // compact/comments — не косметика: на iOS 12 каждые лишние мегабайты
        // текста в мосте Babel приближают jetsam. Кеш на диске тоже меньше.
        compact: true,
        comments: false,
        babelrc: false,
        configFile: false,
        parserOpts: {
          allowReturnOutsideFunction: true,
          allowAwaitOutsideFunction: true,
          allowSuperOutsideMethod: true,
          allowUndeclaredExports: true
        }
      });
      return { ok: true, code: rewriteScheme(out.code, opts.scheme) };
    } catch (e) {
      return { ok: false, code: rewriteScheme(code, opts.scheme), error: String(e && e.message || e) };
    }
  }

  /* ----------------------------------------------------------------- CSS ---- */

  function patchCSS(css) {
    if (!css) { return ''; }
    var out = css;

    // inset: 0 / inset: 10px 20px → top/right/bottom/left
    out = out.replace(/(^|[;{]\s*)inset\s*:\s*([^;}{]+)(;|(?=\s*\}))?/g, function (m, pre, val, term) {
      var p = val.trim().split(/\s+/);
      var t = p[0];
      var r = p.length > 1 ? p[1] : t;
      var b = p.length > 2 ? p[2] : t;
      var l = p.length > 3 ? p[3] : r;
      var tail = term || '';
      // Между двумя декларациями нужен `;`, а не повтор префикса.
      var sep = '; ';
      return pre + 'top: ' + t + '; right: ' + r + '; bottom: ' + b + '; left: ' + l +
        sep + 'inset: ' + val.trim() + tail;
    });

    out = out.replace(/(^|[;{]\s*)inset-inline-start\s*:\s*([^;}{]+);/g, '$1left: $2;');
    out = out.replace(/(^|[;{]\s*)inset-inline-end\s*:\s*([^;}{]+);/g, '$1right: $2;');
    out = out.replace(/(^|[;{]\s*)inset-block-start\s*:\s*([^;}{]+);/g, '$1top: $2;');
    out = out.replace(/(^|[;{]\s*)inset-block-end\s*:\s*([^;}{]+);/g, '$1bottom: $2;');
    out = out.replace(/(^|[;{]\s*)inset-inline\s*:\s*([^;}{]+);/g, '$1left: $2; right: $2;');
    out = out.replace(/(^|[;{]\s*)inset-block\s*:\s*([^;}{]+);/g, '$1top: $2; bottom: $2;');

    out = out.replace(/(^|[;{]\s*)(margin|padding)-inline\s*:\s*([^;}{]+);/g, function (m, pre, prop, val) {
      var p = val.trim().split(/\s+/);
      return pre + prop + '-left: ' + p[0] + '; ' + prop + '-right: ' + (p.length > 1 ? p[1] : p[0]) + ';';
    });
    out = out.replace(/(^|[;{]\s*)(margin|padding)-block\s*:\s*([^;}{]+);/g, function (m, pre, prop, val) {
      var p = val.trim().split(/\s+/);
      return pre + prop + '-top: ' + p[0] + '; ' + prop + '-bottom: ' + (p.length > 1 ? p[1] : p[0]) + ';';
    });

    // aspect-ratio — Safari 12 не умеет; запоминаем в переменную (её читает legacy.js)
    out = out.replace(/(^|[;{]\s*)aspect-ratio\s*:\s*([^;}{]+)(;|(?=\s*\}))?/g,
      function (m, pre, val, term) {
        return pre + '--legacy-aspect-ratio: ' + val.trim() + (term || '');
      });

    // gap (flex) → дублируем grid-свойствами + -webkit-префикс
    out = out.replace(/(^|[;{]\s*)gap\s*:\s*([^;}{]+);/g, '$1grid-gap: $2; $1gap: $2;');
    out = out.replace(/(^|[;{]\s*)row-gap\s*:\s*([^;}{]+);/g, '$1grid-row-gap: $2; $1row-gap: $2;');
    out = out.replace(/(^|[;{]\s*)column-gap\s*:\s*([^;}{]+);/g, '$1grid-column-gap: $2; $1column-gap: $2;');

    // light-dark(a, b) → a (iOS 12 всё равно всегда светлая тема)
    out = out.replace(/light-dark\(\s*([^,()]+)\s*,\s*([^()]*?)\)/g, '$1');

    // color-mix(a, b) → первый цвет
    out = out.replace(/color-mix\([^)]*,\s*([^,()]+)[^)]*\)/gi, '$1');

    // oklch() → hex
    out = out.replace(/\boklch\(([^)]*)\)/gi, function (m, inner) {
      var hex = oklchToHex(inner);
      return hex || m;
    });

    // -webkit- префиксы
    var PREFIXED = ['backdrop-filter', 'user-select', 'appearance', 'clip-path',
      'text-size-adjust', 'box-decoration-break', 'hyphens', 'mask-image', 'mask'];
    for (var i = 0; i < PREFIXED.length; i++) {
      var prop = PREFIXED[i];
      var re = new RegExp('(^|[;{\\s])(' + prop + '\\s*:\\s*[^;}]+)', 'g');
      out = out.replace(re, function (m, pre, decl) {
        return pre + '-webkit-' + decl + ';' + decl;
      });
    }

    // :has() — Safari 12 не понимает селектор, правило выкидываем
    out = out.replace(/[^{}]*:has\([^{}]*\)\s*\{[^{}]*\}/g, '');

    return out;
  }

  function oklchToHex(inner) {
    try {
      var parts = inner.replace(/\//g, ' / ').trim().split(/\s+/);
      var L = parseFloat(parts[0]);
      var C = parseFloat(parts[1]);
      var H = parseFloat(parts[2]);
      if (isNaN(L) || isNaN(C) || isNaN(H)) { return null; }
      var h = H * Math.PI / 180;
      var a = C * Math.cos(h);
      var b = C * Math.sin(h);
      var l_ = L + 0.3963377774 * a + 0.2158037573 * b;
      var m_ = L - 0.1055613458 * a - 0.0638541728 * b;
      var s_ = L - 0.0894841775 * a - 1.2914855480 * b;
      var l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
      var r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
      var g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
      var bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
      function toSRGB(x) {
        x = Math.max(0, Math.min(1, x));
        return Math.round(255 * (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055));
      }
      var hex = '#' + [toSRGB(r), toSRGB(g), toSRGB(bl)].map(function (v) {
        var t = v.toString(16);
        return t.length === 1 ? '0' + t : t;
      }).join('');
      return hex;
    } catch (e) { return null; }
  }

  /* ---------------------------------------------------------------- HTML ---- */

  var HEAD_INJECT =
    '<script src="/__legacy/polyfills.js"></script>\n' +
    '<script src="/__legacy/core-js-bundle.js"></script>\n' +
    '<script src="/__legacy/legacy.js"></script>\n' +
    '<link rel="stylesheet" href="/__legacy/compat.css">\n';

  // Маркер: загрузчик в приложении по нему понимает, что страницу уже
  // подготовили (и что полифилы лежат рядом).
  var CLIENT_MARKER = '<!--pc-client-->\n';

  var JS_TYPES = /^(|text\/javascript|application\/javascript|application\/x-javascript|module|text\/ecmascript|application\/ecmascript)$/i;

  /**
   * @param {string} html
   * @param {{transformInline?:boolean}} opts
   * @returns {string}
   */
  function transformHTML(html, opts) {
    opts = opts || {};
    if (!html) { return ''; }
    var out = html;

    // CSP meta ломает наши вставки
    out = out.replace(/<meta[^>]+http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>/gi, '');

    if (opts.transformInline !== false) {
      out = out.replace(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi, function (m, attrs, body) {
        if (/\bsrc\s*=/i.test(attrs)) { return m; }
        var typeM = /\btype\s*=\s*["']?([^"'\s>]+)/i.exec(attrs);
        var type = typeM ? typeM[1] : '';
        if (!JS_TYPES.test(type)) { return m; }
        if (!body || !NEEDS_TRANSPILE.test(body)) { return m; }
        var isModule = /^module$/i.test(type);
        var res = transformJS(body, { sourceType: isModule ? 'module' : 'script' });
        if (!res.ok) { return m; }
        return '<script' + attrs + '>' + res.code + '</script>';
      });
    }

    // iOS-клиент: <base> для схемы wk:// — относительные пути остаются в прокси.
    if (opts.baseHref) {
      var baseTag = '<base href="' + String(opts.baseHref).replace(/"/g, '&quot;') + '">';
      if (/<head\b[^>]*>/i.test(out)) {
        out = out.replace(/<head\b[^>]*>/i, function (m) { return m + baseTag; });
      } else {
        out = baseTag + out;
      }
    }

    // iOS-клиент: маркер для загрузчика полифилов в WKUserScript.
    if (opts.clientMarker) {
      out = out.replace(/<head\b[^>]*>/i, function (m) { return m + CLIENT_MARKER; });
    }

    // AI Chat и Image Gen в меню bridge.html (когда загружается сам прокси-интерфейс)
    if (html.indexOf('perchance-client-bridge') !== -1) {
       var menuInject = '<div class="menu-item" onclick="window.open(\'/ai-chat\')"><span class="menu-item-icon">💬</span><span class="menu-item-label">AI Chat</span></div>' +
                        '<div class="menu-item" onclick="window.open(\'/ai-image-generator\')"><span class="menu-item-icon">🎨</span><span class="menu-item-label">Image Gen</span></div>';
       out = out.replace('<!--pc-menu-extra-->', menuInject);
    }

    // Инъекция кнопок в меню Perchance
    out = out.replace(/(<div[^>]+data-mi="new"[^>]*>[\s\S]*?<\/div>)/i, '$1' + 
      '<div class="menu-item" onclick="window.open(\'/ai-chat\')" style="padding:0 6px"><span class="menu-item-icon">💬</span><span class="menu-item-label">AI Chat</span></div>' +
      '<div class="menu-item" onclick="window.open(\'/ai-image-generator\')" style="padding:0 6px"><span class="menu-item-icon">🎨</span><span class="menu-item-label">Image Gen</span></div>');

    // Вставляем полифилы первыми
    if (/<head\b[^>]*>/i.test(out)) {
      out = out.replace(/<head\b[^>]*>/i, function (m) { return m + HEAD_INJECT; });
    } else if (/<html\b[^>]*>/i.test(out)) {
      out = out.replace(/<html\b[^>]*>/i, function (m) {
        return m + '<head>' + HEAD_INJECT + '</head>';
      });
    } else {
      out = HEAD_INJECT + out;
    }

    if (opts.scheme) { out = rewriteScheme(out, opts.scheme); }
    return out;
  }

  /* -------------------------------------------------------------- экспорт --- */

  global.PCTransform = {
    VERSION: VERSION,
    transformJS: transformJS,
    transformHTML: transformHTML,
    patchCSS: patchCSS,
    needsTranspile: function (code) { return NEEDS_TRANSPILE.test(code); }
  };
}(typeof window !== 'undefined' ? window : this));
