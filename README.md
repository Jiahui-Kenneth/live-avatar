# Live Avatar — 全本地语音对话 + 数字人口型同步

<p align="center">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
  <a href="https://github.com/Jiahui-Kenneth/live-avatar"><img src="https://img.shields.io/badge/platform-Windows-2ea44f.svg" alt="Platform"></a>
  <img src="https://img.shields.io/badge/Python-3.11-3776AB.svg?logo=python&logoColor=white" alt="Python 3.11">
  <img src="https://img.shields.io/badge/GPU-NVIDIA%20CUDA-76B900.svg?logo=nvidia&logoColor=white" alt="NVIDIA CUDA">
  <img src="https://img.shields.io/github/stars/Jiahui-Kenneth/live-avatar" alt="GitHub stars">
  <img src="https://img.shields.io/github/v/release/Jiahui-Kenneth/live-avatar?label=release" alt="Release">
</p>

一个完全本地运行的**中文语音对话数字人**。你对着麦克风说话，本地大模型用中文回答，声音被实时合成，同时驱动一个 3D 数字人做**口型同步**，数字人画面铺满整个网页作为背景 —— 就像在和一个真人视频通话。

![架构图](./docs/architecture.md)

## 特性

- 🗣️ **全本地推理** — LLM（Qwen3.5 9B，llama.cpp）与语音管线全部运行在你自己的 GPU 上，无需联网、无 API 费用。
- 👄 **数字人口型同步** — 回复音频实时转发给 [LiveTalking](https://gitee.com/lipku/LiveTalking)（wav2lip），驱动数字人口型。
- 🖼️ **图片头像管理** — 在“设置”中上传单人正脸图片、裁剪、生成并无缝切换数字人头像。
- 🖥 **整页全屏数字人背景** — 数字人视频作为页面背景铺满全屏，UI（说话按钮、输入框）悬浮其上，沉浸感强。
- 🎯 **中文优先** — STT(faster-whisper)、LLM、TTS 全链路中文优化。
- 🔌 **一键启动** — 4 个服务（LLM → 数字人 → 语音管线 → 网页）自动按依赖顺序拉起。

## 架构

```
┌─────────────┐   ┌──────────────┐   ┌────────────┐   ┌───────────────┐
│  llama-server │──▶│  s2s backend │──▶│  s2s demo  │   │  LiveTalking    │
│  (LLM, :8080) │   │  (管线, :8765)│   │ (网页, :7860)│──▶│ (数字人, :8010) │
│ Qwen3.5 4B-35B│   │ VAD+STT+TTS  │   │             │   │  wav2lip 口型   │
└────────────┘   └──────┬───────┘   └────────────┘   └───▲───────────┘
                        │  音频 (16kHz int16 PCM)          │
                        └──────────────┬─────────────────┘
                                     `/humanpcm`
```

**对话流程**：你说中文 → VAD 检测语音 → faster-whisper 转写中文 → llama.cpp 生成中文回复 → Qwen3-TTS 合成语音 → 同一份音频推给 LiveTalking `/humanpcm` → 浏览器播放数字人的 WebRTC 音轨并同步口型。

## 快速开始

> 推荐使用 [联网安装包](docs/INSTALLER.md)。它会检测显存，在 4B / 9B / 27B / 35B 四档中自动推荐并下载；详细手动步骤见 [部署教程](docs/DEPLOYMENT.md)。

### 小型联网安装包

运行 `LiveAvatar-Setup-0.1.0.exe`，选择程序目录和数据目录即可。安装器本身约 2.1 MB，不内置模型；所有载荷支持断点续传、固定字节数和 SHA-256 校验。RTX 50/Blackwell 使用 PyTorch 2.11.0 CUDA 12.8。安装、迁移、修复、卸载保留规则见 [安装包说明](docs/INSTALLER.md)。

### 手动安装

```bat
git clone https://github.com/你的用户名/live-avatar.git
cd live-avatar
rem 按文档先安装四个依赖组件
copy scripts\config.local.bat.example scripts\config.local.bat
notepad scripts\config.local.bat
start_all.bat
```

打开 <http://127.0.0.1:7860> ，点击中间的圆球开始说话。

要更换静态图片头像，打开右上角“设置”，选择 JPEG、PNG 或 WebP 图片，完成 3:4 裁剪后点击“生成并切换”。图片最大 10 MiB；裁剪结果固定为 576×768。处理过程会显示人脸检查、生成和切换状态，生成成功后原始上传文件不会保留。

## 仓库结构

```
live-avatar/
├── scripts/          # 参数化启动脚本
│   ├── config.local.bat.example # 本机路径配置模板
│   ├── start_all.bat         # 一键启动（推荐）
│   ├── start_llama.bat       # llama.cpp LLM
│   ├── start_s2s.bat         # speech-to-speech 管线
│   ├── start_demo.bat        # 网页 UI
│   └── start_livetalking.bat # 数字人服务
├── patches/                  # 对上游仓库的改动（patch）
│   ├── s2s-integration.patch        # s2s：转发桥/web集成/中文STT
│   └── livetalking-integration.patch# LiveTalking：/humanpcm 路由、loopback规避
├── web/embed.html            # 数字人全屏嵌入页（自研）
├── docs/DEPLOYMENT.md        # 详细部署教程 + 注意事项
└── LICENSE                   # MIT
```

> 上传音色需要语音克隆 Base 模型；默认 CustomVoice 模型只能选择内置 speaker。详细配置和 Wav2Lip 输入尺寸注意事项见[部署教程](docs/DEPLOYMENT.md#7-常见问题与注意事项)。

## 依赖（上游项目）

本仓库不包含以下上游代码，部署时按文档分别安装并用 patch 集成：

| 组件 | 来源 | 用途 | License |
|------|------|------|---------|
| [speech-to-speech](https://github.com/huggingface/speech-to-speech) v0.2.11 | HF | 语音对话管线（VAD/STT/LLM/TTS） | Apache-2.0 |
| [LiveTalking](https://gitee.com/lipku/LiveTalking) | lipku | 数字人生成（wav2lip） | MIT |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | ggerganov | llama-server 推理 | MIT |
| [Qwen3.5-9B Uncensored GGUF](https://huggingface.co/) | — | 中文对话模型 | 见模型页 |

## 致谢

本项目是对以下开源项目的集成，感谢原作者：
- Hugging Face [speech-to-speech](https://github.com/huggingface/speech-to-speech)
- lipku [LiveTalking](https://gitee.com/lipku/LiveTalking)
- ggml-org [llama.cpp](https://github.com/ggml-org/llama.cpp)
- Qwen3.5 (Alibaba / Qwen team)

## License

本仓库（scripts/, patches/, web/, docs/）采用 [MIT License](./LICENSE)。上游依赖遵循各自许可证。
