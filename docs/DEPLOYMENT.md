# 部署教程 — Live Avatar

> 本文档从零开始，带你在一台 **Windows + NVIDIA GPU** 的机器上部署完整的中文语音对话数字人。

## 目录

1. [硬件与系统要求](#1-硬件与系统要求)
2. [总览](#2-总览)
3. [安装依赖组件](#3-安装依赖组件)
4. [应用集成补丁](#4-应用集成补丁)
5. [配置启动脚本](#5-配置启动脚本)
6. [启动与验证](#6-启动与验证)
7. [常见问题与注意事项](#7-常见问题与注意事项)
8. [自研组件详解](#8-自研组件详解)

---

## 1. 硬件与系统要求

| 项目 | 要求 | 说明 |
|------|------|------|
| OS | Windows 10/11 64 位 | 本教程以 Windows 为准 |
| GPU | **NVIDIA，16GB 显存** | RTX 4070 Ti / 4080 / 5060 Ti 等 |
| 驱动 | 最新 NVIDIA 驱动 | 需支持 CUDA 12.x |
| CUDA | 12.1+ | 与 PyTorch 版本匹配 |
| 内存 | 32GB 推荐 | 多个模型常驻 |
| 磁盘 | 至少 60GB 空闲 | 模型权重 + 依赖 |
| 网络 | 能访问 GitHub / HF / 国内镜像 | 见注意事项 |

**显存分配参考**（三个服务同时运行，实测 16GB 满载）：

| 服务 | 显存占用 |
|------|----------|
| llama-server (Qwen3.5-9B Q4) | ~7 GB |
| s2s (whisper + Qwen3-TTS) | ~3 GB |
| LiveTalking (wav2lip) | ~4 GB |

---

## 2. 总览

整套系统由 **4 个独立服务** 组成，需要分别安装、依次启动：

```
[llama-server]  :8080   本地 LLM（Qwen3.5-9B，llama.cpp）
     │  提供 OpenAI 兼容接口 /v1/chat/completions
     ▼
[s2s backend]   :8765   语音对话管线（VAD→STT→LLM→TTS）
     │  把 TTS 音频转发给数字人做口型同步与浏览器播放
     ├────────────────────────────┐
     ▼                            ▼
[s2s demo]      :7860   [LiveTalking]  :8010
网页 UI（数字人全屏背景）   数字人 wav2lip 口型同步
```

**对话流程**：你对页面说话 → whisper 转写中文 → llama.cpp 生成中文回复 → Qwen3-TTS 合成语音 → 音频推给 LiveTalking → 浏览器播放数字人的 WebRTC 音轨，口型同步跟随。

---

## 3. 安装依赖组件

按顺序安装以下 4 个组件。每个都验证能独立运行后再进入下一步。

### 3.1 Python 3.11

本项目组件要求 Python 3.10+，实测 3.11.9 稳定。

```bat
rem 从 https://www.python.org/downloads/ 下载安装 3.11.x
rem 安装时勾选 "Add Python to PATH"
```

### 3.2 llama.cpp（本地 LLM 推理）

```bat
rem 1. 从 GitHub Release 下载 Windows CUDA 版本：
rem    https://github.com/ggml-org/llama.cpp/releases
rem    下载 "llama-bxxxx-bin-win-cuda-cu12.2-x64.zip"
rem 2. 解压到 C:\llama.cpp（确保里面有 llama-server.exe）
```

**下载模型权重**（约 5.2GB）：

| 模型 | 说明 |
|------|------|
| `Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | 中文对话模型，Q4 量化，无审查约束 |

> 模型请从 Hugging Face 搜索下载（模型名见上表），或替换为你自己的中文 GGUF 模型。

**验证 llama.cpp 独立运行**：

```bat
cd C:\llama.cpp
llama-server.exe -m "C:\llama.cpp\models\你的模型.gguf" ^
  --host 127.0.0.1 --port 8080 ^
  --n-gpu-layers 999 --ctx-size 8192 --parallel 1 ^
  --reasoning off --alias qwen3.5-9b
```

浏览器打开 <http://127.0.0.1:8080/health> 看到 `{"status":"ok"}` 即成功。

> **⚠️ 关键**：必须加 `--reasoning off`。否则模型输出的 `<think>` 推理内容会占用 `reasoning_content` 字段，而 `content` 为空，s2s 拿不到实际回复文本。

### 3.3 speech-to-speech（语音对话管线）

```bat
rem 1. 安装 git for windows（https://git-scm.com/）
rem 2. 克隆仓库并切换到集成 patch 对应的版本：
git clone https://github.com/huggingface/speech-to-speech.git C:\s2s
cd C:\s2s
git checkout 656099a
rem 3. 创建虚拟环境（用 3.11）：
py -3.11 -m venv .venv
.venv\Scripts\activate
rem 4. 安装依赖（用国内镜像加速）：
pip install -e ".[dev]" -i https://mirrors.aliyun.com/pypi/simple/
```

> 首次安装会自动下载 whisper / TTS 模型到 `~/.cache`。国内网络慢的话，设置 `HF_ENDPOINT=https://hf-mirror.com`。

### 3.4 LiveTalking（数字人）

```bat
git clone https://gitee.com/lipku/LiveTalking.git C:\LiveTalking
cd C:\LiveTalking
py -3.11 -m venv .venv
.venv\Scripts\activate
pip install torch --index-url https://download.pytorch.org/whl/cu121
pip install -r requirements.txt
```

**下载数字人模型**（从 LiveTalking README 的网盘链接）：

1. `wav2lip256.pth` → 放入 `C:\LiveTalking\models\`，重命名为 `wav2lip.pth`
2. `wav2lip256_avatar1.tar.gz` → 解压后整个文件夹放入 `C:\LiveTalking\data\avatars\`，重命名为 `myavatar`

**验证独立运行**：

```bat
cd C:\LiveTalking
.venv\Scripts\python.exe app.py --transport webrtc --model wav2lip ^
  --avatar_id myavatar --listenport 8010 --listenhost 127.0.0.1
```

浏览器打开 <http://127.0.0.1:8010/index.html> 能看到数字人即成功。

---

## 4. 应用集成补丁

两个上游项目需要打上本仓库提供的集成补丁。

### 4.1 s2s 补丁（转发桥 + 中文 STT + 网页集成）

```bat
cd C:\s2s
rem 确保工作树干净（.venv 目录除外，它已被 gitignore）
git apply C:\live-avatar\patches\s2s-integration.patch
```

该补丁修改了这些文件：

| 文件 | 改动内容 |
|------|----------|
| `src/.../api/openai_realtime/websocket_router.py` | **新增音频转发桥**：把 TTS 音频通过 `LIVETALKING_URL` 环境变量转发给数字人 |
| `src/.../STT/faster_whisper_handler.py` | 支持中文字符（去除默认英文干扰） |
| `src/.../TTS/qwen3_tts_handler.py` | Qwen3-TTS 本地 torch 后端微调 |
| `src/.../VAD/vad_handler.py` | 静音/语音阈值优化 |
| `demo/index.html`, `style.css` | 嵌入数字人 iframe，全屏背景布局 |
| `demo/server.py`, `ws/s2s-ws-client.js`, `ui/chat.js` | 前端 WS 连接与转发配置 |

### 4.2 LiveTalking 补丁（/humanpcm 流式接口 + 本机监听）

```bat
cd C:\LiveTalking
git apply C:\live-avatar\patches\livetalking-integration.patch
```

| 文件 | 改动内容 |
|------|----------|
| `server/routes.py` | **新增 `/humanpcm` 路由**：接收裸 int16 PCM 流，按 20ms 切块驱动口型 |
| `app.py`, `config.py` | 新增 `--listenhost` 参数（本机监听安全加固） |

**放置自研嵌入页**：

```bat
copy C:\live-avatar\web\embed.html C:\LiveTalking\web\embed.html
```

`embed.html` 是数字人全屏背景嵌入页（自动 WebRTC 连接、断线自动重连、不重复播放音频）。

---

## 5. 配置启动脚本

复制本机配置模板，再填写你机器上的实际路径：

```bat
copy scripts\config.local.bat.example scripts\config.local.bat
notepad scripts\config.local.bat
```

在 `config.local.bat` 中填写：

```bat
set "S2S_DIR=C:\s2s"                        @ 你的 speech-to-speech 目录
set "LIVETALKING_DIR=C:\LiveTalking"        @ 你的 LiveTalking 目录
set "LLAMA_CPP_DIR=C:\llama.cpp"            @ llama.cpp 解压目录
set "LLM_MODEL_GGUF=C:\llama.cpp\models\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
```

可选配置（有默认值，按需取消注释修改）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LLM_CTX_SIZE` | `8192` | LLM 上下文长度 |
| `LLM_ALIAS` | `qwen3.5-9b` | LLM 模型别名 |
| `STT_LANG` | `zh` | STT 语言（改 `en` 则识别英文） |
| `DEMO_PORT` | `7860` | 网页端口 |
| `LT_PORT` | `8010` | 数字人端口 |
| `LIVE_AVATAR_DATA_DIR` | `<仓库>\data` | 自定义头像、当前选择和安全令牌的持久化目录 |

> **⚠️ STT 语言注意**：s2s 的 faster-whisper 默认按英文识别。必须传 `--faster_whisper_stt_gen_language zh`，否则你说中文会被强行按英文转写（输出变成英文句子），LLM 也会回复英文。`start_s2s.bat` 已默认带上 `STT_LANG=zh`。若想中英文都支持，把 `STT_LANG` 改为 `auto`。

---

## 6. 启动与验证

### 6.1 一键启动

```bat
cd C:\live-avatar\scripts
start_all.bat
```

脚本会依次启动 4 个服务（各开一个窗口）。

### 6.2 确认服务就绪

```bat
rem 分别检查 4 个端口：
netstat -ano | findstr ":8080 :8765 :7860 :8010"
```

| 端口 | 服务 | 验证 URL |
|------|------|----------|
| 8080 | llama-server | <http://127.0.0.1:8080/health> → `{"status":"ok"}` |
| 8765 | s2s 后端 | 稍候在浏览器页面看是否连接成功 |
| 7860 | 网页 UI | <http://127.0.0.1:7860> |
| 8010 | LiveTalking | <http://127.0.0.1:8010/embed.html> |

> 首次启动 GPU 显存满载，等 30-60 秒让所有模型加载完。llama-server 就绪最快，LiveTalking 的 wav2lip 最慢。

### 6.3 开始对话

1. 打开 <http://127.0.0.1:7860>
2. 等待页面中央圆球出现、数字人画面加载为全屏背景
3. 点击圆球（或直接说话）
4. 说中文 → 听到中文回复 → 观察数字人口型跟随

### 6.4 验证口型链路（排障用）

如果说话有声音但数字人嘴不动，检查转发是否命中活跃会话：

```bat
rem 查看当前数字人活跃会话：
curl http://127.0.0.1:8010/api/admin/sessions
rem 查看 s2s 转发日志是否指向同一个 sessionid：
findstr "humanpcm" C:\s2s\s2s_err.log
```

### 6.5 上传和切换静态图片头像

1. 打开 <http://127.0.0.1:7860>，进入右上角“设置”。
2. 在“数字人头像”区域选择一张 JPEG、PNG 或 WebP 图片，文件最大 10 MiB。
3. 拖动图片并使用缩放滑块，使裁剪框中只保留一个清晰、正面的脸。裁剪输出固定为 576×768（3:4）。
4. 填写名称，点击“生成并切换”。界面会依次显示提交、人脸检查、Wav2Lip 生成和 WebRTC 切换进度。
5. 已生成头像会保留在列表中，可以随时切换。当前使用中的头像、内置头像不能删除。

自定义头像默认保存在 `<仓库>\data\avatars`；当前选择保存在 `<仓库>\data\config\active-avatar.json`。设置 `LIVE_AVATAR_DATA_DIR` 可以把这两部分放到独立数据盘，升级或重新克隆上游项目时不会丢失。服务器只保存裁剪后的生成资源和 SHA-256 摘要，任务结束后会删除临时上传文件与中间视频。

头像管理接口只监听本机，并由启动脚本生成的管理员令牌保护。网页只会拿到有效期 5 分钟、绑定页面来源的短期能力值，不会拿到管理员令牌或数据目录。不要把 8010、7860 端口直接暴露到公网。

---

## 7. 常见问题与注意事项

### 7.1 声音重复两遍

**原因**：LiveTalking 通过 WebRTC 音频轨道把合成语音回传给浏览器，而 s2s demo 页面本身也在播放 TTS 声音，两路叠加。

**解决**：确保使用本仓库的 `web/embed.html`。s2s demo 会静音自身播放，数字人的 WebRTC 音频轨道是唯一的浏览器声音来源。

### 7.2 数字人口型不动（但视频在动）

**原因**：s2s 转发桥缓存的数字人 sessionid 过期（比如页面刷新后 iframe 重连产生了新会话），音频发往了已销毁的旧会话。

**解决**：补丁已修复——转发前校验会话、业务错误时自动重新发现、2 秒 TTL。若仍异常，重启 s2s 或刷新页面重新建立连接。

### 7.3 LLM 回复为空 / 只有思考内容

**原因**：llama-server 未加 `--reasoning off`。

**解决**：见 3.2 节，必须带上该参数。

### 7.4 说中文但识别成英文 / 回复英文

**原因**：faster-whisper 语言默认 `en`，中文被强行按英文转写。

**解决**：`start_s2s.bat` 中 `STT_LANG=zh`（默认已设置）。

### 7.5 显存不足 / CUDA out of memory

- 确保模型为 Q4 量化（GGUF Q4_K_M）
- 先启动 llama-server，再启动其他服务，观察占用
- 可把 whisper 的 `--faster_whisper_stt_compute_type` 从 `float16` 改为 `int8` 省显存
- 减少 `--ctx-size`（4096）或 `--parallel 1`

### 7.6 国内网络下载慢

- pip 用阿里云镜像：`-i https://mirrors.aliyun.com/pypi/simple/`
- Hugging Face 模型设置 `HF_ENDPOINT=https://hf-mirror.com`
- llama.cpp 用 GitHub 直链或国内镜像

### 7.7 首次启动白屏 / 数字人不加载

- 等待模型加载（LiveTalking wav2lip 加载需 30 秒+）
- 确认 LiveTalking 在 `127.0.0.1:8010` 可访问
- 浏览器刷新页面（iframe 会自动重连）

### 7.8 安全提示

- 所有服务默认只监听 `127.0.0.1`（本机）。LiveTalking 的 `--listenhost 127.0.0.1` 是补丁新增的参数，防止暴露到局域网。
- 生产环境建议放在内网或加反向代理认证。

### 7.9 双实例问题（端口被占）

如果 s2s 日志混乱或端口冲突，可能启动了多个实例。用 `netstat -ano | findstr :8765` 找到 PID，用任务管理器结束多余进程后重启。

### 7.10 上传音色后仍是男声

默认的 `Qwen3-TTS-12Hz-1.7B-CustomVoice` 只支持内置 speaker；上传 WAV 不会克隆音色，且默认 `Aiden` 是男声。

- 只想使用内置女声：在网页设置中选择 `Serena`、`Sohee` 或 `Vivian`，保存并重新开始对话。
- 要使用上传的样音：下载 `Qwen/Qwen3-TTS-12Hz-1.7B-Base`，并为 s2s 增加 `--qwen3_tts_model_name`、`--qwen3_tts_ref_audio`。Base 模型支持语音克隆；提供准确样音文稿可获得更好的效果，也可用 `--qwen3_tts_xvec_only` 免文稿但效果略弱。

### 7.11 Wav2Lip 启动后口型线程崩溃

本集成使用的 v2 Wav2Lip 权重不能直接接收默认的 96×96 avatar 人脸裁剪；推理输入必须在 `wav2lip_avatar.py` 中 resize 到 **256×256**。256 是该 v2 网络 encoder/decoder skip connection 都匹配的尺寸；不要改用 384，也不要切换到仓库内不匹配的 v1 架构。

### 7.12 图片头像生成失败或效果不自然

- 只使用单人、正脸、五官无遮挡、光线均匀的图片；多人、侧脸或脸部太小会被拒绝。
- 生成接口需要 576×768 输入。网页裁剪器会自动输出该尺寸，不要绕过设置页直接提交任意分辨率图片。
- 静态图片只能驱动嘴部区域，头发、肩膀和姿势不会自然摆动；想要更自然的整体动作，应改用嘴巴闭合、头部运动轻微的短视频制作头像。
- 生成时会占用 GPU，通常需要几十秒；不要重复点击。完成前原有头像和语音会话保持可用。

### 7.13 轮换头像管理令牌

令牌位于 `%LIVE_AVATAR_DATA_DIR%\config\avatar-admin-token.txt`，不要复制到日志、截图或版本库。轮换步骤：先关闭 demo 和 LiveTalking，删除这个令牌文件，再重新运行 `start_all.bat`；启动脚本会原子生成新令牌。轮换会让旧网页中的短期能力立即失效，需要刷新页面并重新建立数字人会话。

---

## 8. 自研组件详解

| 文件 | 说明 |
|------|------|
| `scripts/start_llama.bat` | llama-server 启动（含 `--reasoning off` 关键参数） |
| `scripts/start_s2s.bat` | 语音管线启动（含中文 STT、转发桥环境变量） |
| `scripts/start_demo.bat` | 网页服务 |
| `scripts/start_livetalking.bat` | 数字人服务（本机监听） |
| `scripts/start_all.bat` | 一键启动，读取本机配置 |
| `scripts/config.local.bat.example` | 本机路径配置模板；复制为 `config.local.bat` 后填写 |
| `patches/s2s-integration.patch` | s2s 集成改动（转发桥、网页集成、中文优化） |
| `patches/livetalking-integration.patch` | LiveTalking 改动（`/humanpcm` 接口、监听加固） |
| `web/embed.html` | 数字人全屏背景嵌入页 |
| `scripts/ensure_avatar_security.ps1` | 原子创建共享头像管理令牌 |

### 图片头像管理安全边界

- LiveTalking 提供创建任务、查询进度、列出、激活、删除和关闭指定 WebRTC 会话的本机接口。
- demo 使用管理员令牌签发短期 HMAC 能力，能力绑定精确页面 Origin，最长有效 300 秒；配置响应不包含管理员令牌或数据路径。
- 上传前后分别校验格式、大小、分辨率、单脸数量和最小脸部尺寸；头像 ID 仅允许受限字符，所有路径都限制在共享数据目录内。
- 生成目录先在临时区完成，校验必需资源后再原子提交。内置头像、当前头像和正在使用的头像拒绝删除。

### 转发桥原理

s2s 回复时生成的 16kHz int16 PCM 音频，在 `websocket_router.py` 的 `_forward_audio_to_livetalking()` 中通过 HTTP POST 推给 LiveTalking 的 `/humanpcm` 接口：

```
s2s TTS 音频 → POST /humanpcm?sessionid=<活跃会话> → LiveTalking 按 20ms 切块 → wav2lip 口型驱动
```

- 由 `LIVETALKING_URL` 环境变量控制开关（不设置则完全不影响原 s2s 行为）
- 自动发现数字人活跃会话，2 秒 TTL + 业务错误重发现，页面刷新后仍能跟踪新会话
- 失败仅记 debug 日志，不影响语音主链路

### 嵌入页原理

`web/embed.html` 通过 WebRTC 自动连接 LiveTalking：
- 创建 peer connection，接收视频轨（数字人画面）和音频轨（唯一的浏览器播放来源，避免双声）
- 断线 3 秒自动重连
- 通过 `postMessage` 把 sessionid 通知父页面（供调试）
