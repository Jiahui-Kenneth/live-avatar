. "$PSScriptRoot\TestHarness.ps1"

$fixtureRoot = Join-Path $env:TEMP ("live-avatar-release-manifest-" + [guid]::NewGuid().ToString('N'))
$distDir = Join-Path $fixtureRoot 'dist'
$sourcePath = Join-Path $fixtureRoot 'components.source.json'
$outputPath = Join-Path $fixtureRoot 'components-v0.1.0.json'
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
        }
    )
}
[IO.File]::WriteAllText($sourcePath, ($source | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))

foreach ($name in @(
    'speech-to-speech-656099a-live-avatar-v0.1.0.zip',
    'LiveTalking-c963ad4-live-avatar-v0.1.0.zip',
    'python-wheelhouse-live-avatar-v0.1.0.zip'
)) {
    [IO.File]::WriteAllBytes((Join-Path $distDir $name), [byte[]](1, 2, 3))
}

& "$PSScriptRoot\..\build\New-ReleaseManifest.ps1" `
    -SourceManifest $sourcePath -DistDir $distDir -OutputPath $outputPath | Out-Null

$manifest = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal 4 $manifest.components.Count 'source and release components are emitted on Windows PowerShell 5.1'
Assert-Equal 'python' $manifest.components[0].id 'source component order is preserved'
Assert-Equal 'python-wheelhouse' $manifest.components[3].id 'release artifact order is preserved'

Complete-TestRun
