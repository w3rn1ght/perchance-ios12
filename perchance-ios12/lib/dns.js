/* ============================================================================
 * dns.js — крошечный DNS-сервер для iPhone
 * ----------------------------------------------------------------------------
 * Зачем: страница perchance.org подгружает iframe с другого поддомена
 * (<id>.perchance.org). Чтобы и он шёл через прокси, телефон должен считать,
 * что ВСЕ *.perchance.org живут на этом компьютере.
 *
 * Что делает:
 *   • A-запросы на perchance.org и *.perchance.org → IP этого компьютера;
 *   • AAAA (IPv6) для них → пустой ответ (иначе Safari пойдёт по IPv6 мимо);
 *   • все остальные домены → пересылает в обычный DNS (1.1.1.1 по умолчанию).
 *
 * На iPhone: Настройки → Wi-Fi → (i) → Настройка DNS → Вручную → IP компьютера.
 * ========================================================================== */

'use strict';

const dgram = require('dgram');
const os = require('os');

const UPSTREAM = process.env.LP_DNS_UPSTREAM || '1.1.1.1';
const UPSTREAM_PORT = 53;

function lanIPv4() {
  if (process.env.LP_LAN_IP) { return process.env.LP_LAN_IP; }
  const ifs = os.networkInterfaces();

  // Явно выбираем «домашние» диапазоны (192.168.x.x / 10.x.x.x), затем прочие
  const good = [];
  for (const name of Object.keys(ifs)) {
    for (const a of ifs[name] || []) {
      if (a.family !== 'IPv4' || a.internal) { continue; }
      if (/^(192\.168\.|10\.)/.test(a.address)) { good.push(a.address); }
    }
  }
  if (good.length) { return good[0]; }

  // Запасной вариант: любой IPv4, кроме явных VPN-сетей
  const VPN_RE = /^(172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/;
  for (const name of Object.keys(ifs)) {
    for (const a of ifs[name] || []) {
      if (a.family === 'IPv4' && !a.internal && !VPN_RE.test(a.address)) { return a.address; }
    }
  }
  return '127.0.0.1';
}

function parseQuestion(buf) {
  if (buf.length < 12) { return null; }
  const id = buf.readUInt16BE(0);
  const flags = buf.readUInt16BE(2);
  const qdcount = buf.readUInt16BE(4);
  if (qdcount < 1) { return null; }
  let off = 12;
  const labels = [];
  let guard = 0;
  while (off < buf.length) {
    const len = buf[off];
    if (len === 0) { off += 1; break; }
    if ((len & 0xc0) === 0xc0) { return null; } // сжатие в вопросе — не наш случай
    labels.push(buf.slice(off + 1, off + 1 + len).toString('ascii'));
    off += len + 1;
    if (++guard > 64) { return null; }
  }
  if (off + 4 > buf.length) { return null; }
  const qtype = buf.readUInt16BE(off);
  const qclass = buf.readUInt16BE(off + 2);
  return {
    id, flags, qdcount, qtype, qclass,
    name: labels.join('.').toLowerCase(),
    questionEnd: off + 4
  };
}

function buildAnswer(q, ip) {
  const question = Buffer.from([]);
  void question;
  const header = Buffer.alloc(12);
  header.writeUInt16BE(q.id, 0);
  // QR=1, RD=1, RA=1, NOERROR
  header.writeUInt16BE(0x8180, 2);
  header.writeUInt16BE(1, 4);   // qdcount
  header.writeUInt16BE(1, 6);   // ancount
  header.writeUInt16BE(0, 8);
  header.writeUInt16BE(0, 10);

  const nameBuf = encodeName(q.name);
  const questionBuf = Buffer.alloc(nameBuf.length + 4);
  nameBuf.copy(questionBuf, 0);
  questionBuf.writeUInt16BE(q.qtype, nameBuf.length);
  questionBuf.writeUInt16BE(1, nameBuf.length + 2);

  const answer = Buffer.alloc(16);
  answer.writeUInt16BE(0xc00c, 0);      // указатель на имя в вопросе
  answer.writeUInt16BE(1, 2);           // type A
  answer.writeUInt16BE(1, 4);           // class IN
  answer.writeUInt32BE(60, 6);          // TTL 60
  answer.writeUInt16BE(4, 10);          // rdlength
  const parts = ip.split('.').map((x) => parseInt(x, 10) & 0xff);
  answer[12] = parts[0]; answer[13] = parts[1]; answer[14] = parts[2]; answer[15] = parts[3];

  return Buffer.concat([header, questionBuf, answer]);
}

/** Ответ «нет такой записи» (NOERROR, 0 answers) — нужен для AAAA. */
function buildEmpty(q) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(q.id, 0);
  header.writeUInt16BE(0x8180, 2);
  header.writeUInt16BE(1, 4);
  const nameBuf = encodeName(q.name);
  const questionBuf = Buffer.alloc(nameBuf.length + 4);
  nameBuf.copy(questionBuf, 0);
  questionBuf.writeUInt16BE(q.qtype, nameBuf.length);
  questionBuf.writeUInt16BE(1, nameBuf.length + 2);
  return Buffer.concat([header, questionBuf]);
}

function encodeName(name) {
  const parts = name.split('.').filter(Boolean);
  const bufs = parts.map((p) => {
    const b = Buffer.from(p, 'ascii');
    const out = Buffer.alloc(b.length + 1);
    out[0] = b.length;
    b.copy(out, 1);
    return out;
  });
  return Buffer.concat([...bufs, Buffer.from([0])]);
}

function start(options) {
  const opts = options || {};
  const port = Number(process.env.LP_DNS_PORT || 53);
  const ip = lanIPv4();
  const socket = dgram.createSocket('udp4');
  const log = opts.log || (() => {});
  let intercepted = 0;
  let forwarded = 0;

  const relay = (msg, rinfo, q) => {
    const up = dgram.createSocket('udp4');
    let closed = false;
    const done = () => { if (!closed) { closed = true; try { up.close(); } catch (e) {} } };
    up.on('message', (reply) => {
      try { socket.send(reply, 0, reply.length, rinfo.port, rinfo.address); } catch (e) {}
      done();
    });
    up.on('error', () => done());
    setTimeout(() => {
      if (closed) { return; }
      // Апстрим молчит — отвечаем SERVFAIL, чтобы клиент не висел
      const h = Buffer.alloc(12);
      h.writeUInt16BE(q.id, 0);
      h.writeUInt16BE(0x8182, 2);
      try { socket.send(h, 0, h.length, rinfo.port, rinfo.address); } catch (e) {}
      done();
    }, 4000);
    try {
      up.send(msg, 0, msg.length, UPSTREAM_PORT, UPSTREAM);
    } catch (e) { done(); }
  };

  socket.on('message', (msg, rinfo) => {
    const q = parseQuestion(msg);
    if (!q) { return; }

    const isPerchance = q.name === 'perchance.org' || q.name.endsWith('.perchance.org');
    if (isPerchance) {
      intercepted++;
      if (q.qtype === 1) { // A
        const reply = buildAnswer(q, ip);
        socket.send(reply, 0, reply.length, rinfo.port, rinfo.address);
        return;
      }
      if (q.qtype === 28) { // AAAA — пусто, чтобы не ходить по IPv6
        const reply = buildEmpty(q);
        socket.send(reply, 0, reply.length, rinfo.port, rinfo.address);
        return;
      }
      // Прочие типы (TXT/MX) для perchance — тоже пустой ответ
      const reply = buildEmpty(q);
      socket.send(reply, 0, reply.length, rinfo.port, rinfo.address);
      return;
    }

    forwarded++;
    relay(msg, rinfo, q);
  });

  socket.on('error', (err) => {
    log('DNS error: ' + err.message);
    if (err.code === 'EACCES' || err.code === 'EADDRINUSE') {
      log('DNS не запущен (порт ' + port + ' занят или нужны права администратора).');
      log('Можно указать DNS вручную на iPhone или задать другой порт: LP_DNS_PORT=5353');
    }
  });

  socket.bind(port, '0.0.0.0', () => {
    log('DNS-сервер слушает UDP:' + port + ' → perchance.org = ' + ip +
      ', остальное → ' + UPSTREAM);
    if (opts.onReady) { opts.onReady({ ip, port }); }
  });

  return {
    ip,
    port,
    stats: () => ({ intercepted, forwarded }),
    close: () => { try { socket.close(); } catch (e) {} }
  };
}

module.exports = { start, lanIPv4, parseQuestion, buildAnswer, buildEmpty };
