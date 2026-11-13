// Проверка runtime-hooks.js в песочнице: подменяем DOM/XHR, грузим настоящий Babel.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', 'perchance-client', 'Resources', 'web');
const hookSource = fs.readFileSync(path.join(root, 'runtime-hooks.js'), 'utf8');
const babelSource = fs.readFileSync(path.join(root, 'babel.min.js'), 'utf8');

class FakeNode {
  constructor(tagName) {
    this.nodeType = 1;
    this.tagName = tagName;
    this.children = [];
    this.textContent = '';
    this.src = '';
  }
  appendChild(child) { this.children.push(child); return child; }
  insertBefore(child) { this.children.push(child); return child; }
  replaceChild(child) { this.children.push(child); return child; }
}

const sandbox = { console, Node: FakeNode, setTimeout };
sandbox.window = sandbox;

vm.createContext(sandbox);
sandbox.eval = vm.runInContext('eval', sandbox);
sandbox.Function = vm.runInContext('Function', sandbox);
sandbox.XMLHttpRequest = function XMLHttpRequest() {
  this.status = 200;
  this.responseText = '';
  this.open = function (method, url) { this.url = url; };
  this.send = function () {
    if (this.url === '/__legacy/babel.min.js') {
      this.responseText = babelSource;
    }
  };
};

vm.runInContext(hookSource, sandbox, { filename: 'runtime-hooks.js' });

let ok = true;
function check(label, fn) {
  try {
    console.log('ok  ', label, '->', fn());
  } catch (error) {
    ok = false;
    console.log('FAIL', label, '->', error.message);
  }
}

check('new Function with ?.', () => sandbox.Function('var a = {b: 42}; return a?.b;')());
check('new Function with ??', () => sandbox.Function('var a = null; return a ?? 7;')());
check('function body with return', () => sandbox.Function('obj', 'return obj?.deep?.value;')({}));
check('eval with ?.', () => sandbox.eval('var q = {v: 5}; q?.v;'));
check('script node rewritten on append', () => {
  const parent = new FakeNode('HEAD');
  const script = new FakeNode('SCRIPT');
  script.textContent = 'window.__pcTest = {a: 1}; var v = window.__pcTest?.a;';
  parent.appendChild(script);
  if (script.textContent.indexOf('?.') !== -1) {
    throw new Error('?. остался');
  }
  vm.runInContext(script.textContent, sandbox);
  return sandbox.__pcTest.a;
});

const stats = sandbox.__pcRuntimeStats();
console.log('stats:', JSON.stringify({ babelLoaded: stats.babelLoaded, babelBroken: stats.babelBroken }));
console.log(ok ? 'ALL OK' : 'SOME FAILED');
process.exit(ok ? 0 : 1);
