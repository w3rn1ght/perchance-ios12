/*
 * runtime-hooks.js — переписывает код, который Perchance компилирует в рантайме.
 *
 * Зачем: файлы сайта проходят через Babel в прокси, но текст генераторов
 * (`modelText` из /api/generatorPageData) и inline-скрипты из outputTemplate
 * приходят данными. Движок собирает из них функцию и выполняет через
 * `new Function(...)` или вставляет <script> в DOM. Safari 12 падает на
 * первом `?.` в таком коде — отсюда страница «There is a problem with ...».
 *
 * Здесь мы перехватываем все точки исполнения и прогоняем код через тот же
 * Babel (он лежит в бандле, загружается лениво, синхронно — иначе нельзя:
 * компиляция в движке синхронная).
 *
 * Файл отдаётся как есть (без транспиляции), поэтому только ES5.
 */
(function (global) {
    'use strict';

    if (!global || global.__pcRuntimeHooksInstalled) {
        return;
    }
    global.__pcRuntimeHooksInstalled = true;

    var MODERN = /\?\.|\?\?/;
    var MAX_LENGTH = 900000;
    var CACHE_LIMIT = 8;
    var CACHE_MAX_CODE = 60000;

    var BabelLib = null;
    var babelBroken = false;
    var transforming = false;
    var cache = [];
    var log = [];

    function note(message) {
        log.push(message);
        if (log.length > 40) {
            log.shift();
        }
        try {
            console.log('[pc-runtime] ' + message);
        } catch (error) {
            /* консоли может не быть */
        }
    }

    function loadBabel() {
        if (BabelLib !== null || babelBroken) {
            return BabelLib;
        }
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/__legacy/babel.min.js', false);
            xhr.send(null);
            if ((xhr.status === 200 || xhr.status === 0) && xhr.responseText.length > 1000) {
                (0, eval)(xhr.responseText);
                BabelLib = global.Babel || null;
            }
        } catch (error) {
            note('Babel не загрузился: ' + error);
        }
        if (BabelLib === null) {
            babelBroken = true;
        }
        return BabelLib;
    }

    function rewrite(code) {
        var lib = loadBabel();
        if (lib === null) {
            return code;
        }
        var result = lib.transform(code, {
            presets: [['env', {
                targets: { safari: '12' },
                modules: false,
                bugfixes: true
            }]],
            sourceType: 'script',
            compact: false,
            comments: false,
            parserOpts: {
                allowReturnOutsideFunction: true,
                allowAwaitOutsideFunction: true,
                allowSuperOutsideMethod: true
            }
        });
        return (result && result.code) ? result.code : code;
    }

    function transform(code) {
        if (typeof code !== 'string' || code.length === 0) {
            return code;
        }
        if (!MODERN.test(code)) {
            return code;
        }
        if (code.length > MAX_LENGTH) {
            note('пропуск блока ' + code.length + ' символов');
            return code;
        }
        if (transforming) {
            return code;
        }

        var i;
        for (i = 0; i < cache.length; i++) {
            if (cache[i].input === code) {
                return cache[i].output;
            }
        }

        transforming = true;
        var output = code;
        try {
            output = rewrite(code);
            note('переписан блок ' + code.length + ' → ' + output.length);
        } catch (error) {
            note('ошибка переписывания: ' + error);
        } finally {
            transforming = false;
        }

        if (code.length <= CACHE_MAX_CODE) {
            cache.push({ input: code, output: output });
            if (cache.length > CACHE_LIMIT) {
                cache.shift();
            }
        }
        return output;
    }

    /* ------------------------------------------------------------ Function --- */

    var NativeFunction = global.Function;
    if (typeof NativeFunction === 'function') {
        var PCFunction = function PCFunction() {
            var args = Array.prototype.slice.call(arguments);
            var last = args.length - 1;
            if (last >= 0 && typeof args[last] === 'string') {
                args[last] = transform(args[last]);
            }
            return NativeFunction.apply(null, args);
        };
        PCFunction.prototype = NativeFunction.prototype;
        try {
            global.Function = PCFunction;
        } catch (error) {
            note('Function: ' + error);
        }
    }

    /* ---------------------------------------------------------------- eval --- */

    var nativeEval = global.eval;
    if (typeof nativeEval === 'function') {
        try {
            global.eval = function (code) {
                if (typeof code === 'string') {
                    code = transform(code);
                }
                return nativeEval.call(global, code);
            };
        } catch (error) {
            note('eval: ' + error);
        }
    }

    /* ----------------------------------------------- <script> в DOM ---------- */

    if (typeof global.Node === 'function' && global.Node.prototype) {
        var proto = global.Node.prototype;

        function patchScriptNode(node) {
            if (node === null || node === undefined || node.nodeType !== 1) {
                return;
            }
            if (String(node.tagName).toUpperCase() !== 'SCRIPT') {
                return;
            }
            if (node.src) {
                return;
            }
            var text = node.textContent;
            if (!text || !MODERN.test(text)) {
                return;
            }
            try {
                node.textContent = transform(text);
            } catch (error) {
                note('script: ' + error);
            }
        }

        function wrapInsertion(original) {
            return function (node) {
                try {
                    patchScriptNode(node);
                } catch (error) {
                    /* не мешаем вставке */
                }
                return original.apply(this, arguments);
            };
        }

        var nativeAppendChild = proto.appendChild;
        if (typeof nativeAppendChild === 'function') {
            proto.appendChild = wrapInsertion(nativeAppendChild);
        }
        var nativeInsertBefore = proto.insertBefore;
        if (typeof nativeInsertBefore === 'function') {
            proto.insertBefore = wrapInsertion(nativeInsertBefore);
        }
        var nativeReplaceChild = proto.replaceChild;
        if (typeof nativeReplaceChild === 'function') {
            proto.replaceChild = wrapInsertion(nativeReplaceChild);
        }
    }

    global.__pcRuntimeStats = function () {
        return {
            babelLoaded: BabelLib !== null,
            babelBroken: babelBroken,
            log: log.slice()
        };
    };
})(typeof window !== 'undefined' ? window : this);
