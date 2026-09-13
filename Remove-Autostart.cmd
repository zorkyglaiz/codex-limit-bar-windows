@echo off
set "P=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\CodexLimitBar.cmd"
if exist "%P%" del /q "%P%"
echo Autostart removed.
pause
