[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'LiveAvatar'),
    [string]$DataRoot,
    [ValidateSet('Recommended','Faster','HigherQuality')][string]$Preference = 'Recommended',
    [ValidateSet('Official','China')][string]$Mirror = 'Official',
    [switch]$Unattended,
    [string]$ManifestPath,
    [string]$ModelManifestPath,
    [string]$WheelLockPath,
    [string]$HardwareProfilePath,
    [string]$NvidiaSmiPath = (Join-Path $env:WINDIR 'System32\nvidia-smi.exe'),
    [string]$FixtureSourceRoot,
    [string]$OverlayRoot,
    [switch]$OverlayOnly,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot 'manifests\components-v0.1.0.json' }
if ([string]::IsNullOrWhiteSpace($ModelManifestPath)) { $ModelManifestPath = Join-Path $PSScriptRoot 'manifests\models.json' }
if ([string]::IsNullOrWhiteSpace($WheelLockPath)) { $WheelLockPath = Join-Path $PSScriptRoot 'manifests\python-requirements.lock.json' }
if ([string]::IsNullOrWhiteSpace($OverlayRoot)) { $OverlayRoot = Join-Path $PSScriptRoot 'overlays' }
Import-Module "$PSScriptRoot\modules\Layout.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\modules\Provision.psm1" -ErrorAction Stop

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if ($OverlayOnly) {
    $activeLayout = Resolve-LiveAvatarLayout -InstallRoot $InstallRoot
    $appliedOverlays = @(Install-LiveAvatarOverlays -Layout $activeLayout -OverlayRoot $OverlayRoot -Required)
    [pscustomobject]@{
        status='updated-overlays';version=[string]$activeLayout.config.app_version
        install_root=$InstallRoot;data_root=[string]$activeLayout.data_root;overlays=$appliedOverlays
    } | ConvertTo-Json -Depth 10
    return
}

Import-Module "$PSScriptRoot\modules\Manifest.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\modules\Hardware.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\modules\ModelSelection.psm1" -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path $InstallRoot 'data' }
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$components = Import-LiveAvatarManifest -Path $ManifestPath -Kind Component
$models = Import-LiveAvatarManifest -Path $ModelManifestPath -Kind Model

if (-not [string]::IsNullOrWhiteSpace($HardwareProfilePath)) {
    $hardware = Get-Content -LiteralPath $HardwareProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    $hardware = Get-LiveAvatarHardwareProfile -NvidiaSmiPath $NvidiaSmiPath -InstallPath $InstallRoot -ModelPath $DataRoot
}

$selection = Select-LiveAvatarModel -Profile $hardware -Catalog $models -Preference $Preference
if (-not $selection.preference_available) { throw $selection.disabled_reason }
$version = [string]$components.catalog_version
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$') { $version = '0.1.0' }
$ports = [pscustomobject]@{llm=8080;livetalking=8010;s2s=8765;demo=7860}

if (-not $Unattended -and -not $WhatIf) {
    Import-Module "$PSScriptRoot\ui\InstallWizard.psm1" -Force
    $choice = Show-LiveAvatarInstallWizard -InstallRoot $InstallRoot -DataRoot $DataRoot `
        -Hardware $hardware -Catalog $models -Selection $selection -Components @($components.components) -Mirror $Mirror
    if ($null -eq $choice -or -not $choice.confirmed) { throw 'Installation was cancelled.' }
    $InstallRoot = [IO.Path]::GetFullPath([string]$choice.install_root)
    $DataRoot = [IO.Path]::GetFullPath([string]$choice.data_root)
    $Preference = [string]$choice.preference
    $Mirror = [string]$choice.mirror
    $selection = Select-LiveAvatarModel -Profile $hardware -Catalog $models -Preference $Preference
    if (-not $selection.preference_available) { throw $selection.disabled_reason }
}

if ($WhatIf) {
    $layout = [pscustomobject]@{
        install_root=$InstallRoot;data_root=$DataRoot;version=$version
        version_root=(Join-Path $InstallRoot "app\versions\$version")
        python_root=(Join-Path $InstallRoot 'runtime\Python311')
        launcher_root=(Join-Path $InstallRoot 'launcher')
        config_root=(Join-Path $DataRoot 'config');hardware_root=(Join-Path $DataRoot 'hardware')
        models_root=(Join-Path $DataRoot 'models');avatars_root=(Join-Path $DataRoot 'avatars')
        cache_root=(Join-Path $DataRoot 'cache');logs_root=(Join-Path $DataRoot 'logs');temp_root=(Join-Path $DataRoot 'temp')
        app_config_path=(Join-Path $InstallRoot "app\versions\$version\app.json")
        hardware_profile_path=(Join-Path $DataRoot 'hardware\profile.json')
    }
    $plan = Invoke-LiveAvatarProvisioning -Layout $layout -Hardware $hardware -ModelSelection $selection `
        -Components @($components.components) -Ports $ports -Mirror $Mirror -PlanOnly
    [pscustomobject]@{
        status='what-if';install_root=$InstallRoot;data_root=$DataRoot;gpu=$hardware.gpu_name;vram_mib=$hardware.vram_mib
        selected_model=$selection.model.id;mode=$selection.mode;reason=$selection.reason
        required_bytes=$plan.required_bytes;install_required_bytes=$plan.install_required_bytes
        model_required_bytes=$plan.model_required_bytes;downloads=$plan.downloads
    } | ConvertTo-Json -Depth 10
    return
}

$layout = New-LiveAvatarLayout -InstallRoot $InstallRoot -DataRoot $DataRoot -Version $version
$downloadAction = $null
if (-not [string]::IsNullOrWhiteSpace($FixtureSourceRoot)) {
    $fixtureRoot = [IO.Path]::GetFullPath($FixtureSourceRoot)
    $downloadAction = {
        param($url,$partial)
        $name = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
        $source = Join-Path $fixtureRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "fixture artifact missing: $name" }
        Copy-Item -LiteralPath $source -Destination $partial
    }.GetNewClosure()
}

$smokeTest = {
    param($activeLayout)
    if (-not (Test-Path -LiteralPath $activeLayout.app_config_path -PathType Leaf)) { return $false }
    $modelPath = Join-Path $activeLayout.models_root ([string]$selection.model.filename)
    return (Test-Path -LiteralPath $modelPath -PathType Leaf)
}.GetNewClosure()

$invokeParameters = @{
    Layout=$layout;Hardware=$hardware;ModelSelection=$selection;Components=@($components.components);Ports=$ports
    Mirror=$Mirror;WheelLockPath=$WheelLockPath;OverlayRoot=$OverlayRoot;DownloadAction=$downloadAction;SmokeTestAction=$smokeTest
}
$result = Invoke-LiveAvatarProvisioning @invokeParameters
[pscustomobject]@{
    status='installed';version=$version;install_root=$InstallRoot;data_root=$DataRoot
    model=$result.model.id;mode=$result.mode;states=$result.states
} | ConvertTo-Json -Depth 10
