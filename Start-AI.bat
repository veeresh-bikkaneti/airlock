@echo off
setlocal

where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 is not installed.
    echo.
    echo Install it, then double-click this file again:
    echo   winget install --id Microsoft.PowerShell -e
    echo.
    pause
    exit /b 1
)

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-AI.ps1" %*

echo.
echo Press any key to close this window. The platform keeps running in the background.
pause >nul
