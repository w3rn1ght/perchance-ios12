/*
 * runtime-hooks.js — переписывает код, который Perchance компилирует в рантайме.
 *
 * Зачем: файлы сайта проходят через Babel в прокси, но текст генераторов
 * (`modelText`) и код плагинов приходят данными. Движок собирает из них
 * функцию и компилирует через `new Function` / `AsyncFunction`, а Safari 12
 * падает на первом `?.` или `??` — отсюда «(syntax error)».
 *
 * Здесь мы перехватываем все точки исполнения и прогоняем код через тот же
 * Babel. Babel (3 МБ) лежит рядом в бандле и загружается ЛЕНИВО: только когда
 * действительно встретился современный синтаксис. В обычной странице он не
 * загружается вообще.
 *
 * Дополнительно:
 *   • динамически созданные <iframe src="https://…perchance.org"> переводятся
 *     на схему wk://, иначе они грузятся мимо прокси и падают на Safari 12;
 *   • тела POST-запросов (fetch/XHR) отправляются в нативную часть, потому что
 *     WKURLSchemeTask на iOS 12 не отдаёт body — без этого не работает AI;
 *   • статистика уходит в нативную часть через messageHandlers.pcdiag.
 *
 * Файл отдаётся как есть (без транспиляции), поэтому только ES5 + async/
 * generator-функции (Safari 12 их понимает).
 */
(function (global) {
    'use strict';

    var doc = global.document;

    function mark(key, value) {
        try { localStorage.setItem(key, String(value)); } catch (e) {}
    }

    mark('pc-runtime-load', '1');

    if (!global || global.__pcRuntimeHooksInstalled) {
        mark('pc-runtime-skip', '1');
        return;
    }
    global.__pcRuntimeHooksInstalled = true;
    global.__pcRuntimeReady = true;
    mark('pc-runtime-init', '1');

    /* ------------------------------------------------------------- статистика */

    var stats = {
        load: 1,
        init: 1,
        done: 0,
        fn: 0,          // вызовов new Function с современным синтаксисом
        fnOk: 0,        // успешно переписано
        fnErr: 0,       // Babel не смог
        asyncFn: 0,
        genFn: 0,
        evalCalls: 0,
        script: 0,      // <script> через DOM
        write: 0,       // document.write
        html: 0,        // innerHTML / insertAdjacentHTML
        iframe: 0,      // переписанных iframe src
        fetchFallback: 0,
        babel: 'none',
        lastError: ''
    };

    var postTimer = null;

    function flushStats() {
        postTimer = null;
        stats.done = 1;
        mark('pc-runtime-done', '1');
        mark('pc-runtime-fn-count', stats.fn);
        mark('pc-runtime-fn-ok', stats.fnOk);
        mark('pc-runtime-eval-count', stats.evalCalls);
        mark('pc-runtime-dom-count', stats.script);
        mark('pc-runtime-write-count', stats.write);
        mark('pc-runtime-innerhtml-count', stats.html);
        mark('pc-runtime-iframe-count', stats.iframe);
        try {
            if (global.webkit && global.webkit.messageHandlers &&
                global.webkit.messageHandlers.pcdiag) {
                global.webkit.messageHandlers.pcdiag.postMessage({
                    type: 'stats',
                    href: String((global.location && global.location.href) || ''),
                    stats: stats
                });
            }
        } catch (e) {}
    }

    function scheduleStats() {
        if (postTimer !== null) {
            return;
        }
        try {
            postTimer = global.setTimeout(flushStats, 300);
        } catch (e) {
            postTimer = null;
        }
    }

    /* ---------------------------------------------------------------- Babel --- */

    var NativeFunction = global.Function;
    var nativeEval = global.eval;

    var babel = null;
    var babelTried = false;
    var transforming = false;
    var cache = [];

    var MODERN = /\?\.|\?\?|\|\|=|&&=|\?\?=|\bstatic\s*\{|#[A-Za-z_$][\w$]*\s*[=(;]|\d_\d/;

    function looksModern(code) {
        if (typeof code !== 'string' || code.length === 0) {
            return false;
        }
        if (code.length > 500000) {
            return false;
        }
        return MODERN.test(code);
    }

    function loadBabel() {
        if (babel !== null || babelTried) {
            return babel;
        }
        babelTried = true;
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/__legacy/babel.min.js', false);
            xhr.send(null);
            var text = xhr.responseText;
            if ((xhr.status === 200 || xhr.status === 0) && text && text.length > 1000) {
                // nativeEval — исходный eval, наш перехватчик его не трогает.
                nativeEval.call(global, text);
                babel = global.Babel || null;
            }
        } catch (e) {
            stats.lastError = 'babel: ' + (e && e.message ? e.message : e);
        }
        stats.babel = babel ? 'ok' : 'fail';
        return babel;
    }

    function cacheGet(code) {
        for (var i = 0; i < cache.length; i++) {
            if (cache[i].input === code) {
                return cache[i].output;
            }
        }
        return null;
    }

    function cachePut(input, output) {
        if (input.length > 80000) {
            return;
        }
        cache.push({ input: input, output: output });
        if (cache.length > 24) {
            cache.shift();
        }
    }

    /**
     * Переписывает тело функции. Возвращает исходный текст, если переписать
     * не удалось — движок сам покажет свою ошибку, но мы не сломаем рабочий код.
     */
    function compile(code) {
        if (!looksModern(code) || transforming) {
            return code;
        }
        var cached = cacheGet(code);
        if (cached !== null) {
            return cached;
        }
        var lib = loadBabel();
        if (!lib || typeof lib.transform !== 'function') {
            return code;
        }

        transforming = true;
        var output = code;
        try {
            var result = lib.transform(code, {
                presets: [[
                    'env',
                    {
                        targets: { safari: '12' },
                        modules: false,
                        bugfixes: true,
                        loose: true,
                        useBuiltIns: false
                    }
                ]],
                sourceType: 'script',
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
            if (result && typeof result.code === 'string' && result.code.length > 0) {
                output = result.code;
                stats.fnOk++;
            } else {
                stats.fnErr++;
            }
        } catch (e) {
            stats.fnErr++;
            stats.lastError = String((e && e.message) || e);
        } finally {
            transforming = false;
        }

        cachePut(code, output);
        scheduleStats();
        return output;
    }

    /* -------------------------------------------------------------- Function --- */

    if (typeof NativeFunction === 'function') {
        var PCFunction = function Function() {
            var args = Array.prototype.slice.call(arguments);
            var last = args.length - 1;
            if (last >= 0 && typeof args[last] === 'string' && looksModern(args[last])) {
                stats.fn++;
                args[last] = compile(args[last]);
                scheduleStats();
            }
            return NativeFunction.apply(null, args);
        };
        PCFunction.prototype = NativeFunction.prototype;
        try {
            Object.defineProperty(PCFunction, 'name', { value: 'Function', configurable: true });
        } catch (e) {}
        try {
            global.Function = PCFunction;
        } catch (e) {
            stats.lastError = 'Function: ' + e;
        }
    }

    /* ------------------------------- AsyncFunction / GeneratorFunction -------- */

    function hookConstructor(proto, nativeCtor, label) {
        if (!proto || typeof nativeCtor !== 'function') {
            return;
        }
        var Wrapped = function () {
            var args = Array.prototype.slice.call(arguments);
            var last = args.length - 1;
            if (last >= 0 && typeof args[last] === 'string' && looksModern(args[last])) {
                if (label === 'async') {
                    stats.asyncFn++;
                } else {
                    stats.genFn++;
                }
                args[last] = compile(args[last]);
                scheduleStats();
            }
            return nativeCtor.apply(null, args);
        };
        Wrapped.prototype = nativeCtor.prototype;
        try {
            Object.defineProperty(proto, 'constructor', {
                value: Wrapped,
                writable: true,
                configurable: true
            });
        } catch (e) {
            stats.lastError = label + ': ' + e;
        }
    }

    try {
        var asyncProto = Object.getPrototypeOf(async function () {});
        hookConstructor(asyncProto, asyncProto.constructor, 'async');
    } catch (e) {}
    try {
        var genProto = Object.getPrototypeOf(function* () {});
        hookConstructor(genProto, genProto.constructor, 'gen');
    } catch (e) {}

    /* ----------------------------------------------------------------- eval --- */

    if (typeof nativeEval === 'function') {
        try {
            global.eval = function (code) {
                if (typeof code === 'string' && looksModern(code)) {
                    stats.evalCalls++;
                    code = compile(code);
                    scheduleStats();
                }
                return nativeEval.call(global, code);
            };
        } catch (e) {
            stats.lastError = 'eval: ' + e;
        }
    }

    /* ------------------------------------------------ <script> в DOM ---------- */

    function patchScriptNode(node) {
        if (!node || node.nodeType !== 1) {
            return;
        }
        if (String(node.tagName).toUpperCase() !== 'SCRIPT') {
            return;
        }
        if (node.__pcPatched) {
            return;
        }
        if (node.src) {
            return;
        }
        var text = node.textContent;
        if (!text || !looksModern(text)) {
            return;
        }
        try {
            node.__pcPatched = true;
            node.textContent = compile(text);
            stats.script++;
            scheduleStats();
        } catch (e) {
            stats.lastError = 'script: ' + e;
        }
    }

    function patchAnyNode(node) {
        if (!node || typeof node !== 'object') {
            return;
        }
        if (node.nodeType === 1) {
            patchScriptNode(node);
            return;
        }
        // DocumentFragment: движок может собрать <script> в фрагменте.
        if (node.nodeType === 11 && node.childNodes) {
            for (var i = 0; i < node.childNodes.length; i++) {
                patchScriptNode(node.childNodes[i]);
            }
        }
    }

    if (typeof global.Node === 'function' && global.Node.prototype) {
        var nodeProto = global.Node.prototype;

        function wrapInsertion(original) {
            return function () {
                for (var i = 0; i < arguments.length; i++) {
                    try {
                        patchAnyNode(arguments[i]);
                    } catch (e) {}
                }
                return original.apply(this, arguments);
            };
        }

        if (typeof nodeProto.appendChild === 'function') {
            nodeProto.appendChild = wrapInsertion(nodeProto.appendChild);
        }
        if (typeof nodeProto.insertBefore === 'function') {
            nodeProto.insertBefore = wrapInsertion(nodeProto.insertBefore);
        }
        if (typeof nodeProto.replaceChild === 'function') {
            nodeProto.replaceChild = wrapInsertion(nodeProto.replaceChild);
        }

        // Движок использует document.head.append(scriptEl) в запасном пути
        // после SyntaxError — без этого хука <script> проскочил бы как есть.
        var containers = [global.Element, global.Document, global.DocumentFragment];
        for (var c = 0; c < containers.length; c++) {
            var ctor = containers[c];
            if (!ctor || !ctor.prototype) { continue; }
            if (typeof ctor.prototype.append === 'function') {
                ctor.prototype.append = wrapInsertion(ctor.prototype.append);
            }
            if (typeof ctor.prototype.prepend === 'function') {
                ctor.prototype.prepend = wrapInsertion(ctor.prototype.prepend);
            }
        }
    }

    /* ------------------------------------- динамические URL и HTML-фрагменты --- */

    function rewriteURL(url) {
        if (typeof url !== 'string' || url.length === 0) {
            return url;
        }
        if (/^https?:\/\/[a-z0-9.-]*perchance\.org([\/?#]|$)/i.test(url)) {
            return 'wk://' + url.replace(/^https?:\/\//i, '');
        }
        if (/^\/\/[a-z0-9.-]*perchance\.org([\/?#]|$)/i.test(url)) {
            return 'wk:' + url;
        }
        return url;
    }

    function rewriteFragment(html) {
        if (typeof html !== 'string' || html.length === 0) {
            return html;
        }
        // Фрагмент без ссылок на perchance и без <script> трогать не нужно.
        if (html.indexOf('perchance.org') === -1 && html.indexOf('<script') === -1) {
            return html;
        }
        var out = html.replace(/(\bsrc\s*=\s*["'])(https?:\/\/[a-z0-9.-]*perchance\.org)/gi,
            function (m, pre, url) {
                return pre + rewriteURL(url);
            });
        out = out.replace(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi, function (m, attrs, body) {
            if (/\bsrc\s*=/i.test(attrs)) {
                return m;
            }
            var typeM = /\btype\s*=\s*["']?([^"'\s>]+)/i.exec(attrs);
            var type = typeM ? typeM[1] : '';
            if (type && !/^(text\/javascript|application\/javascript|module|text\/ecmascript)$/i.test(type)) {
                return m;
            }
            if (!body || !looksModern(body)) {
                return m;
            }
            return '<script' + attrs + '>' + compile(body) + '</script>';
        });
        return out;
    }

    // iframe.src = "https://…perchance.org/embed"
    try {
        var iframeProto = global.HTMLIFrameElement && global.HTMLIFrameElement.prototype;
        if (iframeProto) {
            var srcDesc = Object.getOwnPropertyDescriptor(iframeProto, 'src');
            if (srcDesc && srcDesc.set) {
                Object.defineProperty(iframeProto, 'src', {
                    configurable: true,
                    enumerable: srcDesc.enumerable,
                    get: srcDesc.get,
                    set: function (value) {
                        var rewritten = rewriteURL(value);
                        if (rewritten !== value) {
                            stats.iframe++;
                            scheduleStats();
                        }
                        return srcDesc.set.call(this, rewritten);
                    }
                });
            }
        }
    } catch (e) {}

    // iframe.setAttribute('src', …)
    try {
        var nativeSetAttribute = global.Element && global.Element.prototype.setAttribute;
        if (typeof nativeSetAttribute === 'function') {
            global.Element.prototype.setAttribute = function (name, value) {
                try {
                    if (String(name).toLowerCase() === 'src' && this && this.tagName &&
                        String(this.tagName).toUpperCase() === 'IFRAME') {
                        var rewritten = rewriteURL(value);
                        if (rewritten !== value) {
                            stats.iframe++;
                            scheduleStats();
                        }
                        value = rewritten;
                    }
                } catch (e) {}
                return nativeSetAttribute.call(this, name, value);
            };
        }
    } catch (e) {}

    // document.write
    if (doc && typeof doc.write === 'function') {
        var nativeWrite = doc.write;
        doc.write = function () {
            var args = Array.prototype.slice.call(arguments);
            var touched = false;
            for (var i = 0; i < args.length; i++) {
                if (typeof args[i] === 'string' && args[i].indexOf('<') !== -1) {
                    var rewritten = rewriteFragment(args[i]);
                    if (rewritten !== args[i]) {
                        args[i] = rewritten;
                        touched = true;
                    }
                }
            }
            if (touched) {
                stats.write++;
                scheduleStats();
            }
            return nativeWrite.apply(doc, args);
        };
    }

    // innerHTML / insertAdjacentHTML
    try {
        var htmlDesc = Object.getOwnPropertyDescriptor(global.Element.prototype, 'innerHTML');
        if (htmlDesc && htmlDesc.set) {
            Object.defineProperty(global.Element.prototype, 'innerHTML', {
                configurable: true,
                enumerable: htmlDesc.enumerable,
                get: htmlDesc.get,
                set: function (value) {
                    if (typeof value === 'string' && value.indexOf('<') !== -1) {
                        var rewritten = rewriteFragment(value);
                        if (rewritten !== value) {
                            stats.html++;
                            scheduleStats();
                            value = rewritten;
                        }
                    }
                    return htmlDesc.set.call(this, value);
                }
            });
        }
    } catch (e) {}

    try {
        var nativeInsertAdjacentHTML = global.Element.prototype.insertAdjacentHTML;
        if (typeof nativeInsertAdjacentHTML === 'function') {
            global.Element.prototype.insertAdjacentHTML = function (position, html) {
                var value = html;
                if (typeof value === 'string' && value.indexOf('<') !== -1) {
                    var rewritten = rewriteFragment(value);
                    if (rewritten !== value) {
                        stats.html++;
                        scheduleStats();
                        value = rewritten;
                    }
                }
                return nativeInsertAdjacentHTML.call(this, position, value);
            };
        }
    } catch (e) {}

    /* ------------------------------------------------- тела POST-запросов ---- */

    var bodySeq = 0;

    function captureBody(body) {
        if (typeof body !== 'string' || body.length === 0) {
            return null;
        }
        var handlers = global.webkit && global.webkit.messageHandlers;
        if (!handlers || !handlers.pcbody) {
            return null;
        }
        var id = 'b' + (++bodySeq) + '-' + (new Date().getTime());
        try {
            handlers.pcbody.postMessage({ id: id, body: body });
            return id;
        } catch (e) {
            stats.lastError = 'pcbody: ' + e;
            return null;
        }
    }

    var nativeFetch = global.fetch;

    /* ------------------------------------------------------ сеть: фолбэк ---- */

    // iOS 12 (WebKit 606) отказывает fetch() на нестандартной схеме, если
    // считает запрос кросс-доменным: «Cross origin requests are only
    // supported for HTTP». XHR на той же схеме работает всегда, поэтому при
    // таком отказе повторяем запрос через XHR и отдаём объект, похожий на
    // Response: status/headers/json()/text()/body.getReader().
    function isCustomSchemePage() {
        try {
            return String(global.location && global.location.protocol).toLowerCase() === 'wk:';
        } catch (e) {
            return false;
        }
    }

    function looksLikeCustomSchemeURL(url) {
        if (typeof url !== 'string' || url.length === 0) {
            return false;
        }
        if (/^wk:/i.test(url)) {
            return true;
        }
        if (!isCustomSchemePage()) {
            return false;
        }
        var first = url.charAt(0);
        return first === '/' || first === '?' ||
               url.indexOf('./') === 0 || url.indexOf('../') === 0;
    }

    function isAbortError(err) {
        if (!err) {
            return false;
        }
        if (err.name === 'AbortError') {
            return true;
        }
        return /abort/i.test(String(err.message || ''));
    }

    function encodeText(text) {
        if (global.TextEncoder) {
            try {
                return new global.TextEncoder().encode(text);
            } catch (e) {}
        }
        var out = new Uint8Array(text.length);
        for (var i = 0; i < text.length; i++) {
            out[i] = text.charCodeAt(i) & 0xff;
        }
        return out;
    }

    function xhrFetch(url, init) {
        return new global.Promise(function (resolve, reject) {
            var xhr = new global.XMLHttpRequest();
            var method = init && init.method ? String(init.method).toUpperCase() : 'GET';
            try {
                xhr.open(method, url, true);
            } catch (e) {
                reject(e);
                return;
            }
            try { xhr.responseType = 'text'; } catch (e) {}

            var headers = null;
            try {
                headers = new global.Headers((init && init.headers) || undefined);
            } catch (e) {
                headers = null;
            }
            if (headers && typeof headers.forEach === 'function') {
                headers.forEach(function (value, name) {
                    if (String(name).toLowerCase() === 'x-pc-body-id') {
                        return;
                    }
                    try { xhr.setRequestHeader(name, value); } catch (e) {}
                });
            }

            var body = init && init.body;
            if (typeof body === 'string' && body.length > 0) {
                var id = captureBody(body);
                if (id) {
                    try { xhr.setRequestHeader('X-PC-Body-Id', id); } catch (e) {}
                }
            }

            var text = '';
            var sent = 0;
            var done = false;
            var failure = null;
            var waiters = [];

            function takeChunk() {
                if (sent >= text.length) {
                    return null;
                }
                var end = text.length;
                var last = text.charCodeAt(end - 1);
                // Не рвём суррогатную пару на границе куска.
                if (last >= 0xD800 && last <= 0xDBFF) {
                    end -= 1;
                }
                if (end <= sent) {
                    return null;
                }
                var piece = text.slice(sent, end);
                sent = end;
                return encodeText(piece);
            }

            function pump() {
                while (waiters.length > 0) {
                    var chunk = takeChunk();
                    if (chunk) {
                        waiters.shift().resolve({ done: false, value: chunk });
                        continue;
                    }
                    if (failure) {
                        waiters.shift().reject(failure);
                        continue;
                    }
                    if (done) {
                        waiters.shift().resolve({ done: true, value: undefined });
                        continue;
                    }
                    return;
                }
            }

            var reader = {
                read: function () {
                    return new global.Promise(function (res, rej) {
                        waiters.push({ resolve: res, reject: rej });
                        pump();
                    });
                },
                cancel: function () {
                    try { xhr.abort(); } catch (e) {}
                    return global.Promise.resolve();
                },
                releaseLock: function () {}
            };

            function buildResponse() {
                var map = {};
                var raw = '';
                try { raw = xhr.getAllResponseHeaders() || ''; } catch (e) {}
                raw.split(/\r?\n/).forEach(function (line) {
                    var idx = line.indexOf(':');
                    if (idx > 0) {
                        map[line.slice(0, idx).trim().toLowerCase()] = line.slice(idx + 1).trim();
                    }
                });
                var status = 0;
                try { status = xhr.status || 0; } catch (e) {}
                return {
                    ok: status >= 200 && status < 300,
                    status: status,
                    statusText: '',
                    url: url,
                    redirected: false,
                    type: 'basic',
                    headers: {
                        get: function (name) {
                            var value = map[String(name).toLowerCase()];
                            return value === undefined ? null : value;
                        },
                        has: function (name) {
                            return Object.prototype.hasOwnProperty.call(map, String(name).toLowerCase());
                        }
                    },
                    text: function () {
                        return global.Promise.resolve(text);
                    },
                    json: function () {
                        return new global.Promise(function (res, rej) {
                            try { res(JSON.parse(text)); } catch (e) { rej(e); }
                        });
                    },
                    body: {
                        getReader: function () { return reader; }
                    }
                };
            }

            xhr.onprogress = function () {
                try {
                    var current = xhr.responseText || '';
                    if (current.length > text.length) {
                        text = current;
                        pump();
                    }
                } catch (e) {}
            };
            xhr.onload = function () {
                try { text = xhr.responseText || text; } catch (e) {}
                done = true;
                pump();
                resolve(buildResponse());
            };
            xhr.onerror = function () {
                failure = new Error('xhr network error');
                done = true;
                pump();
                reject(failure);
            };
            xhr.onabort = function () {
                var err = new Error('The operation was aborted.');
                err.name = 'AbortError';
                failure = err;
                done = true;
                pump();
                reject(err);
            };

            var signal = init && init.signal;
            if (signal && typeof signal.addEventListener === 'function') {
                if (signal.aborted) {
                    xhr.onabort();
                    return;
                }
                signal.addEventListener('abort', function () {
                    try { xhr.abort(); } catch (e) {}
                });
            }

            try {
                var payload = (method === 'GET' || method === 'HEAD') ? null : body;
                xhr.send(payload === undefined ? null : payload);
            } catch (e) {
                reject(e);
            }
        });
    }

    if (typeof nativeFetch === 'function') {
        global.fetch = function (input, init) {
            var target = input;
            try {
                // Абсолютные https://…perchance.org из кода генератора должны
                // идти через прокси: иначе Safari 12 получит современный JSON
                // напрямую (и CORS не сработает).
                if (typeof target === 'string') {
                    var rewrittenTarget = rewriteURL(target);
                    if (rewrittenTarget !== target) {
                        target = rewrittenTarget;
                    }
                }
            } catch (e) {}

            var options = init;
            try {
                if (init && typeof init === 'object') {
                    var copy = null;
                    var bodyId = null;
                    if (typeof init.body === 'string' && init.body.length > 0) {
                        bodyId = captureBody(init.body);
                    }
                    // Шим AbortController (iOS 12.0/12.1) — не настоящий
                    // AbortSignal: WebKit отверг бы такой fetch с TypeError.
                    var shimSignal = init.signal &&
                        !(global.AbortSignal && init.signal instanceof global.AbortSignal);
                    if (bodyId || shimSignal) {
                        copy = {};
                        for (var key in init) {
                            if (Object.prototype.hasOwnProperty.call(init, key)) {
                                copy[key] = init[key];
                            }
                        }
                        if (bodyId) {
                            var headers;
                            try {
                                headers = new global.Headers(init.headers ||
                                    (input && typeof input === 'object' ? input.headers : undefined));
                            } catch (e) {
                                headers = new global.Headers();
                            }
                            headers.set('X-PC-Body-Id', bodyId);
                            copy.headers = headers;
                        }
                        if (shimSignal) {
                            delete copy.signal;
                        }
                        options = copy;
                    }
                }
            } catch (e) {
                stats.lastError = 'fetch: ' + e;
                options = init;
            }

            var promise = nativeFetch.call(global, target, options);
            if (!looksLikeCustomSchemeURL(target)) {
                return promise;
            }
            return promise.catch(function (err) {
                if (isAbortError(err)) {
                    throw err;
                }
                stats.fetchFallback++;
                stats.lastError = 'fetch: ' + (err && err.message ? err.message : err);
                scheduleStats();
                return xhrFetch(target, options);
            });
        };
    }

    try {
        var XHR = global.XMLHttpRequest;
        if (XHR && XHR.prototype) {
            var nativeOpen = XHR.prototype.open;
            var nativeSend = XHR.prototype.send;
            var nativeSetRequestHeader = XHR.prototype.setRequestHeader;

            XHR.prototype.open = function (method, url) {
                try {
                    this.__pcMethod = String(method || '').toUpperCase();
                } catch (e) {}
                var args = Array.prototype.slice.call(arguments);
                try {
                    if (typeof url === 'string') {
                        var rewritten = rewriteURL(url);
                        if (rewritten !== url) {
                            args[1] = rewritten;
                        }
                    }
                } catch (e) {}
                return nativeOpen.apply(this, args);
            };

            XHR.prototype.send = function (body) {
                try {
                    var method = this.__pcMethod || '';
                    if (method && method !== 'GET' && method !== 'HEAD' &&
                        typeof body === 'string' && body.length > 0) {
                        var id = captureBody(body);
                        if (id) {
                            nativeSetRequestHeader.call(this, 'X-PC-Body-Id', id);
                        }
                    }
                } catch (e) {
                    stats.lastError = 'xhr: ' + e;
                }
                return nativeSend.apply(this, arguments);
            };
        }
    } catch (e) {}

    /* ------------------------------------------------------------- финиш ----- */

    global.__pcRuntimeStats = function () {
        return {
            stats: stats,
            babel: babel !== null,
            version: 3
        };
    };

    flushStats();
})(typeof window !== 'undefined' ? window : this);
