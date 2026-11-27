@echo off
setlocal
REM POOL.bat - atalhos para o pool de egress WARP (warp-pool.ps1).
REM Estado: %LOCALAPPDATA%\opencode-infinite
set "STATE=%LOCALAPPDATA%\opencode-infinite"
set "POOLPS=%STATE%\warp-pool.ps1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass"
set "FROMMENU="

if not exist "%POOLPS%" (
  echo warp-pool.ps1 nao encontrado em %STATE%
  echo Rode o INSTALAR.bat antes de usar o pool.
  goto :sem_pool
)

if "%~1"=="" goto :menu
set "OP=%~1"
if /i "%OP%"=="status" goto :do_status
if /i "%OP%"=="up" goto :do_up
if /i "%OP%"=="down" goto :do_down
if /i "%OP%"=="rotate" goto :do_rotate
if /i "%OP%"=="claim" goto :do_claim
if /i "%OP%"=="release" goto :do_release
if /i "%OP%"=="ver" goto :do_logs
if /i "%OP%"=="logs" goto :do_logs
if /i "%OP%"=="stats" goto :do_stats
if /i "%OP%"=="painel" goto :do_painel
if /i "%OP%"=="dashboard" goto :do_painel
if /i "%OP%"=="-h" goto :help
if /i "%OP%"=="/?" goto :help
echo Comando desconhecido: %OP%
call :help
exit /b 1

:menu
cls
echo === Pool de egress WARP (WPOOL) ===
echo   1 - status (slots, IPs, health)
echo   2 - up (sobe os slots)
echo   3 - down (desliga os slots)
echo   4 - rotate ^<n^> (troca o IP do slot n)
echo   5 - claim ^<instancia^> (reserva um slot)
echo   6 - release ^<instancia^> (libera o slot)
echo   7 - ver logs (status e eventos)
echo   8 - stats (familias de IP boas e queimadas, duracao dos IPs)
echo   9 - painel (abre no navegador: tuneis, familias, trocas)
echo   0 - sair
set "OP="
set /p "OP=Escolha: "
set "FROMMENU=1"
if "%OP%"=="1" goto :do_status
if "%OP%"=="2" goto :do_up
if "%OP%"=="3" goto :do_down
if "%OP%"=="4" goto :do_rotate
if "%OP%"=="5" goto :do_claim
if "%OP%"=="6" goto :do_release
if "%OP%"=="7" goto :do_logs
if "%OP%"=="8" goto :do_stats
if "%OP%"=="9" goto :do_painel
if "%OP%"=="0" exit /b 0
goto :menu

:help
echo Uso: POOL.bat ^<status^|up^|down^|rotate n^|claim instancia^|release instancia^|ver logs^|stats^|painel^>
exit /b 0

:sem_pool
if "%~1"=="" pause
exit /b 1

:do_status
%PS% -File "%POOLPS%" -Action status -State "%STATE%"
goto :fim

:do_up
if not "%~2"=="" (
  %PS% -File "%POOLPS%" -Action up -Count %~2 -State "%STATE%"
) else (
  %PS% -File "%POOLPS%" -Action up -State "%STATE%"
)
goto :fim

:do_down
%PS% -File "%POOLPS%" -Action down -State "%STATE%"
goto :fim

:do_rotate
set "N=%~2"
if defined FROMMENU if "%N%"=="" set /p "N=Numero do slot: "
if "%N%"=="" (
  echo Uso: POOL.bat rotate ^<n^>
  goto :fim
)
%PS% -File "%POOLPS%" -Action rotate -Slot %N% -State "%STATE%"
goto :fim

:do_claim
set "INST=%~2"
if defined FROMMENU if "%INST%"=="" set /p "INST=Instancia: "
if "%INST%"=="" (
  echo Uso: POOL.bat claim ^<instancia^>
  goto :fim
)
%PS% -File "%POOLPS%" -Action claim -Instance "%INST%" -State "%STATE%"
goto :fim

:do_release
set "INST=%~2"
if defined FROMMENU if "%INST%"=="" set /p "INST=Instancia: "
if "%INST%"=="" (
  echo Uso: POOL.bat release ^<instancia^>
  goto :fim
)
%PS% -File "%POOLPS%" -Action release -Instance "%INST%" -State "%STATE%"
goto :fim

:do_logs
if exist "%STATE%\pool\pool-status.json" (
  %PS% -Command "Get-Content -LiteralPath '%STATE%\pool\pool-status.json' -Tail 40"
)
if exist "%STATE%\recovery-events.jsonl" (
  %PS% -Command "Get-Content -LiteralPath '%STATE%\recovery-events.jsonl' -Tail 15"
)
goto :fim

:do_stats
%PS% -File "%POOLPS%" -Action stats -State "%STATE%"
goto :fim

REM O vigia regrava o painel a cada ciclo e a pagina recarrega sozinha a cada 30 s.
:do_painel
%PS% -File "%POOLPS%" -Action dashboard -State "%STATE%"
goto :fim

:fim
if defined FROMMENU goto :menu_pause
exit /b %errorlevel%

:menu_pause
pause
goto :menu
