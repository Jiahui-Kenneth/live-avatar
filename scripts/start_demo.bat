@echo off
rem ============================================================
rem  live-avatar - demo web page launcher
rem
rem  Serves the voice-conversation page with the digital-human
rem  background on :7860.
rem
rem  Required env:
rem    S2S_DIR  - s2s project root
rem  Optional:
rem    DEMO_PORT       - port (default 7860)
rem    SPEECH_TO_SPEECH_URL - backend WS URL (default ws://localhost:8765/v1/realtime)
rem ============================================================
@echo off
chcp 65001 > nul

if "%S2S_DIR%"=="" (
  echo [ERROR] S2S_DIR not set. Edit scripts\start_all.bat first.
  exit /b 1
)

set DEMO_PORT=%DEMO_PORT: =%
if "%DEMO_PORT%"=="" set DEMO_PORT=7860
if defined SPEECH_TO_SPEECH_URL set "SPEECH_TO_SPEECH_URL=%SPEECH_TO_SPEECH_URL: =%"
if not defined SPEECH_TO_SPEECH_URL set "SPEECH_TO_SPEECH_URL=ws://localhost:8765/v1/realtime"

set SPEECH_TO_SPEECH_URL=%SPEECH_TO_SPEECH_URL%

cd /d "%S2S_DIR%"
start "s2s-demo" .venv\Scripts\python.exe -m uvicorn demo.server:app --host 127.0.0.1 --port %DEMO_PORT%
