const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', 'perchance-client', 'Resources', 'web');
const hookSource = fs.readFileSync(path.join(root, 'runtime-hooks.js'), 'utf8');
const babelSource = fs.readFileSync(path.join(root, 'babel.min.js'), 'utf8');

class FakeNode {
  constructor(tag) { this.nodeType = 1; this.tagName = tag; this.textContent = ''; this.src = ''; }
  appendChild(child) { return child; }
  insertBefore(child) { return child; }
  replaceChild(child) { return child; }
}

const sandbox = {};
sandbox.window = sandbox;
sandbox.console = console;
sandbox.Node = FakeNode;
sandbox.Function = Function;
sandbox.eval = eval;
sandbox.setTimeout = setTimeout;
sandbox.XMLHttpRequest = function () {
  this.status = 200;
  this.responseText = '';
  this.open = function (m, u) { this.url = u; };
  this.send = function () { if (this.url === '/__legacy/babel.min.js') this.responseText = babelSource; };
};

vm.createContext(sandbox);
sandbox.eval = vm.runInContext('eval', sandbox);
sandbox.Function = vm.runInContext('Function', sandbox);
vm.runInContext(hookSource, sandbox, { filename: 'runtime-hooks.js' });

console.log('typeof Babel before:', typeof sandbox.Babel);
try {
  const factory = sandbox.Function('var a = {b: 1}; return a?.b;');
  console.log('factory result:', factory());
} catch (e) {
  console.log('factory error:', e.message);
}
console.log('typeof Babel after:', typeof sandbox.Babel);
const stats = sandbox.__pcRuntimeStats();
console.log('stats:', JSON.stringify({ babelLoaded: stats.babelLoaded, babelBroken: stats.babelBroken }));
console.log('log:', stats.log);
