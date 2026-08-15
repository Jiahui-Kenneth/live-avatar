@echo off
rem ============================================================
rem  live-avatar - llama.cpp server launcher
rem
rem  Starts llama-server serving a Qwen3.5 9B GGUF on :8080.
rem
rem  Required env (set in start_all.bat or here):
rem    LLAMA_CPP_DIR   - llama.cpp build dir, e.g. C:\llama.cpp
rem    LLM_MODEL_GGUF  - path to the GGUF model file
rem  Optional:
rem    LLM_CTX_SIZE    - context window (default 8192)
rem    LLM_ALIAS       - model alias (default qwen3.5-9b)
rem ============================================================
@echo off
chcp 65001 > nul

if "%LLAMA_CPP_DIR%"=="" (
  echo [ERROR] LLAMA_CPP_DIR not set. Edit scripts\start_all.bat first.
  exit /b 1
)
if not exist "%LLAMA_CPP_DIR%\llama-server.exe" (
  echo [ERROR] llama-server.exe not found in %LLAMA_CPP_DIR%
  exit /b 1
)
if "%LLM_MODEL_GGUF%"=="" (
  echo [ERROR] LLM_MODEL_GGUF not set.
  exit /b 1
)

set LLM_CTX_SIZE=%LLM_CTX_SIZE: =%
if "%LLM_CTX_SIZE%"=="" set LLM_CTX_SIZE=8192
set LLM_ALIAS=%LLM_ALIAS: =%
if "%LLM_ALIAS%"=="" set LLM_ALIAS=qwen3.5-9b

cd /d "%LLAMA_CPP_DIR%"
echo Starting llama-server (%LLM_ALIAS%) on :8080 ...
start "llama-server" llama-server.exe ^
  -m "%LLM_MODEL_GGUF%" ^
  --host 127.0.0.1 --port 8080 ^
  --n-gpu-layers 999 ^
  --ctx-size %LLM_CTX_SIZE% ^
  --parallel 1 ^
  --reasoning off ^
  --jinja ^
  --alias "%LLM_ALIAS%"
