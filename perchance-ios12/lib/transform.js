/* ============================================================================
 * transform.js — переписывание JS/CSS «на лету» под Safari 12 / iOS 12
 * ----------------------------------------------------------------------------
 * Используется локальная копия @babel/standalone (lib/babel.min.js),
 * поэтому сервер работает без интернета и без npm install.
 * ========================================================================== */

'use strict';

const fs = require('fs');
const path = require('path');

const BABEL_PATH = path.join(__dirname, 'babel.min.js');
let Babel = null;

function getBabel() {
  if (Babel) { return Babel; }
  if (!fs.existsSync(BABEL_PATH)) {
    throw new Error('Не найден lib/babel.min.js — переустанови проект (см. README).');
  }
  // babel.min.js знает, что делать и вне браузера (UMD).
  Babel = require(BABEL_PATH);
  return Babel;
}

const TARGETS = { safari: '12' };

/** Кеш результатов: повторная транспиляция одних и тех же файлов не нужна. */
const cache = new Map();
const CACHE_LIMIT = 400;

// Дисковый кеш — чтобы после перезапуска сервера не ждать Babel заново.
const fsCache = require('fs');
const pathCache = require('path');
const cryptoCache = require('crypto');
const DISK_DIR = pathCache.join(__dirname, '..', 'cache');
try { fsCache.mkdirSync(DISK_DIR, { recursive: true }); } catch (e) {}

function diskKey(kind, code) {
  return kind + '-' + cryptoCache.createHash('sha1').update(code).digest('hex').slice(0, 24);
}

function diskGet(kind, code) {
  try {
    const p = pathCache.join(DISK_DIR, diskKey(kind, code) + '.js');
    if (!fsCache.existsSync(p)) { return null; }
    return fsCache.readFileSync(p, 'utf8');
  } catch (e) { return null; }
}

function diskSet(kind, code, value) {
  try {
    fsCache.writeFileSync(pathCache.join(DISK_DIR, diskKey(kind, code) + '.js'), value);
  } catch (e) {}
}

function transformJS(code, opts) {
  const options = opts || {};
  const sourceType = options.sourceType === 'module' ? 'module' : 'script';
  const key = sourceType + '\u0000' + code.length + '\u0000' + hash(code);
  if (cache.has(key)) { return cache.get(key); }

  const cachedOnDisk = diskGet('js-' + sourceType, code);
  if (cachedOnDisk) {
    const r = { ok: true, code: cachedOnDisk, cached: true };
    if (cache.size > CACHE_LIMIT) { cache.clear(); }
    cache.set(key, r);
    return r;
  }

  const babel = getBabel();
  const presets = [
    [
      'env',
      {
        targets: TARGETS,
        modules: false,
        bugfixes: true,
        loose: true,
        // Не раздуваем промисами то, что и так есть.
        useBuiltIns: false
      }
    ]
  ];

  let result;
  try {
    const out = babel.transform(code, {
      presets,
      sourceType,
      compact: false,
      retainLines: false,
      babelrc: false,
      configFile: false,
      comments: true,
      // Некоторые страницы Perchance содержат «экзотические» фичи, из-за которых
      // Babel может ругаться на parseErrorCallback — обработаем ниже по коду.
      parserOpts: {
        allowReturnOutsideFunction: true,
        allowAwaitOutsideFunction: true,
        allowSuperOutsideMethod: true,
        allowUndeclaredExports: true
      }
    });
    result = { ok: true, code: out.code };
  } catch (err) {
    // Не разбирается — отдаём код без изменений, но вырезанный из `/* */`-строки
    result = {
      ok: false,
      code: code,
      error: String(err && err.message ? err.message : err)
    };
    try {
      console.warn('[transform] Babel не смог разобрать код: ' + result.error.slice(0, 200));
    } catch (e) {}
  }

  if (cache.size > CACHE_LIMIT) { cache.clear(); }
  cache.set(key, result);
  if (result.ok) { diskSet('js-' + sourceType, code, result.code); }
  return result;
}

function hash(str) {
  let h = 5381;
  for (let i = 0; i < str.length; i++) {
    h = ((h << 5) + h + str.charCodeAt(i)) | 0;
  }
  return h >>> 0;
}

/* ---------------------------------------------------------------------- CSS */
// Селекторы вроде `:root` и `body` Safari 12 понимает, поэтому основная задача —
// фолбэки для новых свойств и значений. Патчим точечно, не трогая остальное.
function patchCSS(css) {
  const cached = diskGet('css', css);
  if (cached) { return cached; }
  let out = css;

  // `inset: 0` / `inset: 10px 20px` → top/right/bottom/left (Safari 14.1+)
  // Сначала обрабатываем простейший и самый частый случай `inset: <1 значение>`.
  out = out.replace(/(^|[;{]\s*)inset\s*:\s*([^;}{]+);/g, (m, pre, val) => {
    const parts = val.trim().split(/\s+/);
    const map = [];
    const t = parts[0];
    const r = parts[1] !== undefined ? parts[1] : t;
    const b = parts[2] !== undefined ? parts[2] : t;
    const l = parts[3] !== undefined ? parts[3] : r;
    map.push(`top: ${t}`, `right: ${r}`, `bottom: ${b}`, `left: ${l}`);
    return `${pre}${map.join('; ')}; ${pre}inset: ${val};`;
  });
  // тот же inset, но последней декларацией в блоке (перед `}`)
  out = out.replace(/(^|[;{]\s*)inset\s*:\s*([^;}{]+)(?=\s*\})/g, (m, pre, val) => {
    const parts = val.trim().split(/\s+/);
    const t = parts[0];
    const r = parts[1] !== undefined ? parts[1] : t;
    const b = parts[2] !== undefined ? parts[2] : t;
    const l = parts[3] !== undefined ? parts[3] : r;
    return `${pre}top: ${t}; right: ${r}; bottom: ${b}; left: ${l}; inset: ${val.trim()}`;
  });

  // `inset-inline-start` и родственники (RTL-логические свойства, Safari 14.1+)
  out = out.replace(/(^|[;{]\s*)inset-inline-start\s*:\s*([^;}{]+);/g, '$1left: $2;');
  out = out.replace(/(^|[;{]\s*)inset-inline-end\s*:\s*([^;}{]+);/g, '$1right: $2;');
  out = out.replace(/(^|[;{]\s*)inset-block-start\s*:\s*([^;}{]+);/g, '$1top: $2;');
  out = out.replace(/(^|[;{]\s*)inset-block-end\s*:\s*([^;}{]+);/g, '$1bottom: $2;');
  out = out.replace(/(^|[;{]\s*)inset-inline\s*:\s*([^;}{]+);/g, '$1left: $2; right: $2;');
  out = out.replace(/(^|[;{]\s*)inset-block\s*:\s*([^;}{]+);/g, '$1top: $2; bottom: $2;');

  // `margin-inline: a b` / `padding-block` (Safari 14.1+)
  out = out.replace(/(^|[;{]\s*)(margin|padding)-inline\s*:\s*([^;}{]+);/g, (m, pre, prop, val) => {
    const p = val.trim().split(/\s+/);
    const a = p[0];
    const b = p[1] !== undefined ? p[1] : a;
    return `${pre}${prop}-left: ${a}; ${prop}-right: ${b};`;
  });
  out = out.replace(/(^|[;{]\s*)(margin|padding)-block\s*:\s*([^;}{]+);/g, (m, pre, prop, val) => {
    const p = val.trim().split(/\s+/);
    const a = p[0];
    const b = p[1] !== undefined ? p[1] : a;
    return `${pre}${prop}-top: ${a}; ${prop}-bottom: ${b};`;
  });

  // `aspect-ratio: 1 / 1` (Safari 15+) — Safari 12 не умеет вообще.
  // Оставляем "мягкий" фолбэк: минимальная высота по ширине через padding-top
  // не выставляется (ломает layout), поэтому просто фиксируем соотношение
  // через --legacy-aspect-ratio, а JS-шим (legacy.js) раздувает меню-кнопки.
  out = out.replace(/(^|[;{]\s*)aspect-ratio\s*:\s*([^{};]+);/g,
    (m, pre, val) => `${pre}--legacy-aspect-ratio: ${val.trim()};`);
  out = out.replace(/(^|[;{]\s*)aspect-ratio\s*:\s*([^;}{]+)(?=\s*\})/g,
    (m, pre, val) => `${pre}--legacy-aspect-ratio: ${val.trim()}`);

  // `gap: X` в grid/flex (Safari 14.1+ для flex, 10.1 для grid) — оставляем,
  // но дублируем через `grid-gap` (Safari 10.1+ понимает).
  out = out.replace(/(^|[;{]\s*)gap\s*:\s*([^;}{]+);/g, '$1grid-gap: $2; $1gap: $2;');
  out = out.replace(/(^|[;{]\s*)row-gap\s*:\s*([^;}{]+);/g, '$1grid-row-gap: $2; $1row-gap: $2;');
  out = out.replace(/(^|[;{]\s*)column-gap\s*:\s*([^;}{]+);/g, '$1grid-column-gap: $2; $1column-gap: $2;');

  // `light-dark(a, b)` (Safari 17.5+) → сначала тёмная, затем светлая через media
  // Простая стратегия: светлая версия по умолчанию, тёмная — в @media (уже в hex).
  out = out.replace(/light-dark\(\s*([^,()]+)\s*,\s*([^()]+)\)/g, '$1');

  // `oklch()`, `lab()`, `lch()` — Safari 12 не умеет. Делаем фолбэк через srgb().
  // (Если конвертация невозможна, оставляем цвет как есть.)
  out = out.replace(/\boklch\(([^)]*)\)/gi, (m, inner) => oklchFallback(inner) || m);

  // `color-mix()` — просто берём первый цвет как фолбэк
  out = out.replace(/color-mix\([^)]*,\s*([^,()]+)[^)]*\)/gi, (m, first) => first.trim());

  // :has() (Safari 15.4+) — убираем такие правила: лучше без стиля, чем сломанный парсинг
  out = out.replace(/[^{}]*:has\([^{}]*\)\s*\{[^{}]*\}/g, '');

  // `@supports (color: light-dark(...))` — Safari 12 вернёт false, это ок.
  diskSet('css', css, out);
  return out;
}

/** Приблизительная конвертация oklch в hex (нужно лишь для оттенков Perchance). */
function oklchFallback(inner) {
  try {
    const parts = inner.replace(/\//g, ' / ').trim().split(/\s+/);
    const L = parseFloat(parts[0]);
    const C = parseFloat(parts[1]);
    const H = parseFloat(parts[2]);
    if (isNaN(L) || isNaN(C) || isNaN(H)) { return null; }
    const h = (H * Math.PI) / 180;
    const a = C * Math.cos(h);
    const b = C * Math.sin(h);
    const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
    const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
    let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
    const toSRGB = (x) => {
      x = Math.max(0, Math.min(1, x));
      return Math.round(255 * (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055));
    };
    return '#' + [toSRGB(r), toSRGB(g), toSRGB(bl)]
      .map((v) => v.toString(16).padStart(2, '0')).join('');
  } catch (e) {
    return null;
  }
}

module.exports = { transformJS, patchCSS, getBabel };
