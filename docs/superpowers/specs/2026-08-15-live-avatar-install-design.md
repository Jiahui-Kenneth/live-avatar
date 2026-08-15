# Live Avatar 本机部署设计

## 目标

在 Windows 本机完成 `live-avatar` 的四服务部署，使用户可以通过浏览器进行中文语音对话，并让 LiveTalking 数字人的口型跟随合成语音。除 PyTorch 构建外，组件、模型、补丁、端口和运行参数均遵循原文与仓库部署文档。

## 已确认约束

- 工作目录：`E:\AI\AI-Girlfriend2`。
- GPU：NVIDIA GeForce RTX 5090，32 GB 显存，驱动 610.62。
- 保留现有 Python 3.13 和 3.14；另行安装文章推荐的 Python 3.11.9，所有项目虚拟环境显式使用 `py -3.11`。
- 唯一版本例外：PyTorch 固定为 2.11.0 的 CUDA 12.8 Windows wheel（`torch==2.11.0`、`torchvision==0.26.0`、`torchaudio==2.11.0`），以支持 Blackwell `sm_120`，不使用原文的 CUDA 12.1 wheel。
- 其余内容遵循原文：`speech-to-speech` 固定提交 `656099a`、Qwen3.5-9B Q4 GGUF、llama.cpp CUDA 版、LiveTalking、Wav2Lip 256 权重和头像资源、仓库提供的两份集成补丁。
- 所有网络服务仅监听 `127.0.0.1`。
- 不擅自更换模型、上游提交、TTS/STT 后端或业务参数。出现不兼容时保留日志并停在故障点。

## 目录布局

```text
E:\AI\AI-Girlfriend2\
├── docs\, patches\, scripts\, web\       live-avatar 集成仓库
├── deps\
│   ├── llama.cpp\                         llama.cpp Windows CUDA 运行包
│   ├── speech-to-speech\                  固定到 656099a
│   └── LiveTalking\                       LiveTalking 上游仓库
├── models\
│   └── Qwen3.5-9B-...-Q4_K_M.gguf         本地 LLM 权重
└── downloads\                             可复用的安装包和压缩包
```

每个 Python 上游项目使用自己的 `.venv`，避免 s2s 与 LiveTalking 依赖互相覆盖。`scripts\config.local.bat` 映射到上述实际路径，并继续由 `.gitignore` 排除。

## 组件与版本策略

### Python 3.11

从 Python 官方 Windows 安装包安装 3.11.9，启用 Python Launcher，并确保 `py -3.11` 可用。现有 Python 安装保持不变。

### llama.cpp 与 LLM

下载当前 llama.cpp 发布版本的 Windows CUDA 12.2 x64 包，将可执行文件放入 `deps\llama.cpp`。下载原文指定的 `Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` 至 `models`。启动参数保持：

```text
--host 127.0.0.1 --port 8080 --n-gpu-layers 999
--ctx-size 8192 --parallel 1 --reasoning off --alias qwen3.5-9b
```

### speech-to-speech

克隆 Hugging Face `speech-to-speech`，切换到提交 `656099a`，用 Python 3.11 创建 `.venv`，安装 `.[dev]`。随后在该虚拟环境中从官方 `cu128` 索引强制安装 PyTorch 2.11.0、torchvision 0.26.0 和 torchaudio 2.11.0，并验证 `torch.cuda.get_device_capability()` 返回 `(12, 0)` 且基本 CUDA 张量运算成功。

应用 `patches\s2s-integration.patch`，保留中文识别参数 `--faster_whisper_stt_gen_language zh`，并将 TTS PCM 音频转发到 LiveTalking。

### LiveTalking

按原文克隆 Gitee 的 LiveTalking，用 Python 3.11 创建独立 `.venv`。将原文的 PyTorch CUDA 12.1 安装源替换为官方 PyTorch 2.11.0 CUDA 12.8 wheel；其余依赖继续按 `requirements.txt` 安装。安装后再次确认 requirements 没有把 CUDA 12.8 PyTorch 覆盖掉。

下载 `wav2lip256.pth` 并放到 `deps\LiveTalking\models\wav2lip.pth`。下载原文头像包，解压为 `deps\LiveTalking\data\avatars\myavatar`。应用 `patches\livetalking-integration.patch`，并复制 `web\embed.html`。

## 数据流与服务

```text
浏览器麦克风
  -> s2s demo :7860
  -> s2s backend :8765
  -> faster-whisper 中文转写
  -> llama-server :8080 生成中文回复
  -> Qwen3-TTS 合成 16 kHz int16 PCM
  -> LiveTalking /humanpcm :8010
  -> Wav2Lip 口型与 WebRTC 音视频
  -> 浏览器播放
```

TTS 音频只由 LiveTalking 的 WebRTC 音轨在浏览器播放，避免 s2s 页面和数字人音轨重复发声。

## 安装顺序

1. 安装并验证 Python 3.11。
2. 下载并独立验证 llama.cpp 与 GGUF 模型。
3. 安装并验证 speech-to-speech 虚拟环境与 CUDA 12.8 PyTorch。
4. 安装并验证 LiveTalking 虚拟环境、CUDA 12.8 PyTorch、Wav2Lip 权重和头像。
5. 对两个上游仓库执行补丁预检，再正式应用补丁。
6. 生成本机配置并逐个启动四项服务。
7. 完成端口、GPU、中文语音和口型端到端验证。

## 错误处理

- 每个组件必须先独立通过验证，失败时不继续堆叠后续服务。
- 下载失败可重试官方源或文档明确给出的镜像，但不更换模型或项目版本。
- 补丁先用 `git apply --check` 验证；若失败，记录具体冲突并停止，不直接改上游实现。
- 若安装依赖后 PyTorch 不再是 CUDA 12.8 构建，则重新安装指定 wheel 并复测 CUDA，不默认为 CPU 回退。
- 若资源网站要求登录、验证码或网盘人工操作，暂停并请用户完成该步骤。
- 不结束不相关进程；端口被占用时先报告 PID 和进程信息。
- 服务日志保存在各组件目录，验证失败时保留日志用于定位。

## 验证与完成标准

### 静态检查

- `py -3.11 --version` 成功。
- 两个 `.venv` 均由 Python 3.11 创建。
- 两个环境的 PyTorch 均报告 CUDA 12.8 构建并识别 RTX 5090 `sm_120`。
- 两份补丁已应用，`config.local.bat` 路径全部存在。

### 独立服务检查

- `http://127.0.0.1:8080/health` 返回 `{"status":"ok"}`。
- llama.cpp 聊天接口能生成非空中文内容，且没有因 reasoning 字段导致正文为空。
- LiveTalking `http://127.0.0.1:8010/embed.html` 能建立数字人会话。
- s2s 后端监听 8765，网页 UI 监听 7860。

### 端到端检查

在 `http://127.0.0.1:7860` 完成一次真实中文语音测试，必须同时满足：

1. 中文语音被正确转写；
2. LLM 返回中文文本；
3. 浏览器播放中文合成语音且没有重复声；
4. 数字人口型随该语音变化。

四项均通过才视为安装完成。

## 非目标

- 本轮不替换人物形象、克隆自定义音色、添加长期记忆或知识库。
- 本轮不把服务暴露到局域网或公网。
- 本轮不升级为其他 LLM、STT、TTS 或数字人后端。
