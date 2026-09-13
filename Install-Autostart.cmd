@echo off
set "APPDIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\CodexLimitBar.cmd'; Set-Content -LiteralPath $p -Encoding ASCII -Value '@echo off`r`nstart "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%APPDIR%CodexLimitBar.ps1""'"
echo Autostart installed.
pause
