/*
 * runtime-hooks.js — минимальный рантайм-трансформер для Safari 12.
 * Без зависимостей, без сложных парсеров. Только regex на всём коде.
 * Риск ложных срабатываний в строках/комментариях минимален для целевых операторов.
 */
(function (global) {
    'use strict';

    try { console.log('[pc-runtime] runtime-hooks.js загружен, старт инициализации'); } catch (e) {}

    if (!global || global.__pcRuntimeHooksInstalled) {
        try { console.log('[pc-runtime] уже установлен, выход'); } catch (e) {}
        return;
    }
    global.__pcRuntimeHooksInstalled = true;

    function note(message) {
        try { console.log('[pc-runtime] ' + message); } catch (e) {}
    }

    /* ---------- простая трансформация всего текста ---------- */

    function transformCode(code) {
        if (typeof code !== 'string' || code.length === 0) return code;
        // Быстрая проверка: есть ли что заменять
        if (!/\?\.|\?\?|\|\|=|&&=/.test(code)) return code;

        var work = code;

        // a?.[b] -> (a==null?void 0:a[b])  — СНАЧАЛА, иначе ?. съест ?.[
        work = work.replace(/(\w|\]|\)|\}|`)\?\.\s*\[/g, '$1==null?void 0:[');
        // a?.b -> (a==null?void 0:a.b)
        work = work.replace(/(\w|\]|\)|\}|`)\?\./g, '$1==null?void 0:');
        // a??b -> (a!=null?a:b)
        work = work.replace(/(\w|\]|\)|\}|`)\?\?/g, '$1!=null?$1:');
        // a||=b -> (a||(a=b))
        work = work.replace(/(\w|\]|\)|\}|`)\|\|=/g, '$1||($1=');
        // a&&=b -> (a&&(a=b))
        work = work.replace(/(\w|\]|\)|\}|`)&&=/g, '$1&&($1=');

        return work;
    }

    /* ---------- перехват Function ---------- */

    var NativeFunction = global.Function;
    if (typeof NativeFunction === 'function') {
        var PCFunction = function PCFunction() {
            var args = Array.prototype.slice.call(arguments);
            var last = args.length - 1;
            if (last >= 0 && typeof args[last] === 'string') {
                var transformed = transformCode(args[last]);
                if (transformed !== args[last]) {
                    note('Function перехвачен и переписан (' + args[last].length + ' -> ' + transformed.length + ')');
                }
                args[last] = transformed;
            }
            return NativeFunction.apply(null, args);
        };
        PCFunction.prototype = NativeFunction.prototype;
        try { global.Function = PCFunction; note('Function перехвачен'); }
        catch (e) { note('Function err: ' + e); }
    }

    /* ---------- перехват eval ---------- */

    var nativeEval = global.eval;
    if (typeof nativeEval === 'function') {
        try {
            global.eval = function (code) {
                if (typeof code === 'string') {
                    var transformed = transformCode(code);
                    if (transformed !== code) note('eval переписан');
                    code = transformed;
                }
                return nativeEval.call(global, code);
            };
            note('eval перехвачен');
        } catch (e) { note('eval err: ' + e); }
    }

    /* ---------- перехват DOM <script> ---------- */

    if (typeof global.Node === 'function' && global.Node.prototype) {
        var proto = global.Node.prototype;

        function patchScriptNode(node) {
            if (!node || node.nodeType !== 1) return;
            if (String(node.tagName).toUpperCase() !== 'SCRIPT') return;
            if (node.src) return;
            var text = node.textContent;
            if (!text || !/\?\.|\?\?|\|\|=|&&=/.test(text)) return;
            try {
                node.textContent = transformCode(text);
                note('DOM script переписан');
            } catch (e) { note('script err: ' + e); }
        }

        function wrapInsertion(orig) {
            return function (node) {
                try { patchScriptNode(node); } catch (e) {}
                return orig.apply(this, arguments);
            };
        }

        if (typeof proto.appendChild === 'function') proto.appendChild = wrapInsertion(proto.appendChild);
        if (typeof proto.insertBefore === 'function') proto.insertBefore = wrapInsertion(proto.insertBefore);
        if (typeof proto.replaceChild === 'function') proto.replaceChild = wrapInsertion(proto.replaceChild);
        note('DOM script перехват установлен');
    }

    note('runtime-hooks инициализирован (lite, no Babel)');
})(typeof window !== 'undefined' ? window : this);