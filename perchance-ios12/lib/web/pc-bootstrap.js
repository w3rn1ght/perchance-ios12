/* ============================================================================
 * pc-bootstrap.js — загрузчик полифилов для схемы wk:// (iOS-приложение)
 * ----------------------------------------------------------------------------
 * Проблема: страница Perchance сама вставляет <script src="/lib/appExtras.js">.
 * Скрипт с понимаемым MIME выполнится сразу — и Safari 12 упадёт на `?.`.
 *
 * А WKURLSchemeHandler в iOS 12 не отдаёт нам заголовки ответа для <script>,
 * поэтому «спрятать» JS за неизвестным MIME нельзя.
 *
 * Решение — синхронная заглушка: на время загрузки полифилов мы подменяем
 * document.createElement('script') и HTMLScriptElement.prototype.src.
 * Тег получает `type="x-pc-pending"`, который браузер не исполняет; адрес
 * при этом копируется в data-pc-src. Когда полифилы готовы, мы возвращаем
 * настоящее `type` и `src` — скрипты выполняются по порядку.
 *
 * Файл вставляется через WKUserScript(atDocumentStart, allFrames),
 * т.е. асинхронно и до DOMContentLoaded — но этот зазор безопасен: настоящая
 * страница — наше HTML, а скрипты в нём статически получают
 * x-pc-pending от HTML-транспилятора.
 * ========================================================================== */
(function () {
  'use strict';
  if (window.__pcBootstrap) { return; }
  window.__pcBootstrap = true;

  var PENDING = 'x-pc-pending';
  var JS_TEXT = 'text/javascript';
  var POLY_TYPE = 'x-pc-polyfills';
  var deferred = [];
  var polyLoaded = false;
  var ready = false;

  /* ---------------------------------------------- 1. перехват создания тегов */

  var origCreate = document.createElement;
  document.createElement = function (tagName) {
    var el = origCreate.apply(document, arguments);
    if (String(tagName).toLowerCase() === 'script') { hide(el); }
    return el;
  };

  function hide(el) {
    try {
      var desc = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
      if (!desc || !desc.set) { return; }
      Object.defineProperty(el, 'src', {
        configurable: true,
        enumerable: true,
        get: function () { return this.__pcSrc || ''; },
        set: function (v) {
          this.__pcSrc = v;
          this.setAttribute('data-pc-src', v);
          if (!this.__pcHidden) {
            this.__pcHidden = true;
            this.setAttribute('type', PENDING);
          }
        }
      });
    } catch (e) { /* оставляем как есть */ }
  }

  function reveal(el) {
    var src = el.getAttribute('data-pc-src');
    var type = el.getAttribute('type');
    if (type !== PENDING) { return; }
    el.removeAttribute('type');
    el.setAttribute('type', JS_TEXT);
    if (src) { el.setAttribute('src', src); }
  }

  /* ------------------------------ 2. страховка: ловим теги, прошедшие мимо */

  if (window.MutationObserver && document.documentElement) {
    var mo = new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        var nodes = muts[i].addedNodes;
        for (var j = 0; j < nodes.length; j++) {
          var n = nodes[j];
          if (n.nodeName === 'SCRIPT' && n.getAttribute('type') !== POLY_TYPE && !ready) {
            deferred.push(n);
          }
        }
      }
    });
    mo.observe(document.documentElement, { childList: true, subtree: true });
  }

  /* --------------------------------------------- 3. полифилы, затем релиз */

  function loadPolyfills(done) {
    var files = ['/__legacy/core-js-bundle.js', '/__legacy/polyfills.js', '/__legacy/legacy.js'];
    var left = files.length;
    files.forEach(function (file, idx) {
      var s = origCreate.call(document, 'script');
      if (idx === 0) { s.setAttribute('type', POLY_TYPE); }
      s.async = false;
      s.src = file;
      s.onload = s.onerror = function () {
        if (--left === 0) { done(); }
      };
      (document.head || document.documentElement).appendChild(s);
    });
  }

  function releaseAll() {
    ready = true;
    polyLoaded = true;

    // 1) статические теги в HTML
    var staticScripts = document.querySelectorAll('script[type="' + PENDING + '"]');
    for (var i = 0; i < staticScripts.length; i++) { reveal(staticScripts[i]); }

    // 2) динамические
    var list = deferred;
    deferred = [];
    for (var k = 0; k < list.length; k++) { reveal(list[k]); }

    window.__pcReady = true;

    // 3) снимаем перехват — дальше страница живёт как обычно
    document.createElement = origCreate;
    var made = document.querySelectorAll('script[data-pc-src][type="' + PENDING + '"]');
    for (var m = 0; m < made.length; m++) { reveal(made[m]); }
  }

  function boot() {
    if (polyLoaded) { return; }
    polyLoaded = true;
    loadPolyfills(releaseAll);
  }

  loadPolyfills(releaseAll);
}());
