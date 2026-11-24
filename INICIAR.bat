@echo off
setlocal
REM OpenInfinite Code - iniciar
REM   duplo clique                    -> menu do launcher
REM   arrastar uma pasta para ca      -> abre nessa pasta
REM Caminho recomendado no menu: 2 - 1 - 1
REM   [2] Desktop app  ->  [1] Reabrir a ultima pasta  ->  [1] WARP
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

call "%APPBAT%" %*
exit /b %errorlevel%
