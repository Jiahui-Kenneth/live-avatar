. "$PSScriptRoot\TestHarness.ps1"

function Write-JsonFixture {
    param([string]$Path, $Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}

function New-ZipFixture {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('demo/server.py')
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write('app = object()') } finally { $writer.Dispose() }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

$zh = -join @([char]0x5b89,[char]0x88c5)
$root = Join-Path $env:TEMP ("Live Avatar $zh " + [guid]::NewGuid().ToString('N'))
$fixtures = Join-Path $root 'fixtures'
$installRoot = Join-Path $root 'Program Files'
$dataRoot = Join-Path $root 'User Data'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null

$zipPath = Join-Path $fixtures 's2s.zip'
New-ZipFixture $zipPath
$modelPath = Join-Path $fixtures 'tiny.gguf'
[IO.File]::WriteAllBytes($modelPath, [Text.Encoding]::ASCII.GetBytes('GGUFfixture'))

$componentManifest = [ordered]@{
    schema_version=1;catalog_version='0.1.0';components=@(
        [ordered]@{
            id='speech-to-speech-bundle';install_kind='source_bundle';version='0.1.0';filename='s2s.zip'
            urls=@('https://fixture.invalid/s2s.zip');bytes=[int64](Get-Item $zipPath).Length
            sha256=(Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant();required_files=@('demo/server.py')
        }
    )
}
$modelManifest = [ordered]@{
    schema_version=1;catalog_version='fixture';models=@(
        [ordered]@{
            id='qwen35-test-q4km';display_name='Fixture Qwen';repository='fixture/qwen';revision=('a' * 40)
            filename='tiny.gguf';url='https://fixture.invalid/tiny.gguf';bytes=[int64](Get-Item $modelPath).Length
            sha256=(Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
            full_gpu_min_vram_mib=4096;recommended_vram_mib=4096;hybrid_min_vram_mib=2048
            ctx_size=8192;gpu_layers=999;hybrid_gpu_layers=20;reasoning='off';jinja=$true
        }
    )
}
$profile = [ordered]@{
    windows_version='10.0';os_arch='X64';gpu_name='Fixture RTX';vram_mib=16384;driver_version='999.0'
    compute_capability='8.6';ram_mib=32768;install_free_bytes=100000000000;model_free_bytes=100000000000
    occupied_service_ports=@()
}
$componentPath = Join-Path $fixtures 'components.json'
$modelManifestPath = Join-Path $fixtures 'models.json'
$profilePath = Join-Path $fixtures 'hardware.json'
Write-JsonFixture $componentPath $componentManifest
Write-JsonFixture $modelManifestPath $modelManifest
Write-JsonFixture $profilePath $profile

$output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\bootstrap.ps1" `
    -InstallRoot $installRoot -DataRoot $dataRoot -Preference Recommended -Unattended `
    -ManifestPath $componentPath -ModelManifestPath $modelManifestPath -HardwareProfilePath $profilePath `
    -FixtureSourceRoot $fixtures 2>&1)
Assert-Equal 0 $LASTEXITCODE 'unattended fixture bootstrap exits successfully'
Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'current.json') -PathType Leaf) 'bootstrap activates current version'
Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'app/versions/0.1.0/speech-to-speech/demo/server.py') -PathType Leaf) 'bootstrap stages source bundle'
Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'models/tiny.gguf') -PathType Leaf) 'bootstrap stages model'
Assert-True (($output -join "`n") -match '"status"\s*:\s*"installed"') 'bootstrap emits installed result'

$planOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\bootstrap.ps1" `
    -InstallRoot (Join-Path $root 'Plan Only') -DataRoot (Join-Path $root 'Plan Data') -Preference Recommended -Unattended `
    -ManifestPath "$PSScriptRoot\..\manifests\components-v0.1.0.json" `
    -ModelManifestPath "$PSScriptRoot\..\manifests\models.json" -HardwareProfilePath $profilePath -WhatIf 2>&1)
Assert-Equal 0 $LASTEXITCODE 'production manifest WhatIf exits successfully'
Assert-True (($planOutput -join "`n") -match 'github.com/Jiahui-Kenneth/live-avatar/releases/download/v0.1.0') 'WhatIf prints fork release payload URL'
Assert-True (($planOutput -join "`n") -match 'huggingface.co/.+Qwen3.5') 'WhatIf prints selected model URL'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'Plan Only'))) 'WhatIf creates no install directory'

Complete-TestRun
