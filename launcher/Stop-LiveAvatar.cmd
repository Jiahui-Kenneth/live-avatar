@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LiveAvatar.ps1" -Command stop
if errorlevel 1 pause
