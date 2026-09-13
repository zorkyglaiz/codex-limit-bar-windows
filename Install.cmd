@echo off
setlocal
set "APPDIR=%~dp0"
echo Installing Codex Limit Bar for current user...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$src=$env:APPDIR; $dst=Join-Path $env:LOCALAPPDATA 'Programs\CodexLimitBar'; New-Item -ItemType Directory -Path $dst -Force | Out-Null; Get-ChildItem -LiteralPath $src -File | Where-Object { $_.Name -notin @('Install.cmd') } | Copy-Item -Destination $dst -Force; $shell=New-Object -ComObject WScript.Shell; $menu=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Limit Bar.lnk'; $lnk=$shell.CreateShortcut($menu); $ps=(Join-Path $PSHOME 'powershell.exe'); $lnk.TargetPath=$ps; $lnk.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $dst 'CodexLimitBar.ps1')+'"'; $lnk.WorkingDirectory=$dst; $ico=Join-Path $dst 'CodexLimitBar.ico'; if(Test-Path $ico){$lnk.IconLocation=$ico}; $lnk.Save(); Start-Process -FilePath $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $dst 'CodexLimitBar.ps1')+'"') -WindowStyle Hidden"
if errorlevel 1 (
  echo Installation failed.
  pause
  exit /b 1
)
echo.
echo Installed for current Windows user.
echo Start Menu: Codex Limit Bar
pause
