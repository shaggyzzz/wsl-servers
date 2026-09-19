@echo off
chcp 65001 >nul
title WSL Laravel Manager - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-servers.ps1" status
echo.
pause
