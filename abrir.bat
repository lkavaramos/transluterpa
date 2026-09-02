@echo off
setlocal enabledelayedexpansion
title Abrir VS Code (resgate TSplus)

set "DEV=%USERPROFILE%\dev"
set "FOUND="

rem --- locais comuns do VS Code (user install e system install) ---
for %%P in (
  "%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe"
  "%ProgramFiles%\Microsoft VS Code\Code.exe"
  "%ProgramFiles(x86)%\Microsoft VS Code\Code.exe"
) do if not defined FOUND if exist %%P set "FOUND=%%~P"

rem --- fallback: procura recursivamente no perfil do usuario ---
if not defined FOUND (
  for /f "delims=" %%i in ('dir /s /b "%LOCALAPPDATA%\Code.exe" 2^>nul') do if not defined FOUND set "FOUND=%%i"
)

if defined FOUND (
  start "" "!FOUND!" "%DEV%"
) else (
  echo VS Code nao encontrado. Abrindo prompt de resgate...
  start "" cmd /k "cd /d %DEV% & echo. & echo === Resgate === & echo Digite: powershell   para abrir o PowerShell & echo."
)

endlocal
