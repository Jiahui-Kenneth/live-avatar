. "$PSScriptRoot\TestHarness.ps1"

$fixtureRoot = Join-Path $env:TEMP ("live-avatar-release-manifest-" + [guid]::NewGuid().ToString('N'))
$distDir = Join-Path $fixtureRoot 'dist'
$sourcePath = Join-Path $fixtureRoot 'components.source.json'
$outputPath = Join-Path $fixtureRoot 'components-v0.1.0.json'
$wheelLockPath = Join-Path $fixtureRoot 'python-requirements.lock.json'
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

$source = [ordered]@{
    schema_version = 1
    catalog_version = 'source'
    components = @(
        [ordered]@{
            id = 'python'
            install_kind = 'python_exe'
            version = '3.11.9'
            filename = 'python.exe'
            urls = @('https://example.invalid/python.exe')
            bytes = 1
            sha256 = ('a' * 64)
        },
        [ordered]@{id='torch-package';install_kind='python_package';version='2.11.0+cu128';package='torch';index_url='https://download.pytorch.org/whl/cu128'},
        [ordered]@{id='torchaudio-package';install_kind='python_package';version='2.11.0+cu128';package='torchaudio';index_url='https://download.pytorch.org/whl/cu128'},
        [ordered]@{id='torchvision-package';install_kind='python_package';version='0.26.0+cu128';package='torchvision';index_url='https://download.pytorch.org/whl/cu128'}
    )
}
[IO.File]::WriteAllText($sourcePath, ($source | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))

$torchWheels = @(
    [ordered]@{filename='torch-2.11.0+cu128-cp311-cp311-win_amd64.whl';bytes=11;sha256=('1' * 64)},
    [ordered]@{filename='torchaudio-2.11.0+cu128-cp311-cp311-win_amd64.whl';bytes=12;sha256=('2' * 64)},
    [ordered]@{filename='torchvision-0.26.0+cu128-cp311-cp311-win_amd64.whl';bytes=13;sha256=('3' * 64)}
)
$wheelLock = [ordered]@{schema_version=1;wheels=$torchWheels}
[IO.File]::WriteAllText($wheelLockPath, ($wheelLock | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))

foreach ($name in @(
    'speech-to-speech-656099a-live-avatar-v0.1.0.zip',
    'LiveTalking-c963ad4-live-avatar-v0.1.0.zip',
    'python-wheelhouse-live-avatar-v0.1.0.zip'
)) {
    [IO.File]::WriteAllBytes((Join-Path $distDir $name), [byte[]](1, 2, 3))
}

& "$PSScriptRoot\..\build\New-ReleaseManifest.ps1" `
    -SourceManifest $sourcePath -DistDir $distDir -OutputPath $outputPath -WheelLockPath $wheelLockPath | Out-Null

$manifest = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal 7 $manifest.components.Count 'source, release archives, and external torch wheels are emitted on Windows PowerShell 5.1'
Assert-Equal 'python' $manifest.components[0].id 'source component order is preserved'
Assert-Equal 'torch-cu128-wheel' $manifest.components[3].id 'torch wheel is a separately downloaded component'
Assert-Equal 'torchaudio-cu128-wheel' $manifest.components[4].id 'torchaudio wheel is a separately downloaded component'
Assert-Equal 'torchvision-cu128-wheel' $manifest.components[5].id 'torchvision wheel is a separately downloaded component'
Assert-Equal 'python-wheelhouse' $manifest.components[6].id 'release artifact order is preserved'
Assert-True ($manifest.components[6].urls[0] -match '^https://github\.com/Jiahui-Kenneth/live-avatar/releases/download/v0\.1\.0/') 'release payload uses the publishing fork'
Assert-Equal 'python_wheel' $manifest.components[3].install_kind 'external torch component uses the python wheel install kind'
Assert-Equal '2.11.0+cu128' $manifest.components[3].version 'external wheel keeps the locked package version'
Assert-True ($manifest.components[3].urls[0] -match '^https://download\.pytorch\.org/whl/cu128/torch-2\.11\.0%2Bcu128-') 'torch wheel uses the official PyTorch cu128 URL with an encoded plus'
Assert-Equal 11 ([int64]$manifest.components[3].bytes) 'torch wheel size is copied from the resolved lock'
Assert-Equal ('1' * 64) $manifest.components[3].sha256 'torch wheel hash is copied from the resolved lock'

Complete-TestRun
