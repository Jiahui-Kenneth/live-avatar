param(
    [string]$SourceManifest = (Join-Path $PSScriptRoot '..\manifests\components.source.json'),
    [string]$DistDir = (Join-Path $PSScriptRoot '..\dist'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\manifests\components-v0.1.0.json'),
    [string]$Version = '0.1.0',
    [string]$ReleaseBaseUrl = 'https://github.com/HeiXia2077/live-avatar/releases/download/v0.1.0'
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $SourceManifest -Raw -Encoding UTF8 | ConvertFrom-Json
$components = New-Object Collections.Generic.List[object]
foreach ($component in @($source.components | Where-Object { $_.install_kind -notin @('git_source','python_package') })) { $components.Add($component) }
$artifacts = @(
    @{id='speech-to-speech-bundle';kind='source_bundle';filename="speech-to-speech-656099a-live-avatar-v$Version.zip";version=$Version;required=@('demo/server.py','demo/ui/avatar-api.js')},
    @{id='livetalking-bundle';kind='source_bundle';filename="LiveTalking-c963ad4-live-avatar-v$Version.zip";version=$Version;required=@('app.py','server/avatar_routes.py','web/embed.html')},
    @{id='python-wheelhouse';kind='wheelhouse';filename="python-wheelhouse-live-avatar-v$Version.zip";version=$Version;required=@()}
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
$manifest = [ordered]@{schema_version=1;catalog_version=$Version;components=$components.ToArray()}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($manifest | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
$OutputPath
