@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "NODE=%~dp0node-portable\node.exe"
if not exist "%NODE%" set "NODE=node"

if not exist "%~dp0certs\cert.pem" (
    echo Первый запуск: создаю сертификат для HTTPS...
    "%NODE%" make-cert.js
)

"%NODE%" server.js
pause
