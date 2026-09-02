@echo off
title Setup RPA - rehidratar sessao
echo Baixando e executando setup.ps1 do repositorio...
echo.

set "RAW=https://raw.githubusercontent.com/lkavaramos/transluterpa/main/setup.ps1"

powershell -ExecutionPolicy Bypass -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iwr -useb '%RAW%' | iex"

echo.
pause
