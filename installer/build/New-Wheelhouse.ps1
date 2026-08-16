param(
    [Parameter(Mandatory = $true)][string]$PythonPath,
    [string]$DistDir = (Join-Path $PSScriptRoot '..\dist'),
    [string]$LockPath = (Join-Path $PSScriptRoot '..\manifests\python-requirements.lock.json'),
    [string]$Version = '0.1.0'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw "Python not found: $PythonPath" }
$pythonVersion = (& $PythonPath --version 2>&1).ToString().Trim()
if ($pythonVersion -ne 'Python 3.11.9') { throw "wheelhouse requires Python 3.11.9, got $pythonVersion" }
$lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$lock.schema_version -ne 1) { throw 'unsupported wheel lock schema' }
$stage = Join-Path ([IO.Path]::GetTempPath()) ("live-avatar-wheelhouse-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage,$DistDir -Force | Out-Null

function Remove-SafeWheelTree([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath($stage).TrimEnd('\')
    if (-not $full.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe wheel staging cleanup: $full" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

try {
    foreach ($groupName in @('s2s','livetalking')) {
        $requirements = @($lock.groups.$groupName)
        if ($requirements.Count -eq 0) { throw "empty requirements group: $groupName" }
        foreach ($requirement in $requirements) {
            if ([string]$requirement -notmatch '^[A-Za-z0-9_.-]+==[^\s]+$') { throw "unpinned requirement: $requirement" }
        }
        $requirementsPath = Join-Path $stage "$groupName-requirements.txt"
        [IO.File]::WriteAllLines($requirementsPath, [string[]]$requirements, (New-Object Text.UTF8Encoding($false)))
        & $PythonPath -m pip download --only-binary=:all: --dest $stage --index-url https://pypi.org/simple --extra-index-url https://download.pytorch.org/whl/cu128 --requirement $requirementsPath
        if ($LASTEXITCODE -ne 0) { throw "pip download failed for $groupName" }
        Remove-Item -LiteralPath $requirementsPath -Force
    }
    $wheelFiles = @(Get-ChildItem -LiteralPath $stage -Filter '*.whl' -File | Sort-Object Name)
    if ($wheelFiles.Count -eq 0) { throw 'wheelhouse is empty' }
    $torchFiles = @($wheelFiles | Where-Object Name -Match '^(torch|torchvision|torchaudio)-')
    if ($torchFiles.Count -lt 3) { throw 'cu128 torch trio is missing' }
    foreach ($file in $torchFiles) {
        if ($file.Name -match '(\+cpu|cu121)' -or $file.Name -notmatch 'cu128') { throw "unexpected torch wheel: $($file.Name)" }
    }
    $lock.wheels = @($wheelFiles | ForEach-Object {
        [pscustomobject]@{
            filename=$_.Name
            bytes=[int64]$_.Length
            sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($LockPath), ($lock | ConvertTo-Json -Depth 20), $encoding)
    $archive = Join-Path $DistDir "python-wheelhouse-live-avatar-v$Version.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
    [pscustomobject]@{archive=$archive;wheel_count=$wheelFiles.Count;bytes=(Get-Item $archive).Length} | ConvertTo-Json -Compress
}
finally { Remove-SafeWheelTree $stage }
