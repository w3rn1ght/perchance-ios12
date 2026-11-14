/*
 * runtime-hooks.js — лёгкий рантайм-трансформер для Safari 12.
 *
 * Не использует Babel (3 Мб слишком много для iOS 12).
 * Заменяет только критичный синтаксис, ломающий генераторы:
 *   - Optional chaining:   a?.b      → (a==null?void 0:a.b)
 *   - Optional bracket:    a?.[b]    → (a==null?void 0:a[b])
 *   - Nullish coalescing:  a??b      → (a!=null?a:b)
 *   - Logical assignment:  a||=b     → (a||(a=b))
 *                         a&&=b     → (a&&(a=b))
 *
 * Работает синхронно, без XHR, без зависимостей.
 */
(function (global) {
    'use strict';

    if (!global || global.__pcRuntimeHooksInstalled) {
        return;
    }
    global.__pcRuntimeHooksInstalled = true;

    var log = [];

    function note(message) {
        log.push(message);
        if (log.length > 50) log.shift();
        try { console.log('[pc-runtime] ' + message); } catch (e) {}
    }

    /* ---------- простые regex-замены для выражений (не в строках/комментариях) ---------- */

    function stripStringsAndComments(code) {
        var out = '';
        var i = 0, n = code.length;
        var inS = false, inD = false, inT = false, inReg = false, inComm = false, inCommM = false;
        var esc = false;
        while (i < n) {
            var ch = code[i];
            var ch2 = code[i+1];
            if (inComm) {
                if (ch === '\n') { inComm = false; out += ch; }
                i++; continue;
            }
            if (inCommM) {
                if (ch === '*' && ch2 === '/') { inCommM = false; out += '  '; i += 2; continue; }
                out += ' '; i++; continue;
            }
            if (inS) {
                out += ch;
                if (esc) { esc = false; }
                else if (ch === '\\') { esc = true; }
                else if (ch === '\'') { inS = false; }
                i++; continue;
            }
            if (inD) {
                out += ch;
                if (esc) { esc = false; }
                else if (ch === '\\') { esc = true; }
                else if (ch === '"') { inD = false; }
                i++; continue;
            }
            if (inT) {
                out += ch;
                if (esc) { esc = false; }
                else if (ch === '\\') { esc = true; }
                else if (ch === '`') { inT = false; }
                i++; continue;
            }
            if (inReg) {
                out += ch;
                if (esc) { esc = false; }
                else if (ch === '\\') { esc = true; }
                else if (ch === '/') { inReg = false; }
                i++; continue;
            }
            if (ch === '/' && ch2 === '/') { inComm = true; out += '  '; i += 2; continue; }
            if (ch === '/' && ch2 === '*') { inCommM = true; out += '  '; i += 2; continue; }
            if (ch === '\'') { inS = true; out += ch; i++; continue; }
            if (ch === '"') { inD = true; out += ch; i++; continue; }
            if (ch === '`') { inT = true; out += ch; i++; continue; }
            // очень грубая эвристика для regex: / после (,=,:,[,?,!,&,|,;,{,}, 
            if (ch === '/' && (i===0 || /[\(\[=:,\?\!&|\;\{\}\]]\s*$/.test(out))) { inReg = true; out += ch; i++; continue; }
            out += ch; i++;
        }
        return { code: out, map: buildMap(code, out) };
    }

    function buildMap(orig, stripped) {
        var map = [];
        var oi = 0, si = 0;
        while (oi < orig.length && si < stripped.length) {
            if (orig[oi] === stripped[si]) { map[si] = oi; oi++; si++; }
            else { oi++; }
        }
        return map;
    }

    function restoreStrings(original, transformed, map) {
        if (!map || map.length !== transformed.length) return transformed;
        var out = '';
        var ti = 0, oi = 0;
        while (ti < transformed.length) {
            var origIdx = map[ti];
            if (origIdx !== undefined && origIdx < original.length) {
                out += original[origIdx];
            } else {
                out += transformed[ti];
            }
            ti++;
        }
        return out;
    }

    /* ---------- трансформация кода ---------- */

    function transformCode(code) {
        if (typeof code !== 'string' || code.length === 0) return code;
        if (!/\?\.|\?\?|\|\|=|&&=/.test(code)) return code;

        var parts = stripStringsAndComments(code);
        var work = parts.code;

        // a?.[b] → (a==null?void 0:a[b])   — делаем ПЕРВЫМ, иначе ?. съест ?.[
        work = work.replace(/(\w|\]|\)|\}|\`)\?\.\s*\[/g, '$1==null?void 0:[');
        work = work.replace(/(\w|\]|\)|\}|\`)\?\./g, '$1==null?void 0:');
        // a??b → (a!=null?a:b)
        work = work.replace(/(\w|\]|\)|\}|\`)\?\?/g, '$1!=null?$1:');
        // a||=b → (a||(a=b))
        work = work.replace(/(\w|\]|\)|\}|\`)\|\|=/g, '$1||($1=');
        // a&&=b → (a&&(a=b))
        work = work.replace(/(\w|\]|\)|\}|\`)&&=/g, '$1&&($1=');

        return restoreStrings(code, work, parts.map);
    }

    /* ---------- перехват Function ---------- */

    var NativeFunction = global.Function;
    if (typeof NativeFunction === 'function') {
        var PCFunction = function PCFunction() {
            var args = Array.prototype.slice.call(arguments);
            var last = args.length - 1;
            if (last >= 0 && typeof args[last] === 'string') {
                args[last] = transformCode(args[last]);
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
                if (typeof code === 'string') code = transformCode(code);
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

    global.__pcRuntimeStats = function () {
        return { log: log.slice() };
    };
    note('runtime-hooks инициализирован (lite, no Babel)');
})(typeof window !== 'undefined' ? window : this);