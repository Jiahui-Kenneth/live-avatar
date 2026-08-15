# Live Avatar Local Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and verify the article's four-service Live Avatar stack on this Windows workstation, with PyTorch 2.11.0 CUDA 12.8 as the sole compatibility substitution for the RTX 5090.

**Architecture:** Keep the integration repository at `E:\AI\AI-Girlfriend2` and place all upstream runtimes under ignored local directories. Each Python service receives its own Python 3.11 virtual environment; llama.cpp, s2s, the demo, and LiveTalking bind only to loopback and are verified independently before the end-to-end microphone test.

**Tech Stack:** Windows 11, Python 3.11.9, PyTorch 2.11.0 + CUDA 12.8, llama.cpp Windows CUDA, Qwen3.5-9B Q4_K_M GGUF, Hugging Face speech-to-speech at `656099a`, faster-whisper, Qwen3-TTS, LiveTalking, Wav2Lip, WebRTC.

## Global Constraints

- Working root is exactly `E:\AI\AI-Girlfriend2`.
- Preserve the installed Python 3.13 and 3.14 interpreters; all new environments must use `py -3.11`.
- Install `torch==2.11.0`, `torchvision==0.26.0`, and `torchaudio==2.11.0` from `https://download.pytorch.org/whl/cu128` in both virtual environments.
- Keep `speech-to-speech` at commit `656099a`.
- Use `Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` and keep `--reasoning off`, `--ctx-size 8192`, and `--parallel 1`.
- Keep faster-whisper language `zh` and use the repository's two integration patches unchanged.
- Bind ports 8080, 8765, 7860, and 8010 only to `127.0.0.1`.
- Do not silently substitute a model, commit, speech backend, avatar backend, port, or CPU fallback.
- Stop and report if a patch check fails, a required asset needs interactive login/CAPTCHA, or CUDA reports a capability other than `(12, 0)`.

---

## File and Directory Responsibilities

- Modify: `.gitignore` — excludes machine-local runtimes, downloads, models, and nested upstream repositories.
- Create: `scripts/config.local.bat` — ignored machine-local mapping used by the existing launch scripts.
- Create: `downloads/` — official installer and archive cache.
- Create: `runtime/Python311/` — Python 3.11.9 per-user installation.
- Create: `deps/llama.cpp/` — extracted llama.cpp Windows CUDA binaries.
- Create: `deps/speech-to-speech/` — fixed upstream checkout and its `.venv`.
- Create: `deps/LiveTalking/` — upstream checkout, its `.venv`, patched endpoint, model, and avatar.
- Create: `models/` — Qwen GGUF model.
- Create: `logs/` — redirected service output used during verification.

## Task 1: Prepare Local Directories and Python 3.11.9

**Files:**
- Modify: `.gitignore`
- Create: `downloads/`
- Create: `runtime/Python311/`
- Create: `deps/`
- Create: `models/`
- Create: `logs/`

**Interfaces:**
- Consumes: existing Windows Python Launcher and the official Python 3.11.9 installer URL.
- Produces: `py -3.11` and `E:\AI\AI-Girlfriend2\runtime\Python311\python.exe` for both downstream virtual environments.

- [ ] **Step 1: Record the preflight state**

Run:

```powershell
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
py -0p
[System.IO.DriveInfo]::new('E').AvailableFreeSpace / 1GB
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -In 8080,8765,7860,8010
```

Expected: RTX 5090 with about 32GB VRAM; more than 60GB free; no required port owned by an unrelated listener.

- [ ] **Step 2: Exclude local installation payloads from Git**

Append these exact entries to `.gitignore`:

```gitignore
# Local runtime payloads
/downloads/
/runtime/
/deps/
/models/
/logs/
```

Run:

```powershell
git diff --check
```

Expected: exit code 0.

- [ ] **Step 3: Create the installation directories**

Run:

```powershell
$root = 'E:\AI\AI-Girlfriend2'
'downloads','runtime','deps','models','logs' | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $root $_) | Out-Null }
```

Expected: all five directories exist under the working root.

- [ ] **Step 4: Download and install Python 3.11.9**

Run:

```powershell
$installer = 'E:\AI\AI-Girlfriend2\downloads\python-3.11.9-amd64.exe'
Invoke-WebRequest 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe' -OutFile $installer
$arguments = '/quiet InstallAllUsers=0 TargetDir="E:\AI\AI-Girlfriend2\runtime\Python311" Include_launcher=1 InstallLauncherAllUsers=0 PrependPath=1 Include_test=0'
$process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Python installer exited with $($process.ExitCode)" }
```

Expected: installer exits 0 without removing or changing the existing Python installations.

- [ ] **Step 5: Verify Python 3.11.9**

Run:

```powershell
py -3.11 --version
E:\AI\AI-Girlfriend2\runtime\Python311\python.exe --version
py -0p
```

Expected: both version checks print `Python 3.11.9`; the launcher still lists Python 3.13 and 3.14.

- [ ] **Step 6: Commit repository hygiene**

Run:

```powershell
git add .gitignore
git commit -m "chore: ignore local avatar runtimes"
```

Expected: one commit containing only `.gitignore`.

## Task 2: Install and Verify llama.cpp with Qwen3.5-9B

**Files:**
- Create: `deps/llama.cpp/`
- Create: `models/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf`
- Create: `logs/llama.stdout.log`
- Create: `logs/llama.stderr.log`

**Interfaces:**
- Consumes: official llama.cpp GitHub release assets and the exact Hugging Face Q4_K_M file.
- Produces: OpenAI-compatible LLM endpoint `http://127.0.0.1:8080/v1` and health endpoint `http://127.0.0.1:8080/health`.

- [ ] **Step 1: Record the locked official llama.cpp release assets**

Run:

```powershell
$llamaTag = 'b10437'
$llamaAsset = 'llama-b10437-bin-win-cuda-12.4-x64.zip'
$cudartAsset = 'cudart-llama-bin-win-cuda-12.4-x64.zip'
$release = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$llamaTag"
$names = $release.assets.name
if ($llamaAsset -notin $names -or $cudartAsset -notin $names) { throw 'Locked llama.cpp assets are not present in b10437' }
$release.tag_name
```

Expected: GitHub returns tag `b10437` and confirms both locked official assets exist.

- [ ] **Step 2: Download and extract llama.cpp**

Run:

```powershell
$downloadRoot = 'E:\AI\AI-Girlfriend2\downloads'
$llamaRoot = 'E:\AI\AI-Girlfriend2\deps\llama.cpp'
$binary = $release.assets | Where-Object name -EQ $llamaAsset
$runtime = $release.assets | Where-Object name -EQ $cudartAsset
$binaryZip = Join-Path $downloadRoot $llamaAsset
$runtimeZip = Join-Path $downloadRoot $cudartAsset
Invoke-WebRequest $binary.browser_download_url -OutFile $binaryZip
Invoke-WebRequest $runtime.browser_download_url -OutFile $runtimeZip
Expand-Archive -LiteralPath $binaryZip -DestinationPath $llamaRoot -Force
Expand-Archive -LiteralPath $runtimeZip -DestinationPath $llamaRoot -Force
Get-Item "$llamaRoot\llama-server.exe"
Get-Item "$llamaRoot\cudart64_12.dll"
```

Expected: `llama-server.exe` and the CUDA 12 runtime DLL exist at the configured root.

- [ ] **Step 3: Download the exact Q4_K_M GGUF with resume support**

Run:

```powershell
$modelUrl = 'https://huggingface.co/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive/resolve/main/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf?download=true'
$modelPath = 'E:\AI\AI-Girlfriend2\models\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
curl.exe -L --fail --retry 5 --retry-delay 5 -C - -o $modelPath $modelUrl
Get-Item $modelPath | Select-Object FullName,Length
```

Expected: file exists and is approximately 5.63GB.

- [ ] **Step 4: Start llama-server for isolated verification**

Run:

```powershell
$llama = 'E:\AI\AI-Girlfriend2\deps\llama.cpp\llama-server.exe'
$model = 'E:\AI\AI-Girlfriend2\models\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
$args = @('-m',$model,'--host','127.0.0.1','--port','8080','--n-gpu-layers','999','--ctx-size','8192','--parallel','1','--reasoning','off','--alias','qwen3.5-9b')
$llamaProcess = Start-Process $llama -ArgumentList $args -RedirectStandardOutput 'E:\AI\AI-Girlfriend2\logs\llama.stdout.log' -RedirectStandardError 'E:\AI\AI-Girlfriend2\logs\llama.stderr.log' -PassThru -WindowStyle Hidden
```

Expected: process remains running while the model loads.

- [ ] **Step 5: Verify health and a Chinese completion**

Run after health becomes ready:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8080/health'
$body = @{ model='qwen3.5-9b'; messages=@(@{role='user';content='请只回答：你好'}); max_tokens=32 } | ConvertTo-Json -Depth 5
$reply = Invoke-RestMethod 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body
$reply.choices[0].message.content
```

Expected: health status is `ok`; content is non-empty Chinese text rather than an empty reasoning-only field.

- [ ] **Step 6: Stop only the isolated test process**

Run:

```powershell
Stop-Process -Id $llamaProcess.Id
```

Expected: only the PID started in Step 4 stops and port 8080 becomes free.

## Task 3: Install and Patch speech-to-speech

**Files:**
- Create: `deps/speech-to-speech/`
- Modify in upstream checkout: files listed by `patches/s2s-integration.patch`

**Interfaces:**
- Consumes: Python 3.11.9, PyTorch cu128, llama.cpp endpoint, and `patches/s2s-integration.patch`.
- Produces: s2s backend on `ws://127.0.0.1:8765/v1/realtime` and demo application importable as `demo.server:app`.

- [ ] **Step 1: Clone and pin the upstream repository**

Run:

```powershell
git clone https://github.com/huggingface/speech-to-speech.git 'E:\AI\AI-Girlfriend2\deps\speech-to-speech'
git -C 'E:\AI\AI-Girlfriend2\deps\speech-to-speech' checkout 656099a
git -C 'E:\AI\AI-Girlfriend2\deps\speech-to-speech' rev-parse HEAD
```

Expected: HEAD starts with `656099a` and the worktree is clean.

- [ ] **Step 2: Create the Python 3.11 virtual environment**

Run:

```powershell
py -3.11 -m venv 'E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv'
E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe --version
```

Expected: `Python 3.11.9`.

- [ ] **Step 3: Install the article's development dependencies**

Run:

```powershell
$python = 'E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe'
& $python -m pip install --upgrade pip
& $python -m pip install -e 'E:\AI\AI-Girlfriend2\deps\speech-to-speech[dev]' -i 'https://mirrors.aliyun.com/pypi/simple/'
```

Expected: pip exits 0 and `python -m speech_to_speech.s2s_pipeline --help` is importable.

- [ ] **Step 4: Force the approved CUDA 12.8 PyTorch build**

Run:

```powershell
$python = 'E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe'
& $python -m pip install --upgrade --force-reinstall torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url 'https://download.pytorch.org/whl/cu128'
& $python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0)); print((torch.ones(1, device='cuda') * 2).item())"
```

Expected: versions include `2.11.0` and CUDA `12.8`; GPU is RTX 5090; capability is `(12, 0)`; result is `2.0`.

- [ ] **Step 5: Preflight and apply the s2s patch**

Run:

```powershell
$s2s = 'E:\AI\AI-Girlfriend2\deps\speech-to-speech'
$patch = 'E:\AI\AI-Girlfriend2\patches\s2s-integration.patch'
git -C $s2s apply --check $patch
git -C $s2s apply $patch
git -C $s2s status --short
```

Expected: check and apply exit 0; status lists only the intended patched files.

- [ ] **Step 6: Verify the patched CLI surface**

Run:

```powershell
$python = 'E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe'
& $python -m speech_to_speech.s2s_pipeline --help | Select-String 'faster_whisper_stt_gen_language|qwen3_tts_backend'
```

Expected: both options appear in help output.

## Task 4: Install, Patch, and Provision LiveTalking

**Files:**
- Create: `deps/LiveTalking/`
- Create: `deps/LiveTalking/models/wav2lip.pth`
- Create: `deps/LiveTalking/data/avatars/myavatar/`
- Modify in upstream checkout: files listed by `patches/livetalking-integration.patch`
- Create: `deps/LiveTalking/web/embed.html`

**Interfaces:**
- Consumes: Python 3.11.9, PyTorch cu128, official Wav2Lip resources, and `patches/livetalking-integration.patch`.
- Produces: LiveTalking HTTP/WebRTC service on `http://127.0.0.1:8010` with `/humanpcm`.

- [ ] **Step 1: Clone LiveTalking from the article's Gitee source**

Run:

```powershell
git clone https://gitee.com/lipku/LiveTalking.git 'E:\AI\AI-Girlfriend2\deps\LiveTalking'
git -C 'E:\AI\AI-Girlfriend2\deps\LiveTalking' status --short --branch
```

Expected: clean checkout on the upstream default branch.

- [ ] **Step 2: Create the Python 3.11 environment and install cu128 PyTorch**

Run:

```powershell
py -3.11 -m venv 'E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv'
$python = 'E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe'
& $python -m pip install --upgrade pip
& $python -m pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url 'https://download.pytorch.org/whl/cu128'
& $python --version
```

Expected: Python 3.11.9 and pip exits 0.

- [ ] **Step 3: Install LiveTalking requirements without losing cu128**

Run:

```powershell
$python = 'E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe'
& $python -m pip install -r 'E:\AI\AI-Girlfriend2\deps\LiveTalking\requirements.txt' -i 'https://mirrors.aliyun.com/pypi/simple/'
& $python -m pip install --upgrade --force-reinstall torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url 'https://download.pytorch.org/whl/cu128'
& $python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0)); print((torch.ones(1, device='cuda') * 2).item())"
```

Expected: PyTorch is 2.11.0 cu128, capability `(12, 0)`, and CUDA tensor result `2.0`.

- [ ] **Step 4: Obtain the two official Wav2Lip resources**

Open the official LiveTalking model share `https://pan.quark.cn/s/83a750323ef0` or the official Google Drive folder `https://drive.google.com/drive/folders/1FOC_MD6wdogyyX_7V1d4NDIO7P9NlSAJ?usp=sharing`. Download exactly:

```text
wav2lip256.pth
wav2lip256_avatar1.tar.gz
```

Expected: both files are present in `E:\AI\AI-Girlfriend2\downloads`. If the site requests login, CAPTCHA, or download-client installation, pause for user action rather than using an unofficial mirror.

- [ ] **Step 5: Place and validate the Wav2Lip resources**

Run:

```powershell
Copy-Item 'E:\AI\AI-Girlfriend2\downloads\wav2lip256.pth' 'E:\AI\AI-Girlfriend2\deps\LiveTalking\models\wav2lip.pth'
tar -xf 'E:\AI\AI-Girlfriend2\downloads\wav2lip256_avatar1.tar.gz' -C 'E:\AI\AI-Girlfriend2\deps\LiveTalking\data\avatars'
Rename-Item 'E:\AI\AI-Girlfriend2\deps\LiveTalking\data\avatars\wav2lip256_avatar1' 'myavatar'
Get-Item 'E:\AI\AI-Girlfriend2\deps\LiveTalking\models\wav2lip.pth'
Get-ChildItem 'E:\AI\AI-Girlfriend2\deps\LiveTalking\data\avatars\myavatar' | Select-Object -First 5
```

Expected: the model file is non-empty and the `myavatar` directory contains the extracted avatar frames and metadata.

- [ ] **Step 6: Preflight and apply the LiveTalking patch**

Run:

```powershell
$liveTalking = 'E:\AI\AI-Girlfriend2\deps\LiveTalking'
$patch = 'E:\AI\AI-Girlfriend2\patches\livetalking-integration.patch'
git -C $liveTalking apply --check $patch
git -C $liveTalking apply $patch
Copy-Item 'E:\AI\AI-Girlfriend2\web\embed.html' "$liveTalking\web\embed.html" -Force
git -C $liveTalking status --short
```

Expected: check and apply exit 0; status lists only the intended patched files plus `web/embed.html`.

- [ ] **Step 7: Verify the patched command and route source**

Run:

```powershell
$python = 'E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe'
& $python 'E:\AI\AI-Girlfriend2\deps\LiveTalking\app.py' --help | Select-String 'listenhost'
Select-String -Path 'E:\AI\AI-Girlfriend2\deps\LiveTalking\server\routes.py' -Pattern 'humanpcm'
```

Expected: `listenhost` and `humanpcm` are both found.

## Task 5: Configure and Validate the Existing Launch Scripts

**Files:**
- Create: `scripts/config.local.bat`
- Inspect: `scripts/start_llama.bat`
- Inspect: `scripts/start_s2s.bat`
- Inspect: `scripts/start_livetalking.bat`
- Inspect: `scripts/start_demo.bat`

**Interfaces:**
- Consumes: all installed component directories and the exact model file.
- Produces: one machine-local configuration consumed by `scripts/start_all.bat`.

- [ ] **Step 1: Create the exact local configuration**

Create `scripts/config.local.bat` with:

```bat
@echo off
set "S2S_DIR=E:\AI\AI-Girlfriend2\deps\speech-to-speech"
set "LIVETALKING_DIR=E:\AI\AI-Girlfriend2\deps\LiveTalking"
set "LLAMA_CPP_DIR=E:\AI\AI-Girlfriend2\deps\llama.cpp"
set "LLM_MODEL_GGUF=E:\AI\AI-Girlfriend2\models\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
set "LLM_CTX_SIZE=8192"
set "LLM_ALIAS=qwen3.5-9b"
set "LLM_URL=http://127.0.0.1:8080/v1"
set "LLM_MODEL_NAME=qwen3.5-9b"
set "STT_LANG=zh"
set "DEMO_PORT=7860"
set "LT_PORT=8010"
set "LT_MODEL=wav2lip"
set "LT_AVATAR=myavatar"
```

Expected: file is ignored by Git and contains no external secrets.

- [ ] **Step 2: Validate every configured path and critical flag**

Run:

```powershell
$required = @(
  'E:\AI\AI-Girlfriend2\deps\llama.cpp\llama-server.exe',
  'E:\AI\AI-Girlfriend2\models\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf',
  'E:\AI\AI-Girlfriend2\deps\speech-to-speech\.venv\Scripts\python.exe',
  'E:\AI\AI-Girlfriend2\deps\LiveTalking\.venv\Scripts\python.exe',
  'E:\AI\AI-Girlfriend2\deps\LiveTalking\models\wav2lip.pth',
  'E:\AI\AI-Girlfriend2\deps\LiveTalking\data\avatars\myavatar',
  'E:\AI\AI-Girlfriend2\deps\LiveTalking\web\embed.html'
)
$missing = $required | Where-Object { -not (Test-Path -LiteralPath $_) }
if ($missing) { throw "Missing paths: $($missing -join ', ')" }
Select-String -Path 'scripts\start_llama.bat' -Pattern '--reasoning off','--ctx-size','--parallel 1'
Select-String -Path 'scripts\start_s2s.bat' -Pattern 'faster_whisper_stt_gen_language','STT_LANG=zh','qwen3_tts_device cuda'
Select-String -Path 'scripts\start_livetalking.bat' -Pattern '--listenhost 127.0.0.1'
git check-ignore 'scripts/config.local.bat'
```

Expected: no missing paths; every critical flag matches; Git reports the local config as ignored.

## Task 6: Start and Verify the Four Services

**Files:**
- Create: runtime logs under `logs/` and upstream component directories.

**Interfaces:**
- Consumes: `scripts/config.local.bat` and all provisioned components.
- Produces: healthy listeners on 8080, 8010, 8765, and 7860.

- [ ] **Step 1: Confirm the ports are free immediately before launch**

Run:

```powershell
$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -In 8080,8765,7860,8010
if ($listeners) { $listeners | Format-Table LocalAddress,LocalPort,OwningProcess; throw 'Required port already in use' }
```

Expected: no listener is returned.

- [ ] **Step 2: Start all services with the repository launcher**

Run:

```powershell
cmd.exe /c 'E:\AI\AI-Girlfriend2\scripts\start_all.bat'
```

Expected: four service windows launch in dependency order. Initial model downloads and loading may take several minutes.

- [ ] **Step 3: Poll the four listeners without hiding failures**

Run:

```powershell
$deadline = (Get-Date).AddMinutes(15)
do {
  $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -In 8080,8765,7860,8010 | Select-Object -ExpandProperty LocalPort -Unique
  if (@($ports).Count -eq 4) { break }
  Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)
if (@($ports).Count -ne 4) { throw "Listeners not ready: $($ports -join ', ')" }
$ports | Sort-Object
```

Expected: 7860, 8010, 8080, and 8765 are listed.

- [ ] **Step 4: Verify HTTP surfaces and active GPU processes**

Run:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8080/health'
(Invoke-WebRequest 'http://127.0.0.1:8010/embed.html').StatusCode
(Invoke-WebRequest 'http://127.0.0.1:7860').StatusCode
nvidia-smi
```

Expected: llama health is `ok`; both web pages return HTTP 200; NVIDIA reports llama.cpp and Python GPU processes without out-of-memory errors.

- [ ] **Step 5: Verify the LiveTalking session endpoint after opening the page**

Run:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8010/api/admin/sessions'
```

Expected: the endpoint responds successfully; after the embedded page connects it reports an active session ID used by `/humanpcm`.

## Task 7: Perform the End-to-End Chinese Voice and Lip-Sync Test

**Files:**
- Inspect: service logs and browser-visible output; no tracked repository files change.

**Interfaces:**
- Consumes: microphone input and the four healthy services.
- Produces: verified Chinese STT, Chinese LLM response, single TTS playback, and synchronized Wav2Lip animation.

- [ ] **Step 1: Open the local demo and allow microphone access**

Open `http://127.0.0.1:7860`, wait for the avatar background, and approve microphone access only for this localhost page.

Expected: central voice control and LiveTalking avatar are both visible.

- [ ] **Step 2: Submit a deterministic Chinese utterance**

Say: `你好，请只用中文告诉我今天心情怎么样。`

Expected: faster-whisper transcribes Chinese instead of English and the LLM response is non-empty Chinese.

- [ ] **Step 3: Verify audio and lip synchronization**

Observe one complete response.

Expected: exactly one Chinese audio stream plays; the avatar mouth moves while the response plays and returns to its idle closed-mouth loop afterward.

- [ ] **Step 4: Capture diagnostic state**

Run:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8010/api/admin/sessions'
Get-NetTCPConnection -State Listen | Where-Object LocalPort -In 8080,8765,7860,8010 | Sort-Object LocalPort | Format-Table LocalAddress,LocalPort,OwningProcess
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
git status --short
```

Expected: one active avatar session; four loopback listeners; GPU processes present; tracked repository worktree clean after the `.gitignore` commit.

- [ ] **Step 5: Record completion**

Report the installed paths, exact Python/PyTorch/CUDA versions, llama.cpp release tag, model filename, all four endpoint checks, and the four end-to-end acceptance results. Do not claim success unless all four acceptance results pass.
