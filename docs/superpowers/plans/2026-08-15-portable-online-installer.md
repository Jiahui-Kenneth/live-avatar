# Portable Online Installer and VRAM Model Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a small Windows installer that detects NVIDIA hardware, recommends a verified Qwen3.5 GGUF tier, downloads and validates the complete Live Avatar stack, creates relocatable configuration, and provides start/stop/repair/migrate/uninstall workflows.

**Architecture:** A small Inno Setup wrapper installs PowerShell bootstrap and maintenance code, then the bootstrap reads versioned component/model manifests, probes hardware, presents a recommended model with manual alternatives, and downloads verified artifacts into an app-version/data split. Release tooling produces prepatched s2s and LiveTalking source bundles plus a reusable Python wheelhouse, so the target computer does not require Git or a compiler. A JSON-driven launcher resolves all paths from the install root and owns PIDs, logs, health checks, upgrades, and rollback.

**Tech Stack:** Windows PowerShell 5.1-compatible modules, WinForms, Inno Setup 6, JSON manifests, curl.exe resumable downloads, SHA-256, Python 3.11.9, llama.cpp b10437, PyTorch 2.11.0 cu128, FastAPI/aiohttp health endpoints, native PowerShell test harness.

## Global Constraints

- First release supports Windows 10/11 x64 and NVIDIA RTX 20/30/40/50; AMD, Intel GPU, macOS, and Linux are out of scope.
- Default install is per-user under `%LOCALAPPDATA%\LiveAvatar`; no administrator rights are required.
- Program versions, runtime, models, avatars, configuration, logs, cache, and temporary files have distinct directories.
- No program or configuration may depend on `C:\`, `E:\`, the developer username, or a fixed current working directory.
- All services bind to `127.0.0.1`; ports remain 8080, 8010, 8765, and 7860 unless a generated machine config explicitly changes them.
- Downloads use HTTPS, resumable `.partial` files, exact byte size, and SHA-256 before atomic promotion.
- RTX 50/Blackwell uses PyTorch `2.11.0+cu128`, torchvision `0.26.0+cu128`, torchaudio `2.11.0+cu128`, CUDA 12.8, and validates capability `(12, 0)`.
- Model recommendation accounts for the whole stack, not just GGUF size; TTS, Whisper, Wav2Lip, KV cache, and safety margin stay reserved.
- The current 32 GiB quality tier remains `Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` with `--reasoning off --jinja --ctx-size 8192`.
- Model choice is recommended automatically but remains user-overridable when the selected mode is safe; unsafe choices are disabled with a reason.
- Upgrades never delete models, custom avatars, or user settings. Uninstall requires explicit per-category deletion choices.
- Machine profile and management token are regenerated after migration and never included in export archives.

---

## File Map

### Manifests and release locks

- Create `installer/manifests/components.source.json`: immutable upstream/release inputs.
- Create `installer/manifests/models.json`: four exact Qwen3.5 Q4_K_M tiers and runtime budgets.
- Create `installer/manifests/components.schema.json` and `installer/manifests/models.schema.json`.
- Create `installer/modules/Manifest.psm1`: strict schema-shaped parsing and compatibility filtering.
- Create `installer/tests/TestHarness.ps1` and `installer/tests/Manifest.Tests.ps1`.

### Hardware and model selection

- Create `installer/modules/Hardware.psm1`: Windows/NVIDIA/VRAM/driver/RAM/disk/port probe.
- Create `installer/modules/ModelSelection.psm1`: stable/recommended/fast/high-quality choices and llama parameters.
- Create `installer/tests/Hardware.Tests.ps1` and `installer/tests/ModelSelection.Tests.ps1`.

### Download, layout, and provisioning

- Create `installer/modules/Download.psm1`: resume, mirror, size/hash, `.partial`, atomic promotion.
- Create `installer/modules/Layout.psm1`: relocatable paths, app config, atomic `current.json` switch.
- Create `installer/modules/Provision.psm1`: component-specific install actions.
- Create `installer/tests/Download.Tests.ps1`, `Layout.Tests.ps1`, `Provision.Tests.ps1`.

### Release asset builder

- Create `installer/build/New-SourceBundles.ps1`: clean pinned source, apply integration patches, create prepatched ZIPs.
- Create `installer/build/New-Wheelhouse.ps1`: download exact Python packages/wheels and record hashes.
- Create `installer/build/New-ReleaseManifest.ps1`: hash release artifacts and render concrete stable manifest.
- Create `installer/build/Test-ReleaseArtifacts.ps1`.

### Bootstrap, launcher, maintenance, migration

- Create `installer/bootstrap.ps1` and `installer/ui/InstallWizard.psm1`.
- Create `launcher/LiveAvatar.ps1`, `launcher/Start-LiveAvatar.cmd`, `launcher/Stop-LiveAvatar.cmd`, `launcher/Maintain-LiveAvatar.cmd`.
- Create `installer/modules/Health.psm1`, `Maintenance.psm1`, `Migration.psm1`.
- Create matching tests under `installer/tests/`.
- Create `installer/LiveAvatar.iss`: small setup executable and uninstall choices.
- Modify `README.md`, `docs/DEPLOYMENT.md`; create `docs/INSTALLER.md`.

---

### Task 1: Strict Manifests and Exact Four-Tier Model Catalog

**Files:**
- Create: `installer/manifests/components.source.json`
- Create: `installer/manifests/models.json`
- Create: `installer/manifests/components.schema.json`
- Create: `installer/manifests/models.schema.json`
- Create: `installer/modules/Manifest.psm1`
- Create: `installer/tests/TestHarness.ps1`
- Create: `installer/tests/Manifest.Tests.ps1`

**Interfaces:**
- Produces: `Import-LiveAvatarManifest -Path <path> -Kind Component|Model`.
- Produces immutable model properties: `id`, `revision`, `filename`, `url`, `bytes`, `sha256`, `full_gpu_min_vram_mib`, `recommended_vram_mib`, `hybrid_min_vram_mib`, `ctx_size`, `gpu_layers`, `reasoning`, `jinja`.
- Test harness produces `Assert-Equal`, `Assert-True`, `Assert-Throws`, and nonzero exit on failure.

- [ ] **Step 1: Write failing manifest tests**

```powershell
. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Manifest.psm1" -Force
$models = Import-LiveAvatarManifest -Path "$PSScriptRoot\..\manifests\models.json" -Kind Model
Assert-Equal 4 $models.models.Count 'exactly four model tiers'
Assert-Equal 'c117a47c5d8d1bb91d68031aaa77891f10118338e1174accc48c55ee3fff8717' `
  ($models.models | Where-Object id -eq 'qwen35-35b-a3b-q4km').sha256 '35B hash'
Assert-Throws { Import-LiveAvatarManifest -Path "$PSScriptRoot\fixtures\bad-models.json" -Kind Model } `
  'manifest rejects missing sha256'
Complete-TestRun
```

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File installer\tests\Manifest.Tests.ps1
```

Expected: module and manifests are absent.

- [ ] **Step 3: Implement strict parser and catalogs**

`models.json` must contain these exact locked artifacts:

| ID | Repository revision | File bytes | LFS SHA-256 | Full-GPU recommendation |
| --- | --- | ---: | --- | ---: |
| `qwen35-4b-q4km` | `c09cdbcdb1fefad6d335809d445621b5f5ba0c6e` | 2,707,513,696 | `79e28ecacf84e75b6056cf4059636d435aa9eb67795780f7b7dbc7d32a962741` | 12,288 MiB |
| `qwen35-9b-q4km` | `0a41c68809d375475f954be12ba7c40efa56c2a9` | 5,627,044,224 | `2ca636d9e81d3d23ca9b60c234fe185d30ec082eeba69ce770fdb0c76559a4f5` | 16,384 MiB |
| `qwen35-27b-q4km` | `ba23816347e0f24d82efbd2397278ff32743b75c` | 16,540,271,712 | `ffec017c7ecba924fbaa8a6576df8c74d949eacb2c264113842ddb4176bbcae1` | 28,672 MiB |
| `qwen35-35b-a3b-q4km` | `f34c1414c2f9a3629187098bdf0e90c85f5034f5` | 21,169,117,248 | `c117a47c5d8d1bb91d68031aaa77891f10118338e1174accc48c55ee3fff8717` | 32,000 MiB |

Each URL uses the locked revision, not `main`:

```json
{
  "id": "qwen35-9b-q4km",
  "revision": "0a41c68809d375475f954be12ba7c40efa56c2a9",
  "filename": "Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf",
  "url": "https://huggingface.co/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive/resolve/0a41c68809d375475f954be12ba7c40efa56c2a9/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf?download=true",
  "bytes": 5627044224,
  "sha256": "2ca636d9e81d3d23ca9b60c234fe185d30ec082eeba69ce770fdb0c76559a4f5",
  "full_gpu_min_vram_mib": 16384,
  "recommended_vram_mib": 16384,
  "hybrid_min_vram_mib": 12288,
  "ctx_size": 8192,
  "gpu_layers": 999,
  "hybrid_gpu_layers": 20,
  "reasoning": "off",
  "jinja": true
}
```

The remaining three repository/file pairs use the identical URL pattern:

```text
HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive
  Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
HauhauCS/Qwen3.5-27B-Uncensored-HauhauCS-Aggressive
  Qwen3.5-27B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
HauhauCS/Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive
  Qwen3.5-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
```

`components.source.json` initially locks:

- Python 3.11.9 installer: 26,216,840 bytes, SHA-256 `5ee42c4eee1e6b4464bb23722f90b45303f79442df63083f05322f1785f5fdde`.
- llama.cpp `b10437` CUDA archive: 250,797,514 bytes, SHA-256 `4bda1e9c7836489b4cacf0cfea1f74eb732ead6300bc61071ce8e6dbd6bcdcd2`.
- llama.cpp `b10437` CUDA runtime archive: 391,443,627 bytes, SHA-256 `8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6`.
- Wav2Lip model Google file ID `1wu6XujFL9rF-0P2l44G6kpeapeY0cME7`, 214,670,409 bytes, SHA-256 `b22d7ac86295df667644b17254dc71250c2600b89e20403e90e58812450bc173`.
- Default avatar Google file ID `1aU-9SMEAZWN00hbvAGlRHG2iB17r9dEW`, 353,005,497 bytes, SHA-256 `8e8c82bf973b91db799ed8b557d1b869438e094bcd1b0cf0bd72b208d5329369`.
- speech-to-speech source commit `656099afffda445a3a3cef8ffee55871c9b6123c`.
- LiveTalking source commit `c963ad409c556918b7d23999bf87c47a7c05c932`.

Use these exact upstream URLs in the source manifest:

```text
https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe
https://github.com/ggml-org/llama.cpp/releases/download/b10437/llama-b10437-bin-win-cuda-12.4-x64.zip
https://github.com/ggml-org/llama.cpp/releases/download/b10437/cudart-llama-bin-win-cuda-12.4-x64.zip
https://github.com/huggingface/speech-to-speech.git
https://gitee.com/lipku/LiveTalking.git
```

The parser rejects unknown schema versions, duplicate IDs, non-HTTPS URLs, hashes not matching `^[0-9a-f]{64}$`, nonpositive sizes, and model VRAM thresholds out of ascending order.

- [ ] **Step 4: Run GREEN and JSON parse checks**

Run the manifest tests and `Get-Content ... | ConvertFrom-Json` for all four JSON files. Expected: pass with no duplicate IDs.

- [ ] **Step 5: Commit locked manifests**

```powershell
git add installer/manifests installer/modules/Manifest.psm1 installer/tests
git commit -m "feat: lock installer component and model catalogs"
```

### Task 2: NVIDIA Hardware Probe and Stable Model Recommendation

**Files:**
- Create: `installer/modules/Hardware.psm1`
- Create: `installer/modules/ModelSelection.psm1`
- Create: `installer/tests/Hardware.Tests.ps1`
- Create: `installer/tests/ModelSelection.Tests.ps1`

**Interfaces:**
- Produces: `Get-LiveAvatarHardwareProfile -NvidiaSmiPath <path> -InstallPath <path> -ModelPath <path>`.
- Produces: `Select-LiveAvatarModel -Profile <object> -Catalog <object> -Preference Recommended|Faster|HigherQuality`.
- Profile includes `windows_version`, `os_arch`, `gpu_name`, `vram_mib`, `driver_version`, `compute_capability`, `ram_mib`, `install_free_bytes`, `model_free_bytes`, and occupied service ports.

- [ ] **Step 1: Write failing probe/selection tests**

Use a fake `nvidia-smi.cmd` fixture that prints one deterministic CSV row. Assert:

```powershell
Assert-Equal 'NVIDIA GeForce RTX 5090' $profile.gpu_name 'gpu name'
Assert-Equal 32607 $profile.vram_mib 'reported VRAM'
Assert-Equal 'qwen35-35b-a3b-q4km' `
  (Select-LiveAvatarModel -Profile $profile -Catalog $catalog -Preference Recommended).model.id `
  '32 GiB tier'
```

Table-driven selection cases:

```powershell
$cases = @(
  @{ vram=32607; expected='qwen35-35b-a3b-q4km'; mode='full_gpu' },
  @{ vram=30000; expected='qwen35-27b-q4km'; mode='full_gpu' },
  @{ vram=24576; expected='qwen35-9b-q4km'; mode='full_gpu' },
  @{ vram=16384; expected='qwen35-9b-q4km'; mode='full_gpu' },
  @{ vram=12288; expected='qwen35-4b-q4km'; mode='full_gpu' },
  @{ vram=8192; expected='qwen35-4b-q4km'; mode='hybrid' },
  @{ vram=6144; expected='qwen35-4b-q4km'; mode='cpu' }
)
```

- [ ] **Step 2: Run RED**

Run the two native test scripts. Expected: modules absent.

- [ ] **Step 3: Implement probe and selector**

Probe NVIDIA with:

```powershell
& $NvidiaSmiPath --query-gpu=name,memory.total,driver_version,compute_cap `
  --format=csv,noheader,nounits
```

If `compute_cap` is unavailable on an older driver, query the first three fields and leave capability null; the CUDA smoke test later becomes authoritative. Reject multiple GPUs in v0.1.0 with a clear choice dialog rather than silently summing VRAM.

Selector sorts only compatible models by `recommended_vram_mib`; `Recommended` chooses the highest full-GPU tier that fits. `Faster` chooses one tier lower. `HigherQuality` may choose the next tier only when its full-GPU minimum fits; otherwise it is disabled. Between 8,192 and 12,287 MiB, select 4B hybrid with 20 GPU layers. Below 8,192 MiB, select 4B CPU mode and display a slow-mode warning.

- [ ] **Step 4: Run GREEN and real read-only probe**

Run tests, then run the probe against the current RTX 5090. Expected: GPU `RTX 5090`, VRAM 32607 MiB, compute capability `12.0`, recommended 35B.

- [ ] **Step 5: Commit hardware selection**

```powershell
git add installer/modules/Hardware.psm1 installer/modules/ModelSelection.psm1 installer/tests
git commit -m "feat: recommend models from detected VRAM"
```

### Task 3: Resumable Verified Downloader

**Files:**
- Create: `installer/modules/Download.psm1`
- Create: `installer/tests/Download.Tests.ps1`

**Interfaces:**
- Produces: `Get-VerifiedArtifact -Artifact <manifest item> -Destination <path> -Mirror Official|China -CurlPath <path>`.
- Only a verified final file may be returned.
- Uses `<destination>.partial` for incomplete bytes and `<destination>.bad-<timestamp>` for a hash mismatch retained for diagnostics.

- [ ] **Step 1: Write failing downloader tests**

Inject a downloader scriptblock so tests do not use the internet:

```powershell
$artifact = [pscustomobject]@{
  id='tiny'; urls=@('https://example.invalid/tiny.bin'); bytes=5
  sha256='2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
}
$result = Get-VerifiedArtifact -Artifact $artifact -Destination $dest -DownloadAction {
  param($url,$partial) [IO.File]::WriteAllBytes($partial,[Text.Encoding]::UTF8.GetBytes('hello'))
}
Assert-Equal 'hello' ([IO.File]::ReadAllText($result)) 'verified content'
Assert-True (-not (Test-Path "$dest.partial")) 'partial promoted'
```

Add cases for resume preserving the existing partial, wrong size, wrong hash, mirror fallback, and retry after a thrown network exception.

- [ ] **Step 2: Run RED**

Run `Download.Tests.ps1`. Expected: module absent.

- [ ] **Step 3: Implement exact verification**

Default action runs:

```powershell
& $CurlPath -L --fail --retry 5 --retry-delay 5 -C - -o $partial $url
if ($LASTEXITCODE -ne 0) { throw "download failed with exit $LASTEXITCODE" }
```

After every transfer, compare `[IO.FileInfo].Length`, compute `Get-FileHash -Algorithm SHA256`, compare invariant lowercase strings, then `Move-Item -LiteralPath $partial -Destination $Destination`. Google Drive items use their `file_id` to construct `https://drive.usercontent.google.com/download?id=<id>&export=download&confirm=t`, but still require the locked size/hash so an HTML confirmation response is rejected.

- [ ] **Step 4: Run GREEN and one real range probe**

Run unit tests. Against the Python installer URL, download into a temporary path, validate 26,216,840 bytes and SHA-256 `5ee42c4e...fdde`, then delete only that verified temporary test file.

- [ ] **Step 5: Commit downloader**

```powershell
git add installer/modules/Download.psm1 installer/tests/Download.Tests.ps1
git commit -m "feat: add resumable verified downloads"
```

### Task 4: Relocatable Layout, Machine Config, and Atomic Version Switch

**Files:**
- Create: `installer/modules/Layout.psm1`
- Create: `installer/tests/Layout.Tests.ps1`
- Modify: `scripts/ensure_avatar_security.ps1`

**Interfaces:**
- Produces: `New-LiveAvatarLayout -InstallRoot -DataRoot -Version`.
- Produces: `Write-LiveAvatarConfig -Layout -Hardware -ModelSelection -Ports`.
- Produces: `Set-LiveAvatarCurrentVersion -InstallRoot -Version` and `Get-LiveAvatarCurrentVersion`.
- Config paths are relative to `install_root` or `data_root`; secrets live in separate files.

- [ ] **Step 1: Write failing layout tests**

Create roots containing spaces and Chinese characters. Assert exact directories, JSON round-trip, no developer paths, and failed version switch rollback:

```powershell
Assert-True ((Get-Content $config -Raw) -notmatch 'E:\\AI|Jiahui') 'no developer path'
Assert-Equal 'models/qwen.gguf' $parsed.model.relative_path 'relative model path'
Assert-Equal '0.1.0' (Get-LiveAvatarCurrentVersion $root).version 'active version'
```

- [ ] **Step 2: Run RED**

Run `Layout.Tests.ps1`. Expected: module absent.

- [ ] **Step 3: Implement layout and config**

Create:

```text
<install-root>/app/versions/0.1.0
<install-root>/runtime/Python311
<install-root>/launcher
<data-root>/config
<data-root>/hardware
<data-root>/models
<data-root>/avatars
<data-root>/cache
<data-root>/logs
<data-root>/temp
```

`app.json` stores schema `1`, relative component paths, selected model ID/mode, llama args, loopback ports, and data root. If data root is outside install root, store it as an absolute user-selected root in exactly one top-level field; all descendants remain relative. Write `current.json` via temporary sibling and `os.replace` equivalent `[IO.File]::Replace` when target exists, otherwise `Move-Item`.

- [ ] **Step 4: Run GREEN and relocation test**

Run tests, then copy a fixture layout from one temporary root to another and confirm all resolved paths move with it except an explicitly external data root.

- [ ] **Step 5: Commit layout**

```powershell
git add installer/modules/Layout.psm1 installer/tests/Layout.Tests.ps1 scripts/ensure_avatar_security.ps1
git commit -m "feat: add relocatable install layout"
```

### Task 5: Reproducible Prepatched Source Bundles and Wheelhouse

**Files:**
- Create: `installer/build/New-SourceBundles.ps1`
- Create: `installer/build/New-Wheelhouse.ps1`
- Create: `installer/build/New-ReleaseManifest.ps1`
- Create: `installer/build/Test-ReleaseArtifacts.ps1`
- Create: `installer/manifests/python-requirements.lock.json`

**Interfaces:**
- Produces: `speech-to-speech-656099a-live-avatar-v0.1.0.zip`.
- Produces: `LiveTalking-c963ad4-live-avatar-v0.1.0.zip`.
- Produces: `python-wheelhouse-live-avatar-v0.1.0.zip` with a hash/size entry for every wheel.
- Produces: concrete `components-v0.1.0.json` containing release URLs, bytes, and SHA-256.

- [ ] **Step 1: Write failing release-artifact assertions**

`Test-ReleaseArtifacts.ps1` must reject missing expected source files, patch markers, unpinned wheels, a CPU-only torch wheel, hash mismatch, and an archive containing `.git`, `.venv`, logs, models, or user data.

- [ ] **Step 2: Run RED**

Run the artifact test against an empty temporary dist directory. Expected: reports all three missing archives and exits nonzero.

- [ ] **Step 3: Implement source bundle builder**

The builder creates clean checkouts at the two exact commits. Apply patch blobs byte-for-byte from the integration commit, avoiding PowerShell text conversion:

```powershell
$cmd = 'git -C "{0}" cat-file blob HEAD:patches/s2s-integration.patch | git -C "{1}" apply --check --binary -' -f $RepoRoot,$S2sWork
cmd.exe /d /s /c $cmd
if ($LASTEXITCODE -ne 0) { throw 's2s patch preflight failed' }
$cmd = 'git -C "{0}" cat-file blob HEAD:patches/s2s-integration.patch | git -C "{1}" apply --binary -' -f $RepoRoot,$S2sWork
cmd.exe /d /s /c $cmd
```

Repeat for LiveTalking, copy the exact tracked `web/embed.html`, remove `.git`, and archive with `Compress-Archive`. Assert the source HEAD before patching.

The wheelhouse builder uses Python 3.11.9 and `pip download --only-binary=:all:` for both projects, `faster-whisper`, and exact torch `2.11.0`, torchvision `0.26.0`, torchaudio `2.11.0` from the cu128 index. It writes every wheel filename, size, and SHA-256 to the lock JSON. Provisioning later installs with `--no-index --find-links <wheelhouse>` so target resolution cannot drift.

`New-ReleaseManifest.ps1` hashes the three bundles and renders URLs under:

```text
https://github.com/HeiXia2077/live-avatar/releases/download/v0.1.0/<artifact-name>
```

- [ ] **Step 4: Build and verify artifacts**

Run all three builders and `Test-ReleaseArtifacts.ps1`. Extract both source ZIPs to fresh temporary directories, import the modified Python modules, run the avatar tests and s2s config tests, and confirm torch wheel filenames contain `cu128`, not `cpu` or `cu121`.

- [ ] **Step 5: Commit release tooling and lock**

```powershell
git add installer/build installer/manifests/python-requirements.lock.json
git commit -m "build: create reproducible installer payloads"
```

Do not commit generated ZIP files; attach them to the v0.1.0 release only after Task 8 verification.

### Task 6: Provisioning Engine and End-to-End Bootstrap

**Files:**
- Create: `installer/modules/Provision.psm1`
- Create: `installer/tests/Provision.Tests.ps1`
- Create: `installer/bootstrap.ps1`
- Create: `installer/ui/InstallWizard.psm1`

**Interfaces:**
- Produces: `Install-LiveAvatarComponent -Component -Layout -DownloadRoot`.
- Produces: `bootstrap.ps1 -InstallRoot -DataRoot -Preference -Unattended -ManifestPath`.
- Unattended mode is deterministic and powers automated clean-machine tests; interactive mode uses the same service functions.

- [ ] **Step 1: Write failing provisioning tests**

Use tiny fixture ZIPs and a fake Python installer executable. Assert ordered state transitions:

```text
detect -> choose-model -> confirm-space -> download -> verify -> stage -> configure -> smoke-test -> activate-version
```

Failure during `stage` must leave `current.json` unchanged. Failure after one verified download must preserve that artifact in download cache.

- [ ] **Step 2: Run RED**

Run `Provision.Tests.ps1`. Expected: module/bootstrap absent.

- [ ] **Step 3: Implement provisioning and UI**

Component actions are explicit by `install_kind`:

- `python_exe`: quiet per-user installation into `<install>/runtime/Python311` with `Include_test=0`, then `python --version` exact `3.11.9`.
- `zip`: expand to a staging directory, verify required files, then atomic move.
- `wheelhouse`: create two venvs with the fixed Python, install each locked requirements set using `--no-index`, then install exact cu128 torch trio and run `pip check`.
- `gguf`: retain verified file under `<data>/models/<filename>` and assert first four bytes are `GGUF`.
- `google_drive`: use the same verified downloader and then place Wav2Lip/default avatar resources.

WinForms wizard pages are: Welcome, Paths, Hardware, Model Choice, Download Summary, Progress, Verification, Finish. Hardware/model page shows exact GPU, VRAM, recommendation reason, download bytes, and disables unsafe high-quality entries. Closing during download asks for confirmation and preserves `.partial` files.

- [ ] **Step 4: Run GREEN in fixture and dry-run modes**

Run tests. Run bootstrap `-Unattended` with fixture manifest into a path containing spaces and Chinese; assert complete layout and current version. Run production manifest with `-WhatIf` to print exact URLs, sizes, commands, and disk requirement without downloading.

- [ ] **Step 5: Commit bootstrap**

```powershell
git add installer/modules/Provision.psm1 installer/tests/Provision.Tests.ps1 installer/bootstrap.ps1 installer/ui
git commit -m "feat: bootstrap verified live avatar installs"
```

### Task 7: Launcher, Health, Repair, Migration, and Uninstall Semantics

**Files:**
- Create: `installer/modules/Health.psm1`
- Create: `installer/modules/Maintenance.psm1`
- Create: `installer/modules/Migration.psm1`
- Create: `installer/tests/Health.Tests.ps1`
- Create: `installer/tests/Maintenance.Tests.ps1`
- Create: `installer/tests/Migration.Tests.ps1`
- Create: `launcher/LiveAvatar.ps1`
- Create: `launcher/Start-LiveAvatar.cmd`
- Create: `launcher/Stop-LiveAvatar.cmd`
- Create: `launcher/Maintain-LiveAvatar.cmd`

**Interfaces:**
- Launcher commands: `start`, `stop`, `status`, `doctor`, `repair`, `update`, `export-data`, `import-data`.
- PID records include PID, executable absolute path, arguments hash, start time, and component ID.
- Migration export includes avatars, active avatar, and nonsecret settings only.

- [ ] **Step 1: Write failing lifecycle and migration tests**

Tests inject process and HTTP adapters. Verify dependency start order `llama -> LiveTalking -> s2s -> demo`, health timeouts, rollback of only processes started by the current attempt, refusal to kill an unrelated PID, and exact export exclusions:

```powershell
Assert-True (-not ($zipEntries -match 'avatar-admin-token|hardware/profile|logs/|temp/|cache/')) 'secrets and machine state excluded'
Assert-True ($zipEntries -match 'avatars/.+/metadata.json') 'custom avatars included'
```

- [ ] **Step 2: Run RED**

Run Health, Maintenance, and Migration tests. Expected: modules absent.

- [ ] **Step 3: Implement launcher and maintenance commands**

The launcher resolves itself with `$PSScriptRoot`, reads current/app JSON, exports process-local environment, and uses `Start-Process -WindowStyle Hidden -PassThru` with separate stdout/stderr logs. It polls:

- `http://127.0.0.1:8080/health` for `{"status":"ok"}`;
- `http://127.0.0.1:8010/api/admin/config` code 0;
- TCP 8765;
- `http://127.0.0.1:7860/api/config` with the expected s2s/avatar URLs.

Stop validates PID start time and executable path before termination. Repair revalidates manifest bytes/hashes and redownloads only missing/corrupt artifacts. Update stages a new app version, runs all smoke tests, switches `current.json`, then stops the old processes and starts the new version; failure retains the old current version.

Export uses `Compress-Archive` on an allowlist. Import validates archive entry paths, stages data, excludes token/hardware, then merges avatars without overwriting IDs; conflicts receive a new safe ID and updated metadata.

- [ ] **Step 4: Run GREEN and current-stack shadow validation**

Run tests. Point launcher config at the already installed stack but use alternate test ports; verify status/doctor output without stopping production services. Export current custom avatars to a temporary archive, inspect exclusions, import into a second temporary data root, and compare avatar counts/hashes.

- [ ] **Step 5: Commit operations tooling**

```powershell
git add installer/modules installer/tests launcher
git commit -m "feat: add launcher repair and migration tools"
```

### Task 8: Small Setup EXE, Clean-Machine Matrix, and Release Documentation

**Files:**
- Create: `installer/LiveAvatar.iss`
- Create: `installer/tests/InstallerSmoke.Tests.ps1`
- Create: `docs/INSTALLER.md`
- Modify: `README.md`
- Modify: `docs/DEPLOYMENT.md`

**Interfaces:**
- Produces: `LiveAvatar-Setup-0.1.0.exe` containing only bootstrap code, UI, manifests, launcher, and icons; models/runtimes/source bundles remain online payloads.
- Produces user shortcuts: Live Avatar, Stop Live Avatar, Live Avatar Maintenance.

- [ ] **Step 1: Write failing setup smoke assertions**

Assert the compiled EXE exists, is below 50 MiB, contains version `0.1.0`, installs per-user without elevation, creates three shortcuts, and invokes bootstrap with the selected install/data roots. Uninstall fixture tests assert default preservation of models, avatars, and settings.

- [ ] **Step 2: Run RED**

Run `InstallerSmoke.Tests.ps1` before compilation. Expected: setup EXE absent.

- [ ] **Step 3: Implement Inno Setup and docs**

`LiveAvatar.iss` uses `PrivilegesRequired=lowest`, `ArchitecturesAllowed=x64compatible`, and starts `bootstrap.ps1` hidden only after the wizard path pages complete. Uninstall displays independent checkboxes for models, custom avatars, and settings; all default unchecked. It never recursively removes a user-selected external data root unless the resolved path equals the recorded data root and the user checked at least one category.

Documentation includes supported GPUs, model table, actual download sizes, space calculation, driver prerequisite, mirror behavior, partial resume, install/move/update/repair/uninstall steps, avatar migration, log locations, and offline limitations.

- [ ] **Step 4: Execute release matrix**

Run clean Windows 10/11 tests on representative NVIDIA tiers or equivalent physical test hosts:

- 8 GiB RTX 20/30: 4B hybrid, no OOM, all services healthy.
- 12 GiB RTX 30/40: 4B full GPU.
- 16 GiB RTX 30/40: 9B full GPU.
- 24 GiB RTX 3090/4090: 9B stable default; 27B displayed as unsafe, not selectable as full GPU.
- 32 GiB RTX 5090: 35B Q4_K_M, PyTorch cu128, capability 12.0.

For every tier, complete one Chinese microphone request, audible reply, moving mouth, image-avatar generation/switch, restart persistence, repair dry run, and uninstall preserving avatars. Also test an old driver, no NVIDIA GPU, insufficient disk, interrupted model download/resume, bad hash, occupied port, Chinese/space install path, and external model disk.

- [ ] **Step 5: Build, verify, commit, and stage release**

```powershell
ISCC.exe installer\LiveAvatar.iss
powershell.exe -NoProfile -ExecutionPolicy Bypass -File installer\tests\InstallerSmoke.Tests.ps1
git diff --check
git add installer/LiveAvatar.iss installer/tests/InstallerSmoke.Tests.ps1 docs README.md
git commit -m "feat: package portable live avatar installer"
git status --short
```

Expected: all installer tests pass and worktree is clean. Upload the three verified payload ZIPs, concrete manifest, and setup EXE to the GitHub `v0.1.0` release only after recording every release file's size and SHA-256 in `docs/INSTALLER.md`.
