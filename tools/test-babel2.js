const path = require('path');
const Babel = require(path.resolve(__dirname, '..', 'perchance-client', 'Resources', 'web', 'babel.min.js'));

const samples = [
  'return foo?.bar;',
  'var x = await navigator.storage?.estimate?.(); return x;',
  'async function f() { return (await getThing())?.value ?? 0; }',
  'class A { #x = 1; get() { return this.#x; } }',
];

for (const code of samples) {
  try {
    const out = Babel.transform(code, {
      presets: [['env', { targets: { safari: '12' }, modules: false, bugfixes: true }]],
      sourceType: 'script',
      compact: false,
      comments: false,
      parserOpts: {
        allowReturnOutsideFunction: true,
        allowAwaitOutsideFunction: true,
        allowSuperOutsideMethod: true,
      },
    }).code;
    const modern = /\?\.|\?\?|#[A-Za-z_$]/.test(out) ? 'STILL MODERN' : 'ok';
    let parses = 'ok';
    try { new Function(out); } catch (e) { parses = 'PARSE ERROR: ' + e.message; }
    console.log('IN :', code);
    console.log('OUT:', out.replace(/\s+/g, ' '), '|', modern, '|', parses);
  } catch (e) {
    console.log('IN :', code);
    console.log('FAIL:', e.message);
  }
  console.log('');
}
