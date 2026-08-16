. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Layout.psm1" -Force

$zhLayout = -join @([char]0x5e03,[char]0x5c40)
$zhProgram = -join @([char]0x7a0b,[char]0x5e8f)
$zhExternal = -join @([char]0x5916,[char]0x90e8)
$zhMove = -join @([char]0x642c,[char]0x8fc1)
$base = Join-Path $env:TEMP ("Live Avatar $zhLayout " + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $base "$zhProgram root"
$dataRoot = Join-Path $installRoot 'data'
$layout = New-LiveAvatarLayout -InstallRoot $installRoot -DataRoot $dataRoot -Version '0.1.0'

foreach ($path in @(
    $layout.version_root, $layout.python_root, $layout.launcher_root,
    $layout.config_root, $layout.hardware_root, $layout.models_root,
    $layout.avatars_root, $layout.cache_root, $layout.logs_root, $layout.temp_root
)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Container) "layout directory exists: $path"
}

$hardware = [pscustomobject]@{gpu_name='NVIDIA GeForce RTX 5090';vram_mib=32607;compute_capability='12.0'}
$model = [pscustomobject]@{
    model=[pscustomobject]@{id='qwen35-35b-a3b-q4km';filename='qwen.gguf';ctx_size=8192;reasoning='off';jinja=$true}
    mode='full_gpu';gpu_layers=999
}
$ports = [pscustomobject]@{llm=8080;livetalking=8010;s2s=8765;demo=7860}
$configPath = Write-LiveAvatarConfig -Layout $layout -Hardware $hardware -ModelSelection $model -Ports $ports
$raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$parsed = $raw | ConvertFrom-Json
Assert-True ($raw -notmatch 'E:\\AI|Jiahui') 'no developer path'
Assert-Equal 'models/qwen.gguf' $parsed.model.relative_path 'relative model path'
Assert-Equal 'data' $parsed.data_root 'internal data root is relative'
Assert-Equal 'app/versions/0.1.0' $parsed.components.app.relative_path 'version path is relative'
Assert-True ($raw -notmatch 'token|secret') 'app config contains no secrets'

Set-LiveAvatarCurrentVersion -InstallRoot $installRoot -Version '0.1.0'
Assert-Equal '0.1.0' (Get-LiveAvatarCurrentVersion -InstallRoot $installRoot).version 'active version'
Assert-Throws {
    Set-LiveAvatarCurrentVersion -InstallRoot $installRoot -Version '0.2.0'
} 'missing version cannot become current'
Assert-Equal '0.1.0' (Get-LiveAvatarCurrentVersion -InstallRoot $installRoot).version 'failed switch retains old current version'

$externalData = Join-Path $base "$zhExternal model data"
$externalLayout = New-LiveAvatarLayout -InstallRoot (Join-Path $base "second $zhProgram") -DataRoot $externalData -Version '0.1.0'
$externalConfig = Write-LiveAvatarConfig -Layout $externalLayout -Hardware $hardware -ModelSelection $model -Ports $ports
$externalParsed = Get-Content -LiteralPath $externalConfig -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal ([IO.Path]::GetFullPath($externalData)) $externalParsed.data_root 'external data root is stored once as absolute'
Assert-Equal 1 @($externalParsed.PSObject.Properties.Name | Where-Object { $_ -eq 'data_root' }).Count 'external root appears in exactly one top-level field'

$movedRoot = Join-Path $base "$zhMove root"
Copy-Item -LiteralPath $installRoot -Destination $movedRoot -Recurse
$resolved = Resolve-LiveAvatarLayout -InstallRoot $movedRoot
Assert-Equal ([IO.Path]::GetFullPath((Join-Path $movedRoot 'data'))) $resolved.data_root 'internal data moves with install root'
Assert-Equal ([IO.Path]::GetFullPath((Join-Path $movedRoot 'data\models\qwen.gguf'))) $resolved.model_path 'model resolves under moved root'

$token1 = & "$PSScriptRoot\..\..\scripts\ensure_avatar_security.ps1" -DataRoot $dataRoot
$token2 = & "$PSScriptRoot\..\..\scripts\ensure_avatar_security.ps1" -DataRoot $dataRoot
Assert-True ($token1 -match '^[A-Za-z0-9_-]{43}$') 'management token format'
Assert-Equal $token1 $token2 'management token persists across launches'

Complete-TestRun
