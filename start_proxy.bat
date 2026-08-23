@echo off
title WoWTranslate Universal Proxy
cd /d "%~dp0"
echo ===================================================
echo   Starting WoWTranslate Proxy...
echo ===================================================
set PYTHONUNBUFFERED=1
python -u wow_proxy.py
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Python not found in PATH or exited with error.
    pause
)
