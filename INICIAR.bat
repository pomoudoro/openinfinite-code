@echo off
setlocal
REM OpenInfinite Code - iniciar
REM   duplo clique                    -> menu do launcher
REM   arrastar uma pasta para ca      -> abre nessa pasta
REM Caminho recomendado no menu: 2 - 5 - 1 (pool de tuneis; sem o pool: 2 - 1 - 1)
REM   [2] Launch OpenCode  ->  [5] WIREGUARD  ->  [1] New IP and start OpenCode
set "APPDIR=%LOCALAPPDATA%\opencode-infinite\app"
set "APPBAT=%APPDIR%\OpenCode Infinite.bat"
set "SRC=%~dp0launcher"

if not exist "%APPBAT%" (
  echo OpenInfinite Code ainda nao esta instalado. Abrindo o instalador...
  call "%~dp0INSTALAR.bat"
)
if not exist "%APPBAT%" (
  echo Instalacao nao concluida. Rode o INSTALAR.bat e veja as mensagens.
  pause
  exit /b 1
)

REM Depois de um "git pull", a copia instalada e atualizada com os arquivos desta pasta.
for %%F in ("OpenCode Infinite.bat" "resume-runner.ps1" "desktop-resume.ps1" "resume-target.py") do (
  fc /b "%SRC%\%%~F" "%APPDIR%\%%~F" >nul 2>&1 || (
    echo   atualizando %%~F na copia instalada...
    copy /y "%SRC%\%%~F" "%APPDIR%\%%~F" >nul
  )
)

REM Atalhos do pool e scripts ficam na raiz do estado, nao em app.
set "STATEDIR=%LOCALAPPDATA%\opencode-infinite"
for %%F in ("POOL.bat" "FILA.bat") do (
  fc /b "%~dp0%%~F" "%STATEDIR%\%%~F" >nul 2>&1 || (
    echo   atualizando %%~F na copia instalada...
    copy /y "%~dp0%%~F" "%STATEDIR%\%%~F" >nul
  )
)
for %%F in ("warp-pool.ps1" "multi-dispatcher.ps1" "queue-add.ps1" "device-reset.ps1") do (
  fc /b "%SRC%\%%~F" "%STATEDIR%\%%~F" >nul 2>&1 || (
    echo   atualizando %%~F na copia instalada...
    copy /y "%SRC%\%%~F" "%STATEDIR%\%%~F" >nul
  )
)

REM Traducoes: o launcher le %STATEDIR%\lang\*.json. Antes so o INSTALAR.bat as copiava.
if exist "%STATEDIR%\lang\" for %%F in ("%SRC%\langs\*.json") do (
  fc /b "%%~fF" "%STATEDIR%\lang\%%~nxF" >nul 2>&1 || (
    echo   atualizando traducao %%~nxF...
    copy /y "%%~fF" "%STATEDIR%\lang\%%~nxF" >nul
  )
)

call "%APPBAT%" %*
exit /b %errorlevel%
