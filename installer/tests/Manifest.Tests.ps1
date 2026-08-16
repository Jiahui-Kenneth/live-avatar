. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Manifest.psm1" -Force

$modelPath = "$PSScriptRoot\..\manifests\models.json"
$componentPath = "$PSScriptRoot\..\manifests\components.source.json"
$models = Import-LiveAvatarManifest -Path $modelPath -Kind Model
$components = Import-LiveAvatarManifest -Path $componentPath -Kind Component

Assert-Equal 4 $models.models.Count 'exactly four model tiers'
Assert-Equal 'c117a47c5d8d1bb91d68031aaa77891f10118338e1174accc48c55ee3fff8717' `
    ($models.models | Where-Object id -eq 'qwen35-35b-a3b-q4km').sha256 '35B hash'
Assert-Equal 21169117248 `
    ($models.models | Where-Object id -eq 'qwen35-35b-a3b-q4km').bytes '35B byte size'
Assert-Equal 10 $components.components.Count 'all source components are locked'
Assert-Equal 'b10437' `
    ($components.components | Where-Object id -eq 'llama-cuda').version 'llama release lock'
Assert-Throws { Import-LiveAvatarManifest -Path "$PSScriptRoot\fixtures\bad-models.json" -Kind Model } `
    'manifest rejects missing sha256'

$badSchema = Join-Path $env:TEMP 'live-avatar-bad-schema.json'
'{"schema_version":2,"catalog_version":"x","models":[]}' | Set-Content -LiteralPath $badSchema -Encoding UTF8
Assert-Throws { Import-LiveAvatarManifest -Path $badSchema -Kind Model } 'manifest rejects unknown schema'

$duplicate = Join-Path $env:TEMP 'live-avatar-duplicate-models.json'
$copy = Get-Content -LiteralPath $modelPath -Raw | ConvertFrom-Json
$copy.models += $copy.models[0]
$copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $duplicate -Encoding UTF8
Assert-Throws { Import-LiveAvatarManifest -Path $duplicate -Kind Model } 'manifest rejects duplicate IDs'

$insecure = Join-Path $env:TEMP 'live-avatar-insecure-models.json'
$copy = Get-Content -LiteralPath $modelPath -Raw | ConvertFrom-Json
$copy.models[0].url = 'http://example.invalid/model.gguf'
$copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $insecure -Encoding UTF8
Assert-Throws { Import-LiveAvatarManifest -Path $insecure -Kind Model } 'manifest rejects non-HTTPS URLs'

$thresholds = Join-Path $env:TEMP 'live-avatar-bad-thresholds.json'
$copy = Get-Content -LiteralPath $modelPath -Raw | ConvertFrom-Json
$copy.models[0].hybrid_min_vram_mib = $copy.models[0].full_gpu_min_vram_mib + 1
$copy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $thresholds -Encoding UTF8
Assert-Throws { Import-LiveAvatarManifest -Path $thresholds -Kind Model } 'manifest rejects invalid VRAM order'

Complete-TestRun
