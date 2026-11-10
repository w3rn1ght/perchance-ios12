/* ============================================================================
 * browser.js — рендер страниц через установленный браузер (Chrome/Edge)
 * ----------------------------------------------------------------------------
 * Зачем: Cloudflare на perchance.org пускает настоящий браузер и не пускает
 * серверные запросы (403 managed challenge). Статику (JS/CSS) сервер качает
 * сам — её CF не трогает, — а вот сами страницы (<html>) достаём браузером:
 *
 *   1) запускаем Chrome/Edge в фоне (--headless=new) с отдельным профилем;
 *   2) по CDP (WebSocket) открываем страницу, ждём загрузки;
 *   3) забираем HTML прямо из документа (после того как CF пропустил браузер);
 *   4) отдаём клиенту HTML с уже вставленными полифилами.
 *
 * Браузер ничего не отображает пользователю — это «голова» для прокси.
 * ========================================================================== */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const crypto = require('crypto');

const DEBUG_PORT = Number(process.env.LP_BROWSER_PORT || 9333);

const CANDIDATES = [
  process.env.LP_BROWSER,
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Google\\Chrome\\Application\\chrome.exe'),
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/usr/bin/microsoft-edge'
];

function findBrowser() {
  for (const c of CANDIDATES) {
    try { if (c && fs.existsSync(c)) { return c; } } catch (e) {}
  }
  return null;
}

/* -------------------------------------------------------------------- MiniWS */

class MiniWS {
  constructor(socket, rest) {
    this.socket = socket;
    this.buf = rest && rest.length ? rest : Buffer.alloc(0);
    this.handlers = [];
    this.closed = false;
    this._frag = [];
    socket.on('data', (c) => {
      this.buf = Buffer.concat([this.buf, c]);
      this._drain();
    });
    socket.on('close', () => { this.closed = true; });
    socket.on('error', () => { this.closed = true; });
  }

  static connect(host, port, pathStr) {
    return new Promise((resolve, reject) => {
      const key = crypto.randomBytes(16).toString('base64');
      const socket = net.connect(port, host, () => {
        socket.write(
          'GET ' + pathStr + ' HTTP/1.1\r\n' +
          'Host: ' + host + ':' + port + '\r\n' +
          'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
          'Sec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n' +
          'Origin: http://127.0.0.1:' + port + '\r\n\r\n'
        );
      });
      let headBuf = Buffer.alloc(0);
      const onData = (chunk) => {
        headBuf = Buffer.concat([headBuf, chunk]);
        const idx = headBuf.indexOf('\r\n\r\n');
        if (idx < 0) { return; }
        socket.removeListener('data', onData);
        const head = headBuf.slice(0, idx).toString();
        if (!/^HTTP\/1\.1 101/.test(head)) {
          socket.destroy();
          reject(new Error('WS handshake failed: ' + head.split('\r\n')[0]));
          return;
        }
        resolve(new MiniWS(socket, headBuf.slice(idx + 4)));
      };
      socket.on('data', onData);
      socket.on('error', reject);
      setTimeout(() => reject(new Error('WS connect timeout')), 15000);
    });
  }

  onMessage(fn) { this.handlers.push(fn); }

  send(text) {
    if (this.closed) { return; }
    const payload = Buffer.from(text, 'utf8');
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x81, 0x80 | len]);
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x81; header[1] = 0x80 | 126; header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81; header[1] = 0x80 | 127;
      header.writeUInt32BE(Math.floor(len / 4294967296), 2);
      header.writeUInt32BE(len >>> 0, 6);
    }
    const mask = crypto.randomBytes(4);
    const masked = Buffer.alloc(len);
    for (let i = 0; i < len; i++) { masked[i] = payload[i] ^ mask[i & 3]; }
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  _drain() {
    for (;;) {
      if (this.buf.length < 2) { return; }
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (this.buf.length < 4) { return; }
        len = this.buf.readUInt16BE(2); offset = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) { return; }
        const hi = this.buf.readUInt32BE(2);
        const lo = this.buf.readUInt32BE(6);
        len = hi * 4294967296 + lo; offset = 10;
      }
      const maskLen = masked ? 4 : 0;
      if (this.buf.length < offset + maskLen + len) { return; }
      const mask = masked ? this.buf.slice(offset, offset + 4) : null;
      const data = Buffer.from(this.buf.slice(offset + maskLen, offset + maskLen + len));
      if (mask) { for (let i = 0; i < data.length; i++) { data[i] ^= mask[i & 3]; } }
      this.buf = this.buf.slice(offset + maskLen + len);

      if (opcode === 0x8) { this.close(); return; }
      if (opcode === 0x9) { this._writeFrame(0xA, data); continue; }
      if (opcode === 0xA) { continue; }

      this._frag.push(data);
      if (!fin) { continue; }
      const full = Buffer.concat(this._frag);
      this._frag = [];
      const text = full.toString('utf8');
      for (const h of this.handlers) {
        try { h(text); } catch (e) {}
      }
    }
  }

  _writeFrame(opcode, payload) {
    if (this.closed) { return; }
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x80 | opcode, 0x80 | len]);
    } else {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode; header[1] = 0x80 | 126; header.writeUInt16BE(len, 2);
    }
    const mask = crypto.randomBytes(4);
    const masked = Buffer.alloc(len);
    for (let i = 0; i < len; i++) { masked[i] = payload[i] ^ mask[i & 3]; }
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  close() {
    this.closed = true;
    try { this.socket.destroy(); } catch (e) {}
  }
}

/* --------------------------------------------------------------- CDP-клиент */

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    this.listeners = [];
    this.methodListeners = new Map();
    ws.onMessage((text) => {
      let msg;
      try { msg = JSON.parse(text); } catch (e) { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) { reject(new Error(msg.error.message)); } else { resolve(msg.result); }
      } else if (msg.method) {
        const ml = this.methodListeners.get(msg.method);
        if (ml) { for (const l of ml) { try { l(msg.params); } catch (e) {} } }
        for (const l of this.listeners) { l(msg); }
      }
    });
  }

  once(method) {
    return new Promise((resolve) => {
      let list = this.methodListeners.get(method);
      if (!list) { this.methodListeners.set(method, list = []); }
      const fn = (params) => {
        const i = list.indexOf(fn);
        if (i >= 0) { list.splice(i, 1); }
        resolve(params);
      };
      list.push(fn);
    });
  }

  send(method, params) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error('CDP timeout: ' + method));
        }
      }, 30000);
      this.ws.send(JSON.stringify({ id, method, params: params || {} }));
    });
  }

  on(fn) { this.listeners.push(fn); }
  close() { this.ws.close(); }
}

/* ------------------------------------------------------------- управление */

const state = {
  proc: null,
  userDataDir: path.join(os.tmpdir(), 'perchance-legacy-portal-browser'),
  ready: false,
  starting: null,
  failed: false,
  lastError: ''
};

function httpGetJSON(url) {
  return new Promise((resolve, reject) => {
    const r = require('http').get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (e) { reject(e); }
      });
    });
    r.on('error', reject);
    r.setTimeout(4000, () => r.destroy(new Error('timeout')));
  });
}

/** PUT/POST/DELETE для CDP-эндпоинтов (/json/new, /json/close). */
function httpDevtools(url, method) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const r = require('http').request({
      host: u.hostname,
      port: u.port,
      path: u.pathname + u.search,
      method: method || 'PUT',
      headers: { 'content-length': '0', connection: 'close' }
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        try {
          resolve({ status: res.statusCode, json: body ? JSON.parse(body) : null, body });
        } catch (e) {
          resolve({ status: res.statusCode, json: null, body });
        }
      });
    });
    r.on('error', reject);
    r.setTimeout(10000, () => r.destroy(new Error('timeout')));
    r.end();
  });
}

async function waitForDebugPort(timeoutMs) {
  const start = Date.now();
  let lastBody = '';
  while (Date.now() - start < timeoutMs) {
    try {
      const v = await httpGetJSON('http://127.0.0.1:' + DEBUG_PORT + '/json/version');
      if (v && v.webSocketDebuggerUrl) { return v; }
    } catch (e) {
      lastBody = String(e.message || '');
      // Chromium 111+ требует явный Origin, иначе отвечает «Using unsafe HTTP verb GET…»
    }
    await new Promise((r) => setTimeout(r, 350));
  }
  throw new Error('браузер не открыл отладочный порт ' + DEBUG_PORT +
    (lastBody && lastBody.startsWith('Using unsafe') ? ' (CDP отклоняет запросы без Origin — нужен --remote-allow-origins)' : ''));
}

async function ensureBrowser(timeoutMs) {
  if (state.ready) { return; }
  if (state.starting) { return state.starting; }

  state.starting = (async () => {
    // Может быть уже запущен (LP_BROWSER_PORT указывает на чужой экземпляр)
    try {
      await waitForDebugPort(600);
      state.ready = true;
      return;
    } catch (e) {}

    const exe = findBrowser();
    if (!exe) {
      state.failed = true;
      state.lastError = 'Chrome/Edge не найден. Установи Google Chrome или Microsoft Edge.';
      throw new Error(state.lastError);
    }

    fs.mkdirSync(state.userDataDir, { recursive: true });
    // --headless=new проще в эксплуатации; если CF придирается к headless,
    // запусти start-browser.bat (видимое окно) — сервер подключится к нему.
    const headless = process.env.LP_BROWSER_HEADLESS === '0' ? '' : '--headless=new';
    const args = [
      headless,
      '--remote-debugging-port=' + DEBUG_PORT,
      '--remote-allow-origins=*',
      '--user-data-dir=' + state.userDataDir,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--disable-extensions',
      '--mute-audio',
      '--window-size=430,932',
      '--lang=en-US',
      'about:blank'
    ].filter(Boolean);
    state.proc = spawn(exe, args, { stdio: 'ignore' });
    state.proc.on('exit', () => {
      state.ready = false;
      state.proc = null;
    });

    await waitForDebugPort(timeoutMs || 30000);
    state.ready = true;
  })();

  try {
    await state.starting;
  } finally {
    state.starting = null;
  }
}

/**
 * Загружает HTML страницы через браузер.
 * @returns {Promise<{html:string, status:number, url:string}>}
 */
async function fetchPage(url, timeoutMs) {
  await ensureBrowser();

  const target = (await httpDevtools(
    'http://127.0.0.1:' + DEBUG_PORT + '/json/new?' + encodeURIComponent('about:blank'), 'PUT')).json;
  if (!target || !target.webSocketDebuggerUrl) {
    throw new Error('не удалось создать вкладку в браузере');
  }
  const wsUrl = new URL(target.webSocketDebuggerUrl);
  const ws = await MiniWS.connect('127.0.0.1', DEBUG_PORT, wsUrl.pathname);
  const cdp = new CDP(ws);

  const cleanup = () => {
    try { cdp.close(); } catch (e) {}
    httpDevtools('http://127.0.0.1:' + DEBUG_PORT + '/json/close/' + target.id, 'GET').catch(() => {});
  };

  try {
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');

    // Настоящий браузер + «человеческий» вьюпорт: CF challenge в headless
    // проходит только если окно выглядит как обычное.
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 430, height: 932, deviceScaleFactor: 2, mobile: true
    });

    const loaded = new Promise((resolve) => {
      let done = false;
      const finish = () => { if (!done) { done = true; resolve(); } };
      cdp.on((msg) => {
        if (msg.method === 'Page.loadEventFired') { finish(); }
      });
      setTimeout(finish, timeoutMs || 45000);
    });

    await cdp.send('Page.navigate', { url });
    await loaded;

    // Cloudflare interstitial сам перезагружает страницу — ждём, пока появится
    // настоящая разметка Perchance (или пока не истечёт время).
    const deadline = Date.now() + 40000;
    let html = '';
    let title = '';
    const texts = [];
    for (;;) {
      const res = await cdp.send('Runtime.evaluate', {
        expression: 'JSON.stringify({h: document.documentElement ? document.documentElement.outerHTML : "", t: document.title, u: location.href, x: document.body ? document.body.innerText.slice(0, 300) : ""})',
        returnByValue: true
      });
      let info = {};
      try { info = JSON.parse(res.result.value); } catch (e) {}
      html = info.h || '';
      title = info.t || '';
      const looksLikeCf = /Just a moment|Checking your browser|Attention Required|cf-challenge|Performing security verification/i.test(title + html.slice(0, 4000));
      const looksReal = html.indexOf('generatorPagePath') !== -1 || html.indexOf('menuBarEl') !== -1;
      if (looksReal && !looksLikeCf) { break; }
      if (!looksLikeCf && /__CF|cf_clearance/.test(html + (info.u || ''))) {
        // CF-challenge на странице
      }
      if (Date.now() > deadline) { break; }
      texts.push((info.x || '').slice(0, 120).replace(/\s+/g, ' '));
      await new Promise((r) => setTimeout(r, 800));
    }

    return {
      html: '<!doctype html>\n' + html,
      status: html && html.length > 500 ? 200 : 502,
      url,
      title,
      challengeTexts: texts.slice(-3)
    };
  } finally {
    cleanup();
  }
}

function status() {
  const p = findBrowser();
  return {
    available: !!p,
    path: p || null,
    running: state.ready,
    error: state.lastError || null,
    port: DEBUG_PORT
  };
}

function shutdown() {
  if (state.proc) {
    try { state.proc.kill(); } catch (e) {}
  }
}

module.exports = { fetchPage, ensureBrowser, status, findBrowser, shutdown, MiniWS, CDP, DEBUG_PORT };
