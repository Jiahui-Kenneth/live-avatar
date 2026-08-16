Set-StrictMode -Version 2.0

function ConvertTo-ForwardSlashPath {
    param([string]$Path)
    return $Path.Replace('\','/').TrimStart('/')
}

function Get-RelativePathCompat {
    param([string]$BasePath, [string]$TargetPath)
    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $targetFull = [IO.Path]::GetFullPath($TargetPath)
    $baseUri = New-Object Uri($baseFull)
    $targetUri = New-Object Uri($targetFull)
    return ConvertTo-ForwardSlashPath ([Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()))
}

function Write-AtomicJson {
    param([string]$Path, $Value)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = "$full.tmp-$([Guid]::NewGuid().ToString('N'))"
    $backup = "$full.bak-$([Guid]::NewGuid().ToString('N'))"
    $encoding = New-Object Text.UTF8Encoding($false)
    $json = $Value | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($temporary, $json, $encoding)
    try {
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            [IO.File]::Replace($temporary, $full, $backup, $true)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        }
        else { Move-Item -LiteralPath $temporary -Destination $full }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $full
}

function New-LiveAvatarLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$')][string]$Version
    )
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $data = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $layout = [ordered]@{
        install_root = $install
        data_root = $data
        version = $Version
        version_root = Join-Path $install "app\versions\$Version"
        python_root = Join-Path $install 'runtime\Python311'
        launcher_root = Join-Path $install 'launcher'
        config_root = Join-Path $data 'config'
        hardware_root = Join-Path $data 'hardware'
        models_root = Join-Path $data 'models'
        avatars_root = Join-Path $data 'avatars'
        cache_root = Join-Path $data 'cache'
        logs_root = Join-Path $data 'logs'
        temp_root = Join-Path $data 'temp'
    }
    foreach ($path in @($layout.version_root,$layout.python_root,$layout.launcher_root,$layout.config_root,$layout.hardware_root,$layout.models_root,$layout.avatars_root,$layout.cache_root,$layout.logs_root,$layout.temp_root)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $layout.app_config_path = Join-Path $layout.version_root 'app.json'
    $layout.hardware_profile_path = Join-Path $layout.hardware_root 'profile.json'
    return [pscustomobject]$layout
}

function Get-ConfigDataRootValue {
    param($Layout)
    $install = [IO.Path]::GetFullPath([string]$Layout.install_root).TrimEnd('\')
    $data = [IO.Path]::GetFullPath([string]$Layout.data_root).TrimEnd('\')
    $prefix = $install + '\'
    if ($data.Equals($install, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    if ($data.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return Get-RelativePathCompat $install $data }
    return $data
}

function Write-LiveAvatarConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Hardware,
        [Parameter(Mandatory = $true)]$ModelSelection,
        [Parameter(Mandatory = $true)]$Ports
    )
    $versionRelative = "app/versions/$($Layout.version)"
    $config = [ordered]@{
        schema_version = 1
        app_version = [string]$Layout.version
        data_root = Get-ConfigDataRootValue $Layout
        components = [ordered]@{
            app = [ordered]@{ relative_path=$versionRelative }
            python = [ordered]@{ relative_path='runtime/Python311/python.exe'; version='3.11.9' }
            llama = [ordered]@{ relative_path="$versionRelative/llama"; version='b10437' }
            s2s = [ordered]@{ relative_path="$versionRelative/speech-to-speech" }
            livetalking = [ordered]@{ relative_path="$versionRelative/LiveTalking" }
            launcher = [ordered]@{ relative_path='launcher' }
        }
        model = [ordered]@{
            id = [string]$ModelSelection.model.id
            relative_path = "models/$($ModelSelection.model.filename)"
            mode = [string]$ModelSelection.mode
            ctx_size = [int]$ModelSelection.model.ctx_size
            gpu_layers = [int]$ModelSelection.gpu_layers
            reasoning = [string]$ModelSelection.model.reasoning
            jinja = [bool]$ModelSelection.model.jinja
        }
        ports = [ordered]@{
            llm = [int]$Ports.llm
            livetalking = [int]$Ports.livetalking
            s2s = [int]$Ports.s2s
            demo = [int]$Ports.demo
        }
        runtime = [ordered]@{
            python = '3.11.9'
            torch = '2.11.0+cu128'
            torchvision = '0.26.0+cu128'
            torchaudio = '2.11.0+cu128'
            cuda = '12.8'
        }
        hardware_profile = 'hardware/profile.json'
    }
    Write-AtomicJson $Layout.hardware_profile_path $Hardware | Out-Null
    return Write-AtomicJson $Layout.app_config_path $config
}

function Set-LiveAvatarCurrentVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$')][string]$Version,
        [scriptblock]$BeforeCommit
    )
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $versionRoot = Join-Path $install "app\versions\$Version"
    $configPath = Join-Path $versionRoot 'app.json'
    if (-not (Test-Path -LiteralPath $versionRoot -PathType Container)) { throw "version is not staged: $Version" }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "version config is missing: $configPath" }
    if ($null -ne $BeforeCommit) { & $BeforeCommit }
    return Write-AtomicJson (Join-Path $install 'current.json') ([ordered]@{schema_version=1;version=$Version})
}

function Get-LiveAvatarCurrentVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $path = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'current.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$value.schema_version -ne 1 -or [string]$value.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') { throw 'current.json is invalid' }
    return $value
}

function Resolve-LiveAvatarLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $current = Get-LiveAvatarCurrentVersion $install
    if ($null -eq $current) { throw 'no active Live Avatar version' }
    $versionRoot = Join-Path $install "app\versions\$($current.version)"
    $configPath = Join-Path $versionRoot 'app.json'
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dataRoot = if ([IO.Path]::IsPathRooted([string]$config.data_root)) {
        [IO.Path]::GetFullPath([string]$config.data_root)
    } else {
        [IO.Path]::GetFullPath((Join-Path $install ([string]$config.data_root).Replace('/','\')))
    }
    return [pscustomobject]@{
        install_root = $install
        data_root = $dataRoot
        version_root = $versionRoot
        config_path = $configPath
        config = $config
        model_path = [IO.Path]::GetFullPath((Join-Path $dataRoot ([string]$config.model.relative_path).Replace('/','\')))
        python_path = [IO.Path]::GetFullPath((Join-Path $install ([string]$config.components.python.relative_path).Replace('/','\')))
        llama_root = [IO.Path]::GetFullPath((Join-Path $install ([string]$config.components.llama.relative_path).Replace('/','\')))
        s2s_root = [IO.Path]::GetFullPath((Join-Path $install ([string]$config.components.s2s.relative_path).Replace('/','\')))
        livetalking_root = [IO.Path]::GetFullPath((Join-Path $install ([string]$config.components.livetalking.relative_path).Replace('/','\')))
        launcher_root = [IO.Path]::GetFullPath((Join-Path $install ([string]$config.components.launcher.relative_path).Replace('/','\')))
        avatars_root = Join-Path $dataRoot 'avatars'
        cache_root = Join-Path $dataRoot 'cache'
        logs_root = Join-Path $dataRoot 'logs'
        temp_root = Join-Path $dataRoot 'temp'
    }
}

Export-ModuleMember -Function New-LiveAvatarLayout, Write-LiveAvatarConfig, Set-LiveAvatarCurrentVersion, Get-LiveAvatarCurrentVersion, Resolve-LiveAvatarLayout
