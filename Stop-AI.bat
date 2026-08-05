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

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Stop-AI.ps1" %*

pause >nul
