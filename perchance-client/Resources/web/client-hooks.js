(function () {
  'use strict';
  /**
   * Логика обработчика wk://, вынесенная из нативного кода.
   * Вызывается из bridge.html (через PCTransform) и отдаёт то, что нужно
   * приложению: HTML, CSS, JS — уже переписанными.
   *
   * Обёртка оставляет место для специфики клиента:
   *  - маркер «страница подготовлена» (clientMarker);
   *  - отключение inline-транспиляции при необходимости.
   */
  window.PCTransformClient = {
    /** Обработка HTML-ответа. */
    html: function (html) {
      return PCTransform.transformHTML(html, { clientMarker: true });
    },
    /** Обработка JS-ответа. */
    js: function (code, filename) {
      return PCTransform.transformJS(code, { filename: filename, force: true });
    },
    /** Обработка CSS-ответа. */
    css: function (code) {
      return PCTransform.patchCSS(code);
    },
    version: function () {
      return PCTransform.VERSION + (window.Babel ? ' (Babel ' + window.Babel.version + ')' : '');
    }
  };
}());
