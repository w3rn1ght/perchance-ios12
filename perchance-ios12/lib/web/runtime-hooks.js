/*
 * runtime-hooks.js — минимальный рантайм-трансформер для Safari 12.
 * Записывает маркеры в localStorage и window для диагностики.
 */
(function (global) {
    'use strict';

    // Мгновенный маркер загрузки (до IIFE)
    try { localStorage.setItem('pc-runtime-load', '1'); } catch (e) {}

    if (!global || global.__pcRuntimeHooksInstalled) {
        try { localStorage.setItem('pc-runtime-skip', '1'); } catch (e) {}
        return;
    }
    global.__pcRuntimeHooksInstalled = true;
    global.__pcRuntimeReady = true;

    try { localStorage.setItem('pc-runtime-init', '1'); } catch (e) {}

    function transformCode(code) {
        if (typeof code !== 'string' || code.length === 0) return code;
        if (!/\?\.|\?\?|\|\|=|&&=/.test(code)) return code;

        var work = code;

        // a?.[b] -> (a==null?void 0:a[b])  — СНАЧАЛА
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

    var NativeFunction = global.Function;
    if (typeof NativeFunction === 'function') {
        var PCFunction = function PCFunction() {
            var args = Array.prototype.slice.call(arguments);
            var last = args.length - 1;
            if (last >= 0 && typeof args[last] === 'string') {
                var transformed = transformCode(args[last]);
                if (transformed !== args[last]) {
                    try { localStorage.setItem('pc-runtime-fn-count', String((parseInt(localStorage.getItem('pc-runtime-fn-count')||'0',10))+1)); } catch (e) {}
                }
                args[last] = transformed;
            }
            return NativeFunction.apply(null, args);
        };
        PCFunction.prototype = NativeFunction.prototype;
        try { global.Function = PCFunction; } catch (e) {}
    }

    var nativeEval = global.eval;
    if (typeof nativeEval === 'function') {
        try {
            global.eval = function (code) {
                if (typeof code === 'string') {
                    var transformed = transformCode(code);
                    if (transformed !== code) {
                        try { localStorage.setItem('pc-runtime-eval-count', String((parseInt(localStorage.getItem('pc-runtime-eval-count')||'0',10))+1)); } catch (e) {}
                    }
                    code = transformed;
                }
                return nativeEval.call(global, code);
            };
        } catch (e) {}
    }

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
                try { localStorage.setItem('pc-runtime-dom-count', String((parseInt(localStorage.getItem('pc-runtime-dom-count')||'0',10))+1)); } catch (e) {}
            } catch (e) {}
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
    }

    try { localStorage.setItem('pc-runtime-done', '1'); } catch (e) {}
})(typeof window !== 'undefined' ? window : this);