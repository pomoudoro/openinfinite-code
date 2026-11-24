@echo off
setlocal
title OpenInfinite Code - instalador
REM Instala/atualiza o OpenInfinite Code. Pode rodar de novo quando quiser (git pull + INSTALAR.bat).
REM Opcoes: -Sim (responde sim para tudo)   -SemDependencias (pula Python/Node/WARP/Desktop)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\instalar.ps1" %*
set "RC=%errorlevel%"
echo.
pause
exit /b %RC%
