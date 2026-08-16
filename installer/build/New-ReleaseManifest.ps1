param(
    [string]$SourceManifest = (Join-Path $PSScriptRoot '..\manifests\components.source.json'),
    [string]$DistDir = (Join-Path $PSScriptRoot '..\dist'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\manifests\components-v0.1.0.json'),
    [string]$WheelLockPath = (Join-Path $PSScriptRoot '..\manifests\python-requirements.lock.json'),
    [string]$Version = '0.1.0',
    [string]$ReleaseBaseUrl = 'https://github.com/Jiahui-Kenneth/live-avatar/releases/download/v0.1.0'
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $SourceManifest -Raw -Encoding UTF8 | ConvertFrom-Json
$components = New-Object Collections.Generic.List[object]
foreach ($component in @($source.components | Where-Object { $_.install_kind -notin @('git_source','python_package') })) { $components.Add($component) }
$artifacts = @(
    @{id='speech-to-speech-bundle';kind='source_bundle';filename="speech-to-speech-656099a-live-avatar-v$Version.zip";version=$Version;required=@('demo/server.py','demo/ui/avatar-api.js')},
    @{id='livetalking-bundle';kind='source_bundle';filename="LiveTalking-c963ad4-live-avatar-v$Version.zip";version=$Version;required=@('app.py','server/avatar_routes.py','web/embed.html')}
)
foreach ($item in $artifacts) {
    $path = Join-Path $DistDir $item.filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "release artifact missing: $path" }
    $component = [ordered]@{
        id=$item.id;install_kind=$item.kind;version=$item.version;filename=$item.filename
        urls=@("$($ReleaseBaseUrl.TrimEnd('/'))/$($item.filename)")
        bytes=[int64](Get-Item -LiteralPath $path).Length
        sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($item.required.Count -gt 0) { $component.required_files=@($item.required) }
    $components.Add([pscustomobject]$component)
}

if (-not (Test-Path -LiteralPath $WheelLockPath -PathType Leaf)) { throw "wheel lock missing: $WheelLockPath" }
$wheelLock = Get-Content -LiteralPath $WheelLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$externalPackages = [ordered]@{
    torch = 'torch-cu128-wheel'
    torchaudio = 'torchaudio-cu128-wheel'
    torchvision = 'torchvision-cu128-wheel'
}
foreach ($package in $externalPackages.Keys) {
    $wheel = @($wheelLock.wheels | Where-Object { [string]$_.filename -match "^$([regex]::Escape($package))-.*\+cu128-.*\.whl$" })
    if ($wheel.Count -ne 1) { throw "expected one resolved cu128 wheel for ${package}, found $($wheel.Count)" }
    $packageLock = @($source.components | Where-Object { [string]$_.install_kind -eq 'python_package' -and [string]$_.package -eq $package })
    if ($packageLock.Count -ne 1) { throw "expected one source package lock for ${package}, found $($packageLock.Count)" }
    $filename = [string]$wheel[0].filename
    $components.Add([pscustomobject][ordered]@{
        id = $externalPackages[$package]
        install_kind = 'python_wheel'
        version = [string]$packageLock[0].version
        filename = $filename
        urls = @("https://download.pytorch.org/whl/cu128/$([Uri]::EscapeDataString($filename))")
        bytes = [int64]$wheel[0].bytes
        sha256 = [string]$wheel[0].sha256
    })
}

$wheelhouseName = "python-wheelhouse-live-avatar-v$Version.zip"
$wheelhousePath = Join-Path $DistDir $wheelhouseName
if (-not (Test-Path -LiteralPath $wheelhousePath -PathType Leaf)) { throw "release artifact missing: $wheelhousePath" }
$components.Add([pscustomobject][ordered]@{
    id = 'python-wheelhouse'
    install_kind = 'wheelhouse'
    version = $Version
    filename = $wheelhouseName
    urls = @("$($ReleaseBaseUrl.TrimEnd('/'))/$wheelhouseName")
    bytes = [int64](Get-Item -LiteralPath $wheelhousePath).Length
    sha256 = (Get-FileHash -LiteralPath $wheelhousePath -Algorithm SHA256).Hash.ToLowerInvariant()
})
$manifest = [ordered]@{schema_version=1;catalog_version=$Version;components=$components.ToArray()}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($manifest | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
$OutputPath
