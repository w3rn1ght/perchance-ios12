#!/usr/bin/env node
/* ============================================================================
 * make-cert.js — создаёт локальный CA и сертификат для *.perchance.org
 * ----------------------------------------------------------------------------
 * Нужен один раз. Требуется openssl в PATH (в Windows он есть в Git for
 * Windows: C:\Program Files\Git\usr\bin\openssl.exe).
 *
 *   node make-cert.js            → certs/ca.crt, certs/cert.pem, certs/key.pem
 *   node make-cert.js --force    → пересоздать
 *
 * После этого установи certs/ca.crt на iPhone (см. README, шаг 4).
 * ========================================================================== */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const os = require('os');

const ROOT = __dirname;
const CERT_DIR = path.join(ROOT, 'certs');
const DAYS = 3650;

function findOpenssl() {
  const candidates = [
    process.env.OPENSSL,
    'openssl',
    'C:\\Program Files\\Git\\usr\\bin\\openssl.exe',
    'C:\\Program Files (x86)\\Git\\usr\\bin\\openssl.exe',
    '/usr/bin/openssl',
    '/usr/local/bin/openssl'
  ].filter(Boolean);

  for (const c of candidates) {
    try {
      execFileSync(c, ['version'], { stdio: 'ignore' });
      return c;
    } catch (e) { /* пробуем следующий */ }
  }
  return null;
}

function run(openssl, args) {
  return execFileSync(openssl, args, { cwd: CERT_DIR, stdio: ['ignore', 'pipe', 'pipe'] }).toString();
}

function lanAddress() {
  try {
    return require('./lib/dns.js').lanIPv4();
  } catch (e) {
    return '127.0.0.1';
  }
}

function main() {
  const force = process.argv.includes('--force');
  fs.mkdirSync(CERT_DIR, { recursive: true });

  const caKey = path.join(CERT_DIR, 'ca.key');
  const caCrt = path.join(CERT_DIR, 'ca.crt');
  const key = path.join(CERT_DIR, 'key.pem');
  const cert = path.join(CERT_DIR, 'cert.pem');

  if (!force && fs.existsSync(key) && fs.existsSync(cert) && fs.existsSync(caCrt)) {
    console.log('Сертификаты уже есть:');
    console.log('  ' + caCrt);
    console.log('  ' + cert);
    console.log('Пересоздать: node make-cert.js --force');
    return;
  }

  const openssl = findOpenssl();
  if (!openssl) {
    console.error('openssl не найден.');
    console.error('Windows: установи Git for Windows (в нём есть openssl) и повтори.');
    console.error('macOS/Linux: обычно уже установлен.');
    process.exit(1);
  }
  console.log('openssl:', openssl);

  const ip = lanAddress();
  console.log('LAN IP:', ip);

  // --- корневой CA
  run(openssl, [
    'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', String(DAYS), '-nodes',
    '-keyout', 'ca.key', '-out', 'ca.crt',
    '-subj', '/CN=Perchance Legacy Portal CA/O=PerchanceLegacyPortal',
    '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
    '-addext', 'keyUsage=critical,keyCertSign,cRLSign'
  ]);

  // --- ключ сервера + CSR
  run(openssl, [
    'req', '-newkey', 'rsa:2048', '-nodes', '-sha256',
    '-keyout', 'key.pem', '-out', 'server.csr',
    '-subj', '/CN=perchance.org'
  ]);

  // --- расширения: SAN на все поддомены
  const ext = [
    'basicConstraints=CA:FALSE',
    'keyUsage=critical,digitalSignature,keyEncipherment',
    'extendedKeyUsage=serverAuth',
    'subjectAltName=DNS:perchance.org,DNS:*.perchance.org,' +
    'DNS:perchance.org.localhost,DNS:*.perchance.org.localhost,' +
    'DNS:localhost,IP:127.0.0.1,IP:' + ip
  ].join('\n');
  fs.writeFileSync(path.join(CERT_DIR, 'san.cnf'), ext + '\n');

  run(openssl, [
    'x509', '-req', '-in', 'server.csr',
    '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial',
    '-out', 'cert.pem', '-days', String(DAYS), '-sha256',
    '-extfile', 'san.cnf'
  ]);

  for (const f of ['server.csr', 'ca.srl']) {
    try { fs.unlinkSync(path.join(CERT_DIR, f)); } catch (e) {}
  }

  console.log('');
  console.log('Готово:');
  console.log('  CA (ставить на iPhone): ' + caCrt);
  console.log('  Сертификат сервера:     ' + cert);
  console.log('  Ключ сервера:           ' + key);
  console.log('');
  console.log('Дальше: см. README, раздел «Установка CA на iPhone».');
}

main();
