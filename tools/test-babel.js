// Проверка: Babel из бандла действительно убирает ?. и ?? под Safari 12.
const path = require('path');
const Babel = require(path.resolve(__dirname, '..', 'perchance-client', 'Resources', 'web', 'babel.min.js'));

const samples = [
  'var x = navigator.storage?.persist?.();',
  'debugInfo.memory.totalJSHeapSize = performance.memory?.totalJSHeapSize;',
  'var y = opts.name ?? "default";',
  'if (a?.b?.c) { await navigator.storage?.estimate?.(); }',
  'obj?.method?.(1, 2);',
];

for (const code of samples) {
  const out = Babel.transform(code, {
    presets: [['env', { targets: { safari: '12' }, modules: false }]],
    sourceType: 'unambiguous',
    compact: false,
    comments: false,
  }).code;
  const modern = /\?\.|\?\?/.test(out) ? 'STILL MODERN' : 'ok';
  let parses = 'ok';
  try {
    new Function(out);
  } catch (error) {
    parses = 'PARSE ERROR: ' + error.message;
  }
  console.log('IN :', code);
  console.log('OUT:', out.replace(/\s+/g, ' '), '|', modern, '|', parses);
  console.log('');
}
