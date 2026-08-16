@echo off
rem ============================================================
rem  live-avatar - LiveTalking avatar launcher
rem
rem  Starts the lip-sync avatar server on :8010 (localhost only).
rem
rem  Required env:
rem    LIVETALKING_DIR - LiveTalking project root
rem  Optional:
rem    LT_PORT   - listen port (default 8010)
rem    LT_MODEL  - model (default wav2lip)
rem    LT_AVATAR - avatar id (default myavatar)
rem    LIVE_AVATAR_DATA_DIR - persistent avatar data root
rem ============================================================
@echo off
chcp 65001 > nul

if "%LIVETALKING_DIR%"=="" (
  echo [ERROR] LIVETALKING_DIR not set. Edit scripts\start_all.bat first.
  exit /b 1
)
if not exist "%LIVETALKING_DIR%\.venv\Scripts\python.exe" (
  echo [ERROR] LiveTalking venv not found at %LIVETALKING_DIR%\.venv
  exit /b 1
)

set LT_PORT=%LT_PORT: =%
if "%LT_PORT%"=="" set LT_PORT=8010
set LT_MODEL=%LT_MODEL: =%
if "%LT_MODEL%"=="" set LT_MODEL=wav2lip
set LT_AVATAR=%LT_AVATAR: =%
if "%LT_AVATAR%"=="" set LT_AVATAR=myavatar
set "LIVE_AVATAR_ROOT=%~dp0.."
if not defined LIVE_AVATAR_DATA_DIR set "LIVE_AVATAR_DATA_DIR=%LIVE_AVATAR_ROOT%\data"
if not defined DEMO_PORT set "DEMO_PORT=7860"
set "LIVE_AVATAR_ALLOWED_ORIGINS=http://127.0.0.1:%DEMO_PORT%,http://localhost:%DEMO_PORT%"
for /f "usebackq delims=" %%T in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure_avatar_security.ps1" -DataRoot "%LIVE_AVATAR_DATA_DIR%"`) do set "LIVE_AVATAR_ADMIN_TOKEN=%%T"
if not defined LIVE_AVATAR_ADMIN_TOKEN (
  echo [ERROR] Failed to initialize avatar management security.
  exit /b 1
)

set PYTHONPATH=%LIVETALKING_DIR%
cd /d "%LIVETALKING_DIR%"
start "livetalking" .venv\Scripts\python.exe app.py --transport webrtc --model %LT_MODEL% --avatar_id %LT_AVATAR% --listenport %LT_PORT% --listenhost 127.0.0.1
