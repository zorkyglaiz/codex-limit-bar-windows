@echo off
setlocal
set "APPDIR=%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APPDIR%CodexLimitBar.ps1"
