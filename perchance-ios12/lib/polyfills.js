/* ============================================================================
 * Perchance Legacy Portal — polyfills for iOS 12 / Safari 12
 * ----------------------------------------------------------------------------
 * Этот файл вставляется ПЕРВЫМ на каждую страницу perchance.org.
 * Синтаксис: строгий ES5 (var/function) — иначе Safari 12 сам его не разберёт.
 *
 * Здесь только то, чего реально нет в Safari 12 (iOS 12):
 *   Safari 12 = ES2018, без optional chaining, без class fields,
 *   без ResizeObserver, без AbortSignal.timeout, без Promise.allSettled и т.д.
 *
 * Синтаксис (?., ??, #private) полифилами НЕ лечится — это делает Babel
 * на сервере (lib/transform.js).
 * ========================================================================== */
(function () {
  'use strict';

  var W = window;
  if (W.__legacyPortalPolyfills) { return; }
  W.__legacyPortalPolyfills = { version: '1.0.0', at: Date.now() };

  var D = document;

  /* ---------------------------------------------------------------- helpers */
  function define(obj, name, value) {
    if (!obj) { return; }
    try {
      if (name in obj) { return; }
      Object.defineProperty(obj, name, {
        value: value, writable: true, configurable: true, enumerable: false
      });
    } catch (e) { /* read-only prototype — пропускаем */ }
  }
  function defineForce(obj, name, value) {
    if (!obj) { return; }
    try {
      Object.defineProperty(obj, name, {
        value: value, writable: true, configurable: true, enumerable: false
      });
    } catch (e) {}
  }
  function isFn(x) { return typeof x === 'function'; }

  /* --------------------------------------------------------------- globalThis */
  define(W, 'globalThis', W);
  if (typeof globalThis === 'undefined') { W.globalThis = W; }

  /* ------------------------------------------------------------------ Object */
  define(Object, 'fromEntries', function fromEntries(entries) {
    var o = {};
    if (!entries) { return o; }
    var list = entries;
    if (typeof list[Symbol.iterator] === 'function') { list = Array.from(list); }
    for (var i = 0; i < list.length; i++) {
      var pair = list[i];
      o[pair[0]] = pair[1];
    }
    return o;
  });

  define(Object, 'hasOwn', function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(Object(obj), key);
  });

  define(Object, 'groupBy', function groupBy(items, cb) {
    var out = {};
    for (var i = 0; i < items.length; i++) {
      var k = isFn(cb) ? cb(items[i], i) : items[i][cb];
      if (!Object.prototype.hasOwnProperty.call(out, k)) { out[k] = []; }
      out[k].push(items[i]);
    }
    return out;
  });

  /* ------------------------------------------------------------------- Array */
  define(Array.prototype, 'at', function at(n) {
    var len = this.length >>> 0;
    n = Math.trunc(n) || 0;
    if (n < 0) { n += len; }
    return (n < 0 || n >= len) ? undefined : this[n];
  });

  define(Array.prototype, 'flat', function flat(depth) {
    var d = depth === undefined ? 1 : Math.trunc(depth);
    var out = [];
    (function walk(arr, level) {
      for (var i = 0; i < arr.length; i++) {
        if (Array.isArray(arr[i]) && level > 0) { walk(arr[i], level - 1); }
        else { out.push(arr[i]); }
      }
    })(this, d === Infinity ? 1e9 : d);
    return out;
  });

  define(Array.prototype, 'flatMap', function flatMap(cb, thisArg) {
    return this.map(cb, thisArg).flat(1);
  });

  define(Array.prototype, 'findLast', function findLast(cb, thisArg) {
    for (var i = this.length - 1; i >= 0; i--) {
      if (cb.call(thisArg, this[i], i, this)) { return this[i]; }
    }
    return undefined;
  });

  define(Array.prototype, 'findLastIndex', function findLastIndex(cb, thisArg) {
    for (var i = this.length - 1; i >= 0; i--) {
      if (cb.call(thisArg, this[i], i, this)) { return i; }
    }
    return -1;
  });

  define(Array.prototype, 'toSorted', function toSorted(cmp) { return this.slice().sort(cmp); });
  define(Array.prototype, 'toReversed', function toReversed() { return this.slice().reverse(); });
  define(Array.prototype, 'toSpliced', function toSpliced() {
    var a = this.slice();
    a.splice.apply(a, arguments);
    return a;
  });
  define(Array.prototype, 'with', function with_(idx, value) {
    var a = this.slice();
    var i = idx < 0 ? a.length + idx : idx;
    a[i] = value;
    return a;
  });
  define(Array.prototype, 'group', function group(cb) { return Object.groupBy(this, cb); });
  define(Array, 'fromAsync', function fromAsync(iterable, mapFn) {
    return Promise.resolve().then(function () {
      return Array.from(iterable, mapFn);
    });
  });

  /* ------------------------------------------------------------------ String */
  define(String.prototype, 'replaceAll', function replaceAll(search, replacement) {
    if (search instanceof RegExp) {
      if (!search.global) { throw new TypeError('replaceAll must be called with a global RegExp'); }
      return this.replace(search, replacement);
    }
    var s = String(this);
    var find = String(search);
    if (find === '') {
      // по спеке вставляем между всеми символами
      var chars = s.split('');
      var rep = isFn(replacement) ? replacement : function () { return String(replacement); };
      var res = '';
      for (var i = 0; i <= chars.length; i++) {
        res += rep('', i) + (chars[i] === undefined ? '' : chars[i]);
      }
      return res;
    }
    return s.split(find).join(isFn(replacement) ? replacement(find) : String(replacement));
  });

  define(String.prototype, 'matchAll', function matchAll(re) {
    var s = String(this);
    var g = new RegExp(re.source, re.flags.indexOf('g') >= 0 ? re.flags : re.flags + 'g');
    var out = [];
    var m;
    g.lastIndex = 0;
    while ((m = g.exec(s)) !== null) {
      out.push(m);
      if (m[0] === '') { g.lastIndex++; }
    }
    return out;
  });

  define(String.prototype, 'at', function at(n) {
    return String(this).charAt(n < 0 ? this.length + n : n) || undefined;
  });
  define(String.prototype, 'isWellFormed', function isWellFormed() { return true; });
  define(String.prototype, 'toWellFormed', function toWellFormed() { return String(this); });

  /* ----------------------------------------------------------------- Promise */
  define(Promise, 'allSettled', function allSettled(iterable) {
    return Promise.all(Array.from(iterable).map(function (p) {
      return Promise.resolve(p).then(
        function (value) { return { status: 'fulfilled', value: value }; },
        function (reason) { return { status: 'rejected', reason: reason }; }
      );
    }));
  });

  define(Promise, 'any', function any(iterable) {
    return new Promise(function (resolve, reject) {
      var list = Array.from(iterable);
      var errors = [];
      var done = false;
      if (list.length === 0) {
        var e = new Error('All promises were rejected');
        e.name = 'AggregateError';
        reject(e);
        return;
      }
      list.forEach(function (p, i) {
        Promise.resolve(p).then(function (v) {
          if (!done) { done = true; resolve(v); }
        }, function (err) {
          errors[i] = err;
          if (Object.keys(errors).length === list.length && !done) {
            done = true;
            var e = new Error('All promises were rejected');
            e.name = 'AggregateError';
            e.errors = errors;
            reject(e);
          }
        });
      });
    });
  });

  define(Promise, 'withResolvers', function withResolvers() {
    var out = {};
    out.promise = new Promise(function (res, rej) {
      out.resolve = res;
      out.reject = rej;
    });
    return out;
  });

  define(Promise, 'try', function try_(fn) {
    return new Promise(function (resolve) { resolve(fn()); });
  });

  /* --------------------------------------------------------- microtask queue */
  define(W, 'queueMicrotask', function queueMicrotask(fn) {
    if (isFn(W.MutationObserver)) {
      var toggle = 1;
      var node = D.createTextNode('');
      var queue = [];
      new W.MutationObserver(function () {
        var tasks = queue.slice();
        queue.length = 0;
        for (var i = 0; i < tasks.length; i++) {
          try { tasks[i](); } catch (e) { W.setTimeout(function () { throw e; }, 0); }
        }
      }).observe(node, { characterData: true });
      return function (cb) {
        queue.push(cb);
        toggle = -toggle;
        node.data = String(toggle);
      };
    }
    return function (cb) { Promise.resolve().then(cb); };
  }());

  /* -------------------------------------------------------------- AbortSignal */
  if (!W.AbortController) {
    var AbortControllerShim = function AbortController() {
      var listeners = [];
      var signal = {
        aborted: false,
        reason: undefined,
        onabort: null,
        addEventListener: function (type, fn) {
          if (type === 'abort') { listeners.push(fn); }
        },
        removeEventListener: function (type, fn) {
          var i = listeners.indexOf(fn);
          if (i >= 0) { listeners.splice(i, 1); }
        },
        dispatchEvent: function (ev) {
          if (isFn(signal.onabort)) { signal.onabort(ev); }
          for (var i = 0; i < listeners.length; i++) { listeners[i].call(signal, ev); }
          return true;
        },
        throwIfAborted: function () {
          if (signal.aborted) { throw signal.reason; }
        }
      };
      this.signal = signal;
      this.abort = function (reason) {
        if (signal.aborted) { return; }
        signal.aborted = true;
        signal.reason = reason === undefined ? new Error('AbortError') : reason;
        signal.dispatchEvent({ type: 'abort', target: signal });
      };
    };
    W.AbortController = AbortControllerShim;
    W.AbortSignal = function AbortSignal() { throw new TypeError('Illegal constructor'); };
  }

  if (W.AbortSignal) {
    define(W.AbortSignal, 'timeout', function timeout(ms) {
      var ctrl = new W.AbortController();
      W.setTimeout(function () {
        var err = new Error('signal timed out');
        err.name = 'TimeoutError';
        ctrl.abort(err);
      }, ms);
      return ctrl.signal;
    });
    define(W.AbortSignal, 'abort', function abort(reason) {
      var ctrl = new W.AbortController();
      ctrl.abort(reason);
      return ctrl.signal;
    });
    define(W.AbortSignal, 'any', function any(signals) {
      var ctrl = new W.AbortController();
      for (var i = 0; i < signals.length; i++) {
        (function (s) {
          if (s.aborted) { ctrl.abort(s.reason); return; }
          s.addEventListener('abort', function () { ctrl.abort(s.reason); });
        })(signals[i]);
      }
      return ctrl.signal;
    });
    define(W.AbortSignal.prototype, 'throwIfAborted', function throwIfAborted() {
      if (this.aborted) { throw this.reason; }
    });
  }

  /* ---------------------------------------------------------------- Element */
  define(Element.prototype, 'replaceChildren', function replaceChildren() {
    while (this.firstChild) { this.removeChild(this.firstChild); }
    if (arguments.length) { this.append.apply(this, arguments); }
  });

  define(Element.prototype, 'checkVisibility', function checkVisibility() {
    return !!(this.offsetWidth || this.offsetHeight || this.getClientRects().length);
  });

  define(Node.prototype, 'getRootNode', function getRootNode() { return D; });

  // inert (Safari 15.5+): приблизительно
  try {
    var inertDesc = Object.getOwnPropertyDescriptor(W.HTMLElement.prototype, 'inert');
    if (!inertDesc) {
      Object.defineProperty(W.HTMLElement.prototype, 'inert', {
        configurable: true,
        get: function () { return this.hasAttribute('inert'); },
        set: function (v) {
          if (v) {
            this.setAttribute('inert', '');
            this.setAttribute('data-legacy-inert', '');
            this.style.pointerEvents = 'none';
          } else {
            this.removeAttribute('inert');
            this.removeAttribute('data-legacy-inert');
            this.style.pointerEvents = '';
          }
        }
      });
    }
  } catch (e) {}

  // HTMLCollection в Safari не итерируемый — многие циклы `for..of` падают
  try {
    if (!W.HTMLCollection.prototype[Symbol.iterator]) {
      defineForce(W.HTMLCollection.prototype, Symbol.iterator, Array.prototype.values);
    }
    if (!W.DOMTokenList.prototype[Symbol.iterator]) {
      defineForce(W.DOMTokenList.prototype, Symbol.iterator, Array.prototype.values);
    }
  } catch (e) {}

  /* ------------------------------------------------------------------ Blob/File */
  try {
    if (!W.Blob.prototype.text) {
      defineForce(W.Blob.prototype, 'text', function text() {
        var blob = this;
        return new Promise(function (resolve, reject) {
          var fr = new W.FileReader();
          fr.onload = function () { resolve(String(fr.result)); };
          fr.onerror = function () { reject(fr.error); };
          fr.readAsText(blob);
        });
      });
    }
    if (!W.Blob.prototype.arrayBuffer) {
      defineForce(W.Blob.prototype, 'arrayBuffer', function arrayBuffer() {
        var blob = this;
        return new Promise(function (resolve, reject) {
          var fr = new W.FileReader();
          fr.onload = function () { resolve(fr.result); };
          fr.onerror = function () { reject(fr.error); };
          fr.readAsArrayBuffer(blob);
        });
      });
    }
  } catch (e) {}

  /* -------------------------------------------------------------- structuredClone */
  define(W, 'structuredClone', function structuredClone(value) {
    // Упрощённая версия: хватает для plain-объектов/массивов/примитивов.
    if (value === null || typeof value !== 'object') { return value; }
    if (value instanceof Date) { return new Date(value.getTime()); }
    if (value instanceof RegExp) { return new RegExp(value.source, value.flags); }
    if (value instanceof ArrayBuffer) { return value.slice(0); }
    if (ArrayBuffer.isView(value)) { return new value.constructor(value); }
    if (Array.isArray(value)) {
      return value.map(function (v) { return W.structuredClone(v); });
    }
    var out = {};
    for (var k in value) {
      if (Object.prototype.hasOwnProperty.call(value, k)) {
        out[k] = W.structuredClone(value[k]);
      }
    }
    return out;
  });

  /* ------------------------------------------------------------------- misc API */
  define(W, 'reportError', function reportError(err) {
    W.setTimeout(function () { throw err; }, 0);
  });

  define(W, 'requestIdleCallback', function requestIdleCallback(cb, opts) {
    var start = Date.now();
    return W.setTimeout(function () {
      cb({
        didTimeout: !!(opts && opts.timeout && Date.now() - start >= opts.timeout),
        timeRemaining: function () { return 50; }
      });
    }, 1);
  });
  define(W, 'cancelIdleCallback', function cancelIdleCallback(id) { W.clearTimeout(id); });

  try {
    if (W.crypto && !W.crypto.randomUUID) {
      defineForce(W.crypto, 'randomUUID', function randomUUID() {
        var b = new Uint8Array(16);
        if (W.crypto.getRandomValues) { W.crypto.getRandomValues(b); }
        else { for (var i = 0; i < 16; i++) { b[i] = Math.floor(Math.random() * 256); } }
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        var hex = [];
        for (var j = 0; j < 16; j++) { hex.push((b[j] + 0x100).toString(16).substr(1)); }
        return hex.slice(0, 4).join('') + '-' + hex.slice(4, 6).join('') + '-' +
          hex.slice(6, 8).join('') + '-' + hex.slice(8, 10).join('') + '-' +
          hex.slice(10, 16).join('');
      });
    }
  } catch (e) {}

  /* ------------------------------------------------------- navigator.* shims */
  try {
    if (!('userActivation' in W.navigator)) {
      defineForce(W.navigator, 'userActivation', {
        isActive: true, hasBeenActive: true,
        addEventListener: function () {}, removeEventListener: function () {}
      });
    }
    if (!('connection' in W.navigator)) {
      defineForce(W.navigator, 'connection', {
        effectiveType: '4g', type: 'wifi', downlink: 10, rtt: 50,
        saveData: false, addEventListener: function () {}, removeEventListener: function () {}
      });
    }
    if (!W.navigator.sendBeacon) {
      defineForce(W.navigator, 'sendBeacon', function sendBeacon(u, data) {
        try {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', u, true);
          xhr.send(data || null);
          return true;
        } catch (e) { return false; }
      });
    }
    // Web Locks API (Safari 15.4+) — Perchance использует для статистики
    if (!W.navigator.locks) {
      var lockChains = {};
      defineForce(W.navigator, 'locks', {
        request: function (name, a, b) {
          var cb = isFn(a) ? a : b;
          var opts = isFn(a) ? {} : (a || {});
          if (opts.ifAvailable) {
            return Promise.resolve(cb ? cb({ name: name, mode: opts.mode || 'exclusive' }) : undefined);
          }
          var prev = lockChains[name] || Promise.resolve();
          var next = prev.then(function () {
            return Promise.resolve(cb ? cb({ name: name, mode: opts.mode || 'exclusive' }) : undefined);
          });
          lockChains[name] = next.catch(function () {});
          return next;
        },
        query: function () {
          return Promise.resolve({ held: [], pending: [], granted: [] });
        }
      });
    }
    if (!W.navigator.clipboard) {
      defineForce(W.navigator, 'clipboard', {
        writeText: function (t) {
          return new Promise(function (resolve, reject) {
            try {
              var ta = D.createElement('textarea');
              ta.value = t;
              ta.setAttribute('readonly', '');
              ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
              D.body.appendChild(ta);
              ta.select();
              ta.setSelectionRange(0, ta.value.length);
              var ok = D.execCommand('copy');
              D.body.removeChild(ta);
              ok ? resolve() : reject(new Error('copy failed'));
            } catch (e) { reject(e); }
          });
        },
        readText: function () { return Promise.reject(new Error('clipboard.readText unsupported')); }
      });
    }
  } catch (e) {}

  /* ------------------------------------------------------------ visualViewport */
  if (!W.visualViewport) {
    var vv = {
      width: W.innerWidth, height: W.innerHeight,
      offsetTop: 0, offsetLeft: 0, pageTop: 0, pageLeft: 0, scale: 1,
      addEventListener: function (t, fn) {
        if (t === 'resize') { W.addEventListener('resize', fn); }
        if (t === 'scroll') { W.addEventListener('scroll', fn); }
      },
      removeEventListener: function (t, fn) {
        if (t === 'resize') { W.removeEventListener('resize', fn); }
        if (t === 'scroll') { W.removeEventListener('scroll', fn); }
      }
    };
    defineForce(W, 'visualViewport', vv);
  }

  /* --------------------------------------------------------- ResizeObserver */
  if (!W.ResizeObserver) {
    var RO = function ResizeObserver(cb) {
      this._cb = cb;
      this._targets = [];
      var self = this;
      this._timer = null;
      this._schedule = function () {
        if (self._timer) { return; }
        self._timer = W.setTimeout(function () {
          self._timer = null;
          self._flush();
        }, 120);
      };
      W.addEventListener('resize', this._schedule, true);
      W.addEventListener('orientationchange', this._schedule, true);
    };
    RO.prototype._flush = function () {
      var entries = [];
      for (var i = 0; i < this._targets.length; i++) {
        var t = this._targets[i];
        var r = t.getBoundingClientRect();
        var last = t.__legacyRO || { w: -1, h: -1 };
        if (last.w !== r.width || last.h !== r.height) {
          t.__legacyRO = { w: r.width, h: r.height };
          entries.push({
            target: t,
            contentRect: r,
            borderBoxSize: [{ inlineSize: r.width, blockSize: r.height }],
            contentBoxSize: [{ inlineSize: r.width, blockSize: r.height }]
          });
        }
      }
      if (entries.length) {
        try { this._cb(entries, this); } catch (e) { W.setTimeout(function () { throw e; }, 0); }
      }
    };
    RO.prototype.observe = function (el) {
      if (this._targets.indexOf(el) >= 0) { return; }
      this._targets.push(el);
      var self = this;
      W.setTimeout(function () { self._flush(); }, 0);
    };
    RO.prototype.unobserve = function (el) {
      var i = this._targets.indexOf(el);
      if (i >= 0) { this._targets.splice(i, 1); }
    };
    RO.prototype.disconnect = function () {
      this._targets.length = 0;
      W.removeEventListener('resize', this._schedule, true);
      W.removeEventListener('orientationchange', this._schedule, true);
    };
    defineForce(W, 'ResizeObserver', RO);
  }

  /* ----------------------------------------------------- IntersectionObserver */
  if (!W.IntersectionObserver) {
    var IO = function IntersectionObserver(cb) {
      this._cb = cb;
      this._targets = [];
    };
    IO.prototype.observe = function (el) {
      this._targets.push(el);
      var self = this;
      W.setTimeout(function () {
        var r = el.getBoundingClientRect();
        var visible = r.top < W.innerHeight && r.bottom > 0;
        try {
          self._cb([{
            target: el, isIntersecting: visible, intersectionRatio: visible ? 1 : 0,
            boundingClientRect: r, intersectionRect: r,
            rootBounds: { top: 0, left: 0, right: W.innerWidth, bottom: W.innerHeight },
            time: Date.now()
          }], self);
        } catch (e) {}
      }, 0);
    };
    IO.prototype.unobserve = function (el) {
      var i = this._targets.indexOf(el);
      if (i >= 0) { this._targets.splice(i, 1); }
    };
    IO.prototype.disconnect = function () { this._targets.length = 0; };
    IO.prototype.takeRecords = function () { return []; };
    defineForce(W, 'IntersectionObserver', IO);
  }

  /* --------------------------------------------------------- WeakRef / Finalization */
  if (!W.WeakRef) {
    defineForce(W, 'WeakRef', function WeakRef(target) {
      if (!(this instanceof W.WeakRef)) { throw new TypeError('Illegal constructor'); }
      this._t = target;
    });
    W.WeakRef.prototype.deref = function () { return this._t; };
  }
  if (!W.FinalizationRegistry) {
    defineForce(W, 'FinalizationRegistry', function FinalizationRegistry() {
      this.register = function () {};
      this.unregister = function () { return false; };
    });
  }

  /* ------------------------------------------------------------------ Web Animations */
  if (!W.Element.prototype.animate) {
    defineForce(W.Element.prototype, 'animate', function animate(keyframes, options) {
      // Мини-реализация: сразу применяем конечное состояние.
      var el = this;
      var frames = Array.isArray(keyframes) ? keyframes : [keyframes];
      var last = frames[frames.length - 1] || {};
      for (var k in last) {
        if (!Object.prototype.hasOwnProperty.call(last, k)) { continue; }
        if (k === 'offset' || k === 'easing') { continue; }
        try { el.style[k] = last[k]; } catch (e) {}
      }
      var cancelled = false;
      var finished = new Promise(function (resolve) {
        W.setTimeout(function () { if (!cancelled) { resolve(); } }, 0);
      });
      return {
        finished: finished,
        cancel: function () { cancelled = true; },
        finish: function () {},
        pause: function () {},
        play: function () {},
        reverse: function () {},
        onfinish: null,
        addEventListener: function () {},
        removeEventListener: function () {},
        currentTime: 0,
        playState: 'finished'
      };
    });
  }

  /* ------------------------------------------------------------- smooth scroll */
  (function () {
    var orig = W.Element.prototype.scrollIntoView;
    defineForce(W.Element.prototype, 'scrollIntoView', function scrollIntoView(arg) {
      if (arg && typeof arg === 'object') {
        // Safari 12 не понимает объект — передаём boolean
        return orig.call(this, arg.block !== 'end' && arg.block !== 'center');
      }
      return orig.call(this, arg);
    });
  }());

  /* ------------------------------------------------------ <dialog> mini-polyfill */
  (function () {
    var proto = W.HTMLDialogElement && W.HTMLDialogElement.prototype;
    if (!proto) {
      try {
        var dlg = D.createElement('dialog');
        proto = Object.getPrototypeOf(dlg);
      } catch (e) { return; }
    }
    if (!proto || proto.showModal) { return; }
    defineForce(proto, 'show', function () {
      this.setAttribute('open', '');
    });
    defineForce(proto, 'showModal', function () {
      this.setAttribute('open', '');
      this.style.position = 'fixed';
      this.style.zIndex = '999999';
      this.style.inset = '0';
      this.style.margin = 'auto';
      this.style.background = '#fff';
      if (W.__legacyDialogBackdrop !== undefined) { return; }
      W.__legacyDialogBackdrop = true;
    });
    defineForce(proto, 'close', function (v) {
      this.removeAttribute('open');
      if (v !== undefined) { this.returnValue = v; }
      var ev = D.createEvent('Event');
      ev.initEvent('close', false, false);
      this.dispatchEvent(ev);
    });
  }());

  /* --------------------------------------------------------------- view transitions */
  define(W.document, 'startViewTransition', function startViewTransition(cb) {
    var p = Promise.resolve(isFn(cb) ? cb() : cb);
    return { ready: p, finished: p, updateCallbackDone: p, skipTransition: function () {} };
  });

  /* --------------------------------------------------------- misc small things */
  define(Number, 'parseInt', W.parseInt);
  define(Math, 'sumPrecise', function (a) { return a.reduce(function (x, y) { return x + y; }, 0); });
  define(W, 'CSS', W.CSS || { supports: function () { return false; }, escape: function (s) { return s; } });
  if (W.CSS && !W.CSS.escape) {
    defineForce(W.CSS, 'escape', function (s) {
      return String(s).replace(/[^a-zA-Z0-9_\u00A0-\uFFFF-]/g, function (c) {
        return '\\' + c;
      });
    });
  }

  /* --------------------------------------------------- отключаем Service Worker */
  // SW мог бы кешировать нетранспилированные файлы и «залипать» между версиями.
  try {
    if (W.navigator.serviceWorker) {
      W.navigator.serviceWorker.register = function () {
        return Promise.reject(new Error('service worker disabled by legacy portal'));
      };
    }
  } catch (e) {}

  /* --------------------------------------------------------- диагностика в консоль */
  try {
    console.info('[legacy-portal] polyfills for iOS 12 loaded (v' +
      W.__legacyPortalPolyfills.version + ')');
  } catch (e) {}
}());
