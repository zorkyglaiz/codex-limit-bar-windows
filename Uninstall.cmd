@echo off
setlocal
echo Close Codex Limit Bar from the tray before uninstalling.
set /p OK=Continue uninstall? [Y/N]: 
if /I not "%OK%"=="Y" exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$startup=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Codex Limit Bar.lnk'; $menu=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Limit Bar.lnk'; if(Test-Path $startup){Remove-Item $startup -Force}; if(Test-Path $menu){Remove-Item $menu -Force}; $dst=Join-Path $env:LOCALAPPDATA 'Programs\CodexLimitBar'; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -Command "Start-Sleep -Seconds 2; if(Test-Path '''+$dst+'''){Remove-Item -LiteralPath '''+$dst+''' -Recurse -Force}"')"
echo Uninstall scheduled. You can close this window.
pause
