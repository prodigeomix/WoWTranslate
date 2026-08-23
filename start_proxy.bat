@echo off
title WoWTranslate Universal Proxy
cd /d "%~dp0"
echo ===================================================
echo   Starting WoWTranslate Proxy...
echo ===================================================
python wow_proxy.py
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Python not found in PATH or exited with error.
    pause
)
