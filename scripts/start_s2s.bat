@echo off
rem ============================================================
rem  live-avatar - s2s backend launcher
rem
rem  Starts the speech-to-speech pipeline (VAD+STT+LLM+TTS) on :8765.
rem  The LLM talks to llama.cpp (:8080), audio is forwarded to the
rem  LiveTalking avatar (:8010) for lip-sync.
rem
rem  Required env:
rem    S2S_DIR     - s2s project root (where .venv and src live)
rem  Optional:
rem    LIVETALKING_URL   - avatar endpoint (default http://127.0.0.1:8010)
rem    LLM_URL           - llama.cpp OpenAI-compatible URL (default http://127.0.0.1:8080/v1)
rem    LLM_MODEL_NAME    - model alias (default qwen3.5-9b)
rem ============================================================
@echo off
chcp 65001 > nul

if "%S2S_DIR%"=="" (
  echo [ERROR] S2S_DIR not set. Edit scripts\start_all.bat first.
  exit /b 1
)
if not exist "%S2S_DIR%\.venv\Scripts\python.exe" (
  echo [ERROR] s2s venv not found at %S2S_DIR%\.venv
  exit /b 1
)

if defined LIVETALKING_URL set "LIVETALKING_URL=%LIVETALKING_URL: =%"
if not defined LIVETALKING_URL set "LIVETALKING_URL=http://127.0.0.1:8010"
set LLM_URL=%LLM_URL: =%
if "%LLM_URL%"=="" set LLM_URL=http://127.0.0.1:8080/v1
set LLM_MODEL_NAME=%LLM_MODEL_NAME: =%
if "%LLM_MODEL_NAME%"=="" set LLM_MODEL_NAME=qwen3.5-9b
set STT_LANG=%STT_LANG: =%
if "%STT_LANG%"=="" set STT_LANG=zh

set HF_ENDPOINT=https://hf-mirror.com
set LIVETALKING_URL=%LIVETALKING_URL%

cd /d "%S2S_DIR%"
start "s2s-backend" .venv\Scripts\python.exe -u -m speech_to_speech.s2s_pipeline ^
  --mode realtime ^
  --stt faster-whisper ^
  --llm_backend chat-completions ^
  --tts qwen3 ^
  --model_name "%LLM_MODEL_NAME%" ^
  --responses_api_base_url "%LLM_URL%" ^
  --responses_api_api_key "dummy" ^
  --language %STT_LANG% ^
  --faster_whisper_stt_model_name "base" ^
  --faster_whisper_stt_device "cuda" ^
  --faster_whisper_stt_compute_type "float16" ^
  --faster_whisper_stt_gen_language "%STT_LANG%" ^
  --qwen3_tts_backend torch ^
  --qwen3_tts_device cuda ^
  --thresh 0.8 ^
  --min_silence_ms 600 ^
  --min_speech_ms 500 ^
  --log_level INFO
