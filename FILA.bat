@echo off
setlocal
REM FILA.bat - wrapper da fila do dispatcher (queue-add.ps1) do OpenInfinite Code.
REM Estado: %LOCALAPPDATA%\opencode-infinite
set "STATE=%LOCALAPPDATA%\opencode-infinite"
set "ADDPS=%STATE%\queue-add.ps1"
set "DISPPS=%STATE%\multi-dispatcher.ps1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass"

if "%~1"=="" goto :sem_args
if /i "%~1"=="-h" goto :uso
if /i "%~1"=="-?" goto :uso
if /i "%~1"=="/?" goto :uso
if /i "%~1"=="-File" goto :add_file
if /i "%~1"=="--file" goto :add_file
if /i "%~1"=="dispatcher" goto :dispatcher
if /i "%~1"=="-Dispatcher" goto :dispatcher

%PS% -File "%ADDPS%" -Prompt "%*"
exit /b %errorlevel%

:add_file
if "%~2"=="" goto :uso
%PS% -File "%ADDPS%" -File "%~2"
exit /b %errorlevel%

:dispatcher
%PS% -File "%DISPPS%" -Count 4 -Project "%CD%" -Pool auto
exit /b %errorlevel%

:uso
echo Uso: FILA.bat "prompt"            - adiciona um prompt a fila
echo       FILA.bat -File prompts.txt  - adiciona um prompt por linha
echo       FILA.bat dispatcher         - inicia o dispatcher (consome a fila)
exit /b 0

:sem_args
call :uso
echo.
pause
exit /b 0
