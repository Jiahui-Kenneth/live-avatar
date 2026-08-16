@echo off
if "%~1"=="" (
  echo Usage: %~nx0 doctor^|status^|repair^|update^|export-data^|import-data [options]
  pause
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LiveAvatar.ps1" -Command %*
if errorlevel 1 pause
