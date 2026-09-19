@echo off
chcp 65001 >nul
title WSL Laravel Manager - Setup Hosts & SSL

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Запрос прав Администратора (UAC)...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/c `\"%~f0`\"' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-servers.ps1" hosts
echo.
pause
