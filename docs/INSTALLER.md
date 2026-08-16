# Live Avatar 联网安装包

`LiveAvatar-Setup-0.1.0.exe` 是一个小型、每用户安装的 Windows 引导程序。它不内置 LLM、CUDA 运行时或 Python wheelhouse；安装时检测 NVIDIA GPU 和显存，推荐合适的 Qwen3.5 GGUF，然后断点续传并用固定字节数与 SHA-256 校验全部载荷。

## 支持范围

- Windows 10/11 x64。
- 单张 NVIDIA RTX 20/30/40/50 系列 GPU；v0.1.0 不支持多 GPU、AMD、Intel GPU、macOS 或 Linux。
- NVIDIA 驱动必须支持 CUDA 12.8。RTX 50/Blackwell 使用 PyTorch `2.11.0+cu128`、torchvision `0.26.0+cu128`、torchaudio `2.11.0+cu128`，启动时应显示计算能力 `(12, 0)`。
- 推荐 32 GiB 系统内存；大型模型建议 64 GiB。

安装器不需要管理员权限，默认程序目录是 `%LOCALAPPDATA%\LiveAvatar`。模型和头像可另选数据盘。

## 显存与模型选择

推荐逻辑为语音识别、Qwen3-TTS、Wav2Lip、KV cache 和安全余量预留显存，并不是简单比较 GGUF 文件大小。

| 显存 | 默认选择 | 模式 | GGUF | 首次安装下载总量* |
|---:|---|---|---:|---:|
| 6 GiB 以下 | 4B | CPU 慢速 | 2.52 GiB | 6.68 GiB |
| 8 GiB | 4B | 混合卸载 | 2.52 GiB | 6.68 GiB |
| 12 GiB | 4B | 全 GPU | 2.52 GiB | 6.68 GiB |
| 16–24 GiB | 9B | 全 GPU | 5.24 GiB | 9.40 GiB |
| 28–30 GiB | 27B | 全 GPU | 15.40 GiB | 19.57 GiB |
| 32 GiB 及以上 | 35B-A3B | 全 GPU | 19.72 GiB | 23.88 GiB |

\* 总量包含 4,464,050,713 字节的 Python、llama.cpp、Wav2Lip、默认头像、预打补丁源码和锁定的 Python wheels。首次启动还会下载 faster-whisper base 与 Qwen3-TTS 语音模型，合计约 4.4 GiB，保存在数据目录的 `cache\huggingface`。

安装器允许选择“更快”档；高质量档只有在完整栈显存预算安全时才可选。24 GiB 机器默认保持 9B，27B 全 GPU 会显示为不安全。

建议空闲磁盘：4B 25 GiB、9B 30 GiB、27B 45 GiB、35B 55 GiB。程序盘需要容纳两个隔离 Python 环境；数据盘需要容纳 GGUF、语音缓存、头像、下载缓存和日志。

## 安装

1. 更新 NVIDIA 驱动，关闭占用 8080、8010、8765、7860 的其它程序。
2. 运行 `LiveAvatar-Setup-0.1.0.exe`。
3. 选择程序目录和数据目录。路径可以包含空格和中文。
4. 检查 GPU、显存、推荐模型、模式和下载量，确认安装。
5. 下载中断后重新运行安装器；`.partial` 文件会保留并由 `curl -C -` 继续下载。完成前后都会核对字节数和 SHA-256，错误文件会以 `.bad-*` 隔离。
6. 安装完成后，从开始菜单运行“Live Avatar”。首启语音模型仍需联网，完成后打开 `http://127.0.0.1:7860/`。

安装器写入三个开始菜单快捷方式：Live Avatar、Stop Live Avatar、Live Avatar Maintenance。全部服务只绑定 `127.0.0.1`。

## 下载路线和离线限制

“Official”按清单顺序使用官方 HTTPS 地址。“China”会优先清单中存在的 `hf-mirror`、阿里云或 Gitee 地址；v0.1.0 的正式发布清单目前只锁定官方 GitHub、Hugging Face、Python 和 Google Drive 地址，因此选择 China 不保证存在替代镜像。

两套环境共使用 148 个锁定 wheel：145 个放在 457,470,408 字节的 GitHub Release wheelhouse 中；`torch`、`torchvision`、`torchaudio` 三个 CUDA 12.8 wheel 直接从 PyTorch 官方地址下载。安装器会先逐个核对固定字节数与 SHA-256，再合并到本地 wheel 目录，随后使用 `--no-index` 安装，因此目标电脑不访问 PyPI，也不需要 Git 或编译器。这样每个 GitHub Release 附件都低于其 2 GiB 单文件限制。

但是全新安装仍要下载发布载荷、GGUF、Wav2Lip 资源，并在首次启动下载语音模型；它不是完全离线安装包。

## 日常命令

以下命令在安装目录执行，也可使用开始菜单快捷方式：

```powershell
launcher\LiveAvatar.ps1 start
launcher\LiveAvatar.ps1 stop
launcher\LiveAvatar.ps1 status
launcher\LiveAvatar.ps1 doctor
launcher\LiveAvatar.ps1 repair
launcher\LiveAvatar.ps1 update
```

`repair` 重新核对清单、缓存和安装目标，只重新下载丢失或损坏的文件；不完整源码目录会改名为 `.bad-*` 后恢复。`update` 先完整安装并验证新版本，再切换 `current.json`；启动失败会恢复旧版本。

日志位于 `<数据目录>\logs`，下载缓存位于 `<数据目录>\cache\downloads`，Hugging Face 缓存位于 `<数据目录>\cache\huggingface`。

## 移动与迁移

停止服务后，如果数据目录在安装根目录内部，可以整体移动安装目录；配置使用相对路径。外置数据目录记录为绝对路径，移动数据盘后应重新安装并选择新位置。

跨电脑迁移头像和非敏感设置：

```powershell
launcher\LiveAvatar.ps1 export-data -ArchivePath "D:\Backup\live-avatar-data.zip"
launcher\LiveAvatar.ps1 import-data -ArchivePath "D:\Backup\live-avatar-data.zip"
```

导出只包含 `avatars` 和 `config/settings.json`，不会包含管理员令牌、硬件配置、日志、缓存、临时文件或模型。导入遇到同名头像会生成新 ID，并同步更新元数据。

## 卸载

Windows“已安装的应用”中卸载 Live Avatar。模型、自定义头像和设置默认全部保留。卸载页提供三个独立复选框；只有显式勾选时，才删除记录的数据目录下对应的 `models`、`avatars` 或 `config` 子目录。卸载器不会递归删除整个外置数据根目录。

## v0.1.0 发布文件

本机构建结果：

| 文件 | 字节 | SHA-256 |
|---|---:|---|
| `LiveAvatar-Setup-0.1.0.exe` | 2,130,008 | `2fe210bac9ea45609c5feb3a1f3b6b1d145ecf54bb6dc7145213402f10214677` |
| `python-wheelhouse-live-avatar-v0.1.0.zip` | 457,470,408 | `73ee9e604aac6247e378687676fc2f8b2b44427a6c6dbc7b2c4599e1e0133c0c` |

源码包、完整 release manifest 以及剩余发布文件的字节数和 SHA-256 以 `installer/manifests/components-v0.1.0.json` 为准。正式上传 GitHub Release 后，应再次核对下载文件与本表。
