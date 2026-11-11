/* ============================================================================
 * legacy.js — runtime-заплатки для iOS 12 (вставляется ПОСЛЕ полифилов)
 * ----------------------------------------------------------------------------
 * Что делает:
 *  - добивает CSS-фолбэки, которые нельзя сделать статически (aspect-ratio
 *    у кнопок меню, flex gap);
 *  - чинит `100vh` на iPhone (адресная строка);
 *  - защищает от падений `event.source` / `origin` в cross-origin postMessage
 *    (Safari 12 не отдаёт их так же, как новые браузеры);
 *  - даёт маленький индикатор версии в уголке (можно скрыть: ?lp_debug=0).
 * ========================================================================== */
(function () {
  'use strict';
  var W = window, D = document;
  if (W.__legacyPortalRuntime) { return; }
  W.__legacyPortalRuntime = true;

  var params = new URLSearchParams(W.location.search);

  /* ---------------------------------------------- 1. правильные 100vh / 100% */
  function setVH() {
    var h = W.innerHeight;
    D.documentElement.style.setProperty('--legacy-vh', h + 'px');
    // Перебиваем популярный трюк с 100vh у оболочки Perchance
    var barH = getComputedStyle(D.documentElement).getPropertyValue('--menu-bar-height').trim() || '26px';
    W.__legacyVH = h;
    return barH;
  }
  setVH();
  W.addEventListener('resize', setVH);
  W.addEventListener('orientationchange', function () { W.setTimeout(setVH, 250); });

  /* --------------------------------- 2. aspect-ratio для кнопок меню (`1 / 1`) */
  function fixAspectRatios() {
    var els = D.querySelectorAll('[style*="aspect-ratio"], [data-mi]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var raw = el.style.getPropertyValue('--legacy-aspect-ratio') || '';
      if (!raw) { continue; }
      var parts = raw.split('/');
      var rw = parseFloat(parts[0]);
      var rh = parts[1] ? parseFloat(parts[1]) : 1;
      if (!rw || !rh) { continue; }
      var h = el.offsetHeight || parseFloat(getComputedStyle(el).height);
      if (!h) { continue; }
      el.style.minWidth = Math.round(h * (rw / rh)) + 'px';
      el.style.width = Math.round(h * (rw / rh)) + 'px';
      el.removeAttribute('data-lp-aspect');
    }
  }
  W.addEventListener('load', fixAspectRatios);
  W.addEventListener('resize', function () { W.setTimeout(fixAspectRatios, 60); });
  D.addEventListener('DOMContentLoaded', function () {
    fixAspectRatios();
    // Наблюдаем за появлением меню после загрузки интерфейса
    if (W.MutationObserver) {
      var mo = new W.MutationObserver(function () { fixAspectRatios(); });
      mo.observe(D.body, { childList: true, subtree: true });
      W.setTimeout(function () { mo.disconnect(); }, 15000);
    }
  });

  /* --------------------------- 3. flex `gap` в меню (Safari 12 игнорирует gap) */
  function fixFlexGap() {
    if (W.CSS && W.CSS.supports && W.CSS.supports('gap', '1px')) { return; }
    var rows = D.querySelectorAll('div[style*="display:flex"], div[style*="display: flex"]');
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var gap = parseFloat(getComputedStyle(row).gap || getComputedStyle(row).columnGap) || 0;
      if (!gap) {
        // Perchance задаёт gap:0.21rem инлайн — достаём из атрибута
        var m = /gap\s*:\s*([0-9.]+)(rem|px)/.exec(row.getAttribute('style') || '');
        if (!m) { continue; }
        gap = parseFloat(m[1]) * (m[2] === 'rem' ? (parseFloat(getComputedStyle(D.documentElement).fontSize) || 16) : 1);
      }
      var kids = row.children;
      for (var k = 1; k < kids.length; k++) {
        kids[k].style.marginLeft = (parseFloat(kids[k].style.marginLeft) || 0) + gap + 'px';
      }
    }
  }
  W.addEventListener('load', function () { W.setTimeout(fixFlexGap, 300); });

  /* -------------------------------------- 4. безопасный postMessage-origin */
  // В Safari 12 `event.source` для cross-origin окна может быть null в момент
  // проверки, а сам код Perchance делает `e.origin || e.originalEvent.origin`.
  // Ничего не подменяем — только логируем, если пришли «подозрительные» данные.
  function isPcOrigin(origin) {
    return typeof origin === 'string' && /^https:\/\/([a-z0-9-]+\.)?perchance\.org$/.test(origin);
  }
  if (params.get('lp_trace') === '1') {
    W.addEventListener('message', function (e) {
      if (!e.data || typeof e.data !== 'object') { return; }
      if (!isPcOrigin(e.origin)) { return; }
      try {
        console.debug('[legacy-portal] ←', e.data.type, e.origin);
      } catch (err) {}
    });
  }

  /* ------------------------------- 5. iframe генератора: разрешаем fullscreen */
  // Safari 12 не знает `allow="..."` с новыми политиками — просто не мешаем.

  /* ------------------------------------ 6. шрифты: ускоряем/чиним подключение */
  // В Safari 12 есть баг с `font-display` в @font-face для css-fonts.
  // Ничего не ломаем: если `Cousine` не загрузилась, даём monospace-фолбэк.
  D.addEventListener('DOMContentLoaded', function () {
    var st = D.createElement('style');
    st.textContent = 'body,.menu-item,#console-input{font-family:Cousine,Menlo,Consolas,monospace !important;}';
    D.head.appendChild(st);
  });

  /* -------------------------------------- 7. видимый индикатор (для отладки) */
  if (params.get('lp_debug') !== '0') {
    D.addEventListener('DOMContentLoaded', function () {
      var badge = D.createElement('div');
      badge.id = 'legacyPortalBadge';
      badge.title = 'Транспилировано для iOS 12. Нажми, чтобы скрыть.';
      badge.textContent = 'iOS12';
      badge.style.cssText = [
        'position:fixed', 'left:2px', 'bottom:2px', 'z-index:2147483647',
        'font:10px/14px Menlo,monospace', 'padding:0 4px', 'border-radius:3px',
        'background:#2b6cb0', 'color:#fff', 'opacity:.55', 'cursor:pointer',
        'user-select:none', 'pointer-events:auto'
      ].join(';');
      badge.addEventListener('click', function () { badge.style.display = 'none'; });
      D.body.appendChild(badge);
    });
  }

  /* ------------------- 8. wk:// → https:// для проверок origin ------------- */
  // Приложение отдаёт страницы по схеме wk://, а Perchance сравнивает origin
  // с https://<id>.perchance.org. Нормализуем «на лету», иначе обработчики
  // postMessage между страницей и iframe генератора молча отбрасываются.
  (function () {
    function asHttps(v) {
      if (typeof v !== 'string') { return v; }
      return v.replace(/^wk:\/\//, 'https://');
    }
    try {
      var d = Object.getOwnPropertyDescriptor(W.MessageEvent.prototype, 'origin');
      if (d && d.get) {
        Object.defineProperty(W.MessageEvent.prototype, 'origin', {
          configurable: true,
          enumerable: d.enumerable,
          get: function () { return asHttps(d.get.call(this)); }
        });
      }
    } catch (e) {}
    try {
      var L = W.Location && W.Location.prototype;
      var dl = L && Object.getOwnPropertyDescriptor(L, 'origin');
      if (dl && dl.get) {
        Object.defineProperty(L, 'origin', {
          configurable: true,
          enumerable: dl.enumerable,
          get: function () { return asHttps(dl.get.call(this)); }
        });
      }
    } catch (e) {}
    try {
      var origPost = W.postMessage;
      W.postMessage = function (message, targetOrigin, transfer) {
        var target = targetOrigin;
        if (typeof target === 'string' &&
            /^https:\/\/[a-z0-9.-]*perchance\.org$/i.test(target)) {
          target = 'wk://' + target.slice('https://'.length);
        }
        return origPost.call(W, message, target, transfer);
      };
    } catch (e) {}
  }());

  try {
    console.info('[legacy-portal] runtime loaded');
  } catch (e) {}
}());
