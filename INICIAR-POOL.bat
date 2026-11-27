@echo off
setlocal
REM OpenInfinite Code - abrir direto no pool de tuneis (o mesmo que INICIAR.bat - 2 - 5 - 1, sem menus)
REM   duplo clique                    -> abre na ultima pasta usada
REM   arrastar uma pasta para ca      -> abre nessa pasta
REM Precisa do pool ligado (Definicoes - Pool de tuneis) e de WIREGUARD como metodo de ligacao.
set "STATEDIR=%LOCALAPPDATA%\opencode-infinite"
set "PASTA="
if not "%~1"=="" if exist "%~1\" set "PASTA=%~1"
if not defined PASTA if exist "%STATEDIR%\lastfolder.txt" set /p PASTA=<"%STATEDIR%\lastfolder.txt"
REM lastfolder.txt guarda o caminho entre aspas.
if defined PASTA set "PASTA=%PASTA:"=%"
if defined PASTA if exist "%PASTA%\" cd /d "%PASTA%"
call "%~dp0INICIAR.bat" --pool
exit /b %errorlevel%
