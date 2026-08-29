@echo off
title WoWTranslate Universal Proxy
cd /d "%~dp0"
echo ===================================================
echo   Starting WoWTranslate Proxy...
echo ===================================================
set PYTHONUNBUFFERED=1

where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    python -u wow_proxy.py
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo ===================================================
        echo   [ERROR] Proxy terminated with error code %ERRORLEVEL%.
        echo ===================================================
        pause
    )
    goto done
)

where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    py -u wow_proxy.py
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo ===================================================
        echo   [ERROR] Proxy terminated with error code %ERRORLEVEL%.
        echo ===================================================
        pause
    )
    goto done
)

echo.
echo ===================================================
echo   [ERROR] Python is not found on your computer!
echo ===================================================
echo.
echo 1. Download Python from: https://www.python.org/downloads/
echo 2. CRITICAL: Check the box "Add python.exe to PATH" at the bottom!
echo.
echo Or run this in PowerShell: winget install Python.Python.3.12
echo ===================================================
echo.
pause

:done
