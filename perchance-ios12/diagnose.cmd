@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "NODE=%~dp0node-portable\node.exe"
if not exist "%NODE%" set "NODE=node"

echo === Диагностика сети и транспиляции ===
"%NODE%" diag.js
echo.
echo === Cloudflare: HTTP/2 против HTTP/1.1 ===
"%NODE%" probe.js
echo.
echo === Сертификат HTTPS ===
"%NODE%" make-cert.js
echo.
echo === Самопроверка трансформера ===
echo (если сервер не запущен — сначала запусти start.cmd)
"%NODE%" selftest.js
pause
