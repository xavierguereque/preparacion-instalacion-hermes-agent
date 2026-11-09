@echo off
rem ===========================================================================
rem  Preparación para Hermes Agent - Windows (doble clic)
rem  Ejecuta scripts\prepare-windows.ps1 sin cambiar la política de ejecución.
rem  Si este .bat se copió solo (sin el repo), descarga el script de GitHub.
rem  Opciones: Preparar-Hermes.bat -CheckOnly  |  -Yes  |  -Reset
rem ===========================================================================
chcp 65001 >nul
setlocal
set "PS1=%~dp0..\scripts\prepare-windows.ps1"
set "URL=https://raw.githubusercontent.com/xavierguereque/preparacion-instalacion-hermes-agent/main/scripts/prepare-windows.ps1"

if exist "%PS1%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText('%PS1%', [Text.Encoding]::UTF8))) %*"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; & ([scriptblock]::Create((Invoke-RestMethod '%URL%'))) %*"
)

echo.
pause
endlocal
