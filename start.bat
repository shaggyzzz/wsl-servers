@echo off
chcp 65001 >nul
title WSL Laravel Manager - Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-servers.ps1" start
echo.
pause
