param(
    [string]$DistDir = (Join-Path $PSScriptRoot '..\dist'),
    [string]$LockPath = (Join-Path $PSScriptRoot '..\manifests\python-requirements.lock.json'),
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\manifests\components-v0.1.0.json')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$errors = New-Object Collections.Generic.List[string]

function Add-ArtifactError([string]$Message) { $script:errors.Add($Message) }

function Get-ZipEntries([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try { return @($zip.Entries | ForEach-Object { $_.FullName.Replace('\','/') }) }
    finally { $zip.Dispose() }
}

function Read-ZipText([string]$Path, [string]$EntryName) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) { return $null }
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

function Get-ZipEntryHash([string]$Path, [string]$EntryName) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) { return $null }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
    }
    finally { $zip.Dispose() }
}

$expected = [ordered]@{
    s2s = Join-Path $DistDir 'speech-to-speech-656099a-live-avatar-v0.1.0.zip'
    livetalking = Join-Path $DistDir 'LiveTalking-c963ad4-live-avatar-v0.1.0.zip'
    wheelhouse = Join-Path $DistDir 'python-wheelhouse-live-avatar-v0.1.0.zip'
}
foreach ($name in $expected.Keys) {
    if (-not (Test-Path -LiteralPath $expected[$name] -PathType Leaf)) { Add-ArtifactError "missing $name archive: $($expected[$name])" }
}

$forbidden = '^(\.git|\.venv|logs?|models?|data|cache|temp)(/|$)'
foreach ($name in @('s2s','livetalking')) {
    $path = $expected[$name]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $entries = Get-ZipEntries $path
    foreach ($entry in $entries) { if ($entry -match $forbidden) { Add-ArtifactError "$name archive contains forbidden entry: $entry" } }
}

if (Test-Path -LiteralPath $expected.s2s -PathType Leaf) {
    $entries = Get-ZipEntries $expected.s2s
    foreach ($required in @('demo/avatar_capability.py','demo/ui/avatar-api.js','tests/test_demo_avatar_config.py')) {
        if ($entries -notcontains $required) { Add-ArtifactError "s2s archive missing $required" }
    }
    $marker = Read-ZipText $expected.s2s 'demo/ui/avatar-api.js'
    if ($null -eq $marker -or $marker -notmatch 'X-Live-Avatar-Capability') { Add-ArtifactError 's2s integration marker is missing' }
}

if (Test-Path -LiteralPath $expected.livetalking -PathType Leaf) {
    $entries = Get-ZipEntries $expected.livetalking
    foreach ($required in @('server/avatar_routes.py','server/avatar_auth.py','web/embed.html','tests/test_avatar_routes.py')) {
        if ($entries -notcontains $required) { Add-ArtifactError "LiveTalking archive missing $required" }
    }
    $marker = Read-ZipText $expected.livetalking 'server/avatar_routes.py'
    if ($null -eq $marker -or $marker -notmatch '/api/avatar/image-task') { Add-ArtifactError 'LiveTalking integration marker is missing' }
}

if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
    Add-ArtifactError "wheel lock missing: $LockPath"
}
else {
    $lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $wheels = @($lock.wheels)
    $externalWheels = @($wheels | Where-Object filename -Match '^(torch|torchvision|torchaudio)-.*\+cu128-')
    if ($wheels.Count -eq 0) { Add-ArtifactError 'wheel lock contains no resolved wheels' }
    if (Test-Path -LiteralPath $expected.wheelhouse -PathType Leaf) {
        $entries = @(Get-ZipEntries $expected.wheelhouse | Where-Object { $_ -match '\.whl$' })
        foreach ($wheel in $wheels) {
            if ($wheel.filename -notmatch '\.whl$' -or $wheel.sha256 -notmatch '^[0-9a-f]{64}$' -or [int64]$wheel.bytes -le 0) {
                Add-ArtifactError "invalid wheel lock entry: $($wheel.filename)"
                continue
            }
            if ($externalWheels.filename -contains $wheel.filename) {
                if ($entries -contains $wheel.filename) { Add-ArtifactError "wheelhouse must exclude external PyTorch wheel: $($wheel.filename)" }
                continue
            }
            if ($entries -notcontains $wheel.filename) { Add-ArtifactError "wheelhouse missing bundled locked wheel: $($wheel.filename)"; continue }
            $actual = Get-ZipEntryHash $expected.wheelhouse $wheel.filename
            if ($actual -ne $wheel.sha256) { Add-ArtifactError "wheel hash mismatch: $($wheel.filename)" }
        }
        foreach ($entry in $entries) {
            if (@($wheels.filename) -notcontains $entry) { Add-ArtifactError "wheelhouse contains unlocked wheel: $entry" }
        }
        $torchNames = @($externalWheels.filename)
        if ($torchNames.Count -ne 3) { Add-ArtifactError 'wheel lock must contain exactly three external cu128 PyTorch wheels' }
        foreach ($name in $torchNames) {
            if ($name -match '(\+cpu|cu121)' -or $name -notmatch 'cu128') { Add-ArtifactError "wrong torch build: $name" }
        }
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { Add-ArtifactError "component manifest missing: $ManifestPath" }
    else {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($wheel in $externalWheels) {
            $component = @($manifest.components | Where-Object filename -EQ $wheel.filename)
            if ($component.Count -ne 1) { Add-ArtifactError "manifest must contain one external wheel component: $($wheel.filename)"; continue }
            if ([string]$component[0].install_kind -ne 'python_wheel') { Add-ArtifactError "wrong install kind for external wheel: $($wheel.filename)" }
            if ([int64]$component[0].bytes -ne [int64]$wheel.bytes -or [string]$component[0].sha256 -ne [string]$wheel.sha256) {
                Add-ArtifactError "external wheel manifest metadata mismatch: $($wheel.filename)"
            }
            if ([string]@($component[0].urls)[0] -notmatch '^https://download\.pytorch\.org/whl/cu128/') {
                Add-ArtifactError "external wheel does not use the official PyTorch cu128 host: $($wheel.filename)"
            }
        }
        foreach ($component in @($manifest.components)) {
            $releaseHosted = @($component.urls | Where-Object { [string]$_ -match '^https://github\.com/.+/releases/download/' })
            if ($releaseHosted.Count -gt 0 -and [int64]$component.bytes -ge 2GB) {
                Add-ArtifactError "GitHub release asset is not under 2 GiB: $($component.filename)"
            }
        }
    }
}

if ($errors.Count -gt 0) {
    foreach ($errorMessage in $errors) { Write-Host "ERROR: $errorMessage" -ForegroundColor Red }
    exit 1
}
Write-Host 'Release artifacts verified.'
