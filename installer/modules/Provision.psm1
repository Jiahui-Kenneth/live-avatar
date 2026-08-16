Set-StrictMode -Version 2.0

Import-Module "$PSScriptRoot\Download.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Layout.psm1" -ErrorAction Stop

function Test-ObjectProperty {
    param($Value, [string]$Name)
    return $null -ne $Value -and $Value.PSObject.Properties.Name -contains $Name
}

function Assert-PathBelowRoot {
    param([string]$Root, [string]$Path, [string]$Context)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escapes the allowed root"
    }
    return $pathFull
}

function Test-ZipEntrySafety {
    param([string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = ([string]$entry.FullName).Replace('\','/')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or @($name.Split('/')) -contains '..') {
                throw "unsafe archive entry: $name"
            }
        }
    }
    finally { $archive.Dispose() }
}

function Expand-SafeZip {
    param([string]$ArchivePath, [string]$Destination)
    Test-ZipEntrySafety $ArchivePath
    if (Test-Path -LiteralPath $Destination) { throw "staging directory already exists: $Destination" }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
}

function Assert-RequiredFiles {
    param($Component, [string]$Root)
    if (-not (Test-ObjectProperty $Component 'required_files')) { return }
    foreach ($relative in @($Component.required_files)) {
        $candidate = Assert-PathBelowRoot $Root (Join-Path $Root ([string]$relative).Replace('/','\')) 'required file'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "component '$($Component.id)' is missing required file '$relative'"
        }
    }
}

function Copy-FileAtomically {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Destination.new-$([guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $Source -Destination $temporary
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backup = "$Destination.old-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::Replace($temporary, $Destination, $backup, $true)
        if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force }
    }
    else { Move-Item -LiteralPath $temporary -Destination $Destination }
    return $Destination
}

function Write-ProvisionJson {
    param([string]$Path, $Value)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.new-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.old-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::Replace($temporary, $Path, $backup, $true)
        if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force }
    }
    else { Move-Item -LiteralPath $temporary -Destination $Path }
    return $Path
}

function Get-ComponentTarget {
    param($Component, $Layout)
    switch ([string]$Component.id) {
        'llama-cuda' { return Join-Path $Layout.version_root 'llama' }
        'llama-cudart' { return Join-Path $Layout.version_root 'llama' }
        'speech-to-speech-bundle' { return Join-Path $Layout.version_root 'speech-to-speech' }
        'livetalking-bundle' { return Join-Path $Layout.version_root 'LiveTalking' }
        'wav2lip-model' { return Join-Path $Layout.version_root 'LiveTalking\models\wav2lip.pth' }
        'default-avatar' { return Join-Path $Layout.avatars_root 'myavatar' }
        'python-wheelhouse' { return Join-Path $Layout.version_root '.wheelhouse-installed.json' }
        default {
            if ([string]$Component.install_kind -eq 'gguf') {
                return Join-Path $Layout.models_root ([string]$Component.filename)
            }
            throw "component '$($Component.id)' has no installation target"
        }
    }
}

function Invoke-CheckedProcess {
    param([string]$FilePath, [string[]]$Arguments, [scriptblock]$ProcessAction)
    if ($null -ne $ProcessAction) {
        $result = & $ProcessAction $FilePath $Arguments
        if ($null -ne $result -and [int]$result -ne 0) { throw "process failed with exit ${result}: $FilePath" }
        return
    }
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "process failed with exit ${LASTEXITCODE}: $FilePath" }
}

function Install-PythonRuntime {
    param($Component, $Layout, [string]$ArtifactPath, [scriptblock]$ProcessAction)
    $python = Join-Path $Layout.python_root 'python.exe'
    if (Test-Path -LiteralPath $python -PathType Leaf) {
        $version = @(& $python --version 2>&1)
        if ($LASTEXITCODE -eq 0 -and ($version -join ' ') -match '^Python 3\.11\.9') { return $python }
    }
    $arguments = @('/quiet','InstallAllUsers=0','PrependPath=0','Include_launcher=0','Include_test=0',"TargetDir=$($Layout.python_root)")
    Invoke-CheckedProcess $ArtifactPath $arguments $ProcessAction
    if ($null -eq $ProcessAction) {
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Python installer did not create python.exe' }
        $version = @(& $python --version 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch '^Python 3\.11\.9') { throw 'Python runtime is not exactly 3.11.9' }
    }
    return $python
}

function Install-ZipComponent {
    param($Component, $Layout, [string]$ArtifactPath)
    $target = Get-ComponentTarget $Component $Layout
    $stage = Join-Path $Layout.temp_root ("stage-$($Component.id)-" + [guid]::NewGuid().ToString('N'))
    Expand-SafeZip $ArtifactPath $stage
    try {
        Assert-RequiredFiles $Component $stage
        if ([string]$Component.install_kind -eq 'zip_overlay') {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $stage '*') -Destination $target -Recurse -Force
            return $target
        }
        if (Test-Path -LiteralPath $target -PathType Container) {
            try { Assert-RequiredFiles $Component $target; return $target } catch {}
            throw "component target already exists but is incomplete: $target"
        }
        $targetParent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        Move-Item -LiteralPath $stage -Destination $target
        $stage = $null
        return $target
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

function Install-Wheelhouse {
    param($Component, $Layout, [string]$ArtifactPath, [string]$WheelLockPath, [scriptblock]$ProcessAction)
    if ([string]::IsNullOrWhiteSpace($WheelLockPath) -or -not (Test-Path -LiteralPath $WheelLockPath -PathType Leaf)) {
        throw 'wheelhouse lock is required'
    }
    $marker = Get-ComponentTarget $Component $Layout
    $artifactHash = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $current = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$current.sha256 -eq $artifactHash) { return $marker }
    }
    $python = Join-Path $Layout.python_root 'python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Python 3.11.9 must be installed before the wheelhouse' }
    $wheelRoot = Join-Path $Layout.temp_root ("wheelhouse-" + [guid]::NewGuid().ToString('N'))
    Expand-SafeZip $ArtifactPath $wheelRoot
    try {
        $lock = Get-Content -LiteralPath $WheelLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('s2s','livetalking')) {
            $sourceRoot = if ($name -eq 's2s') { Join-Path $Layout.version_root 'speech-to-speech' } else { Join-Path $Layout.version_root 'LiveTalking' }
            if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "source bundle must be installed before wheelhouse: $name" }
            $venvRoot = Join-Path $sourceRoot '.venv'
            $venvPython = Join-Path $venvRoot 'Scripts\python.exe'
            if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
                Invoke-CheckedProcess $python @('-m','venv',$venvRoot) $ProcessAction
            }
            $requirements = @($lock.groups.$name | ForEach-Object { [string]$_ })
            Invoke-CheckedProcess $venvPython (@('-m','pip','install','--no-index','--find-links',$wheelRoot) + $requirements) $ProcessAction
            if ($name -eq 's2s') {
                Invoke-CheckedProcess $venvPython @('-m','pip','install','--no-index','--find-links',$wheelRoot,'--no-build-isolation','--no-deps','-e',$sourceRoot) $ProcessAction
            }
            Invoke-CheckedProcess $venvPython @('-m','pip','check') $ProcessAction
        }
        $value = [ordered]@{schema_version=1;sha256=$artifactHash;installed_at=(Get-Date).ToUniversalTime().ToString('o')}
        Write-ProvisionJson $marker $value | Out-Null
        return $marker
    }
    finally {
        if (Test-Path -LiteralPath $wheelRoot -PathType Container) { Remove-Item -LiteralPath $wheelRoot -Recurse -Force }
    }
}

function Install-TarAvatar {
    param($Component, $Layout, [string]$ArtifactPath, [scriptblock]$ProcessAction)
    $target = Get-ComponentTarget $Component $Layout
    if (Test-Path -LiteralPath $target -PathType Container) { return $target }
    $stage = Join-Path $Layout.temp_root ("avatar-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        if ($null -eq $ProcessAction) {
            $entries = @(& tar.exe -tzf $ArtifactPath)
            if ($LASTEXITCODE -ne 0) { throw 'unable to inspect default avatar archive' }
            foreach ($entry in $entries) {
                $name = ([string]$entry).Replace('\','/')
                if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or @($name.Split('/')) -contains '..') {
                    throw "unsafe avatar archive entry: $name"
                }
            }
        }
        Invoke-CheckedProcess 'tar.exe' @('-xzf',$ArtifactPath,'-C',$stage) $ProcessAction
        $candidate = Get-ChildItem -LiteralPath $stage -Directory -Recurse | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName 'full_imgs') -PathType Container
        } | Select-Object -First 1
        if ($null -eq $candidate) { throw 'default avatar archive does not contain full_imgs' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Move-Item -LiteralPath $candidate.FullName -Destination $target
        return $target
    }
    finally {
        if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Install-LiveAvatarComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$DownloadRoot,
        [string]$WheelLockPath,
        [scriptblock]$ProcessAction
    )
    $artifactPath = Join-Path ([IO.Path]::GetFullPath($DownloadRoot)) ([string]$Component.filename)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "verified artifact is missing: $artifactPath" }
    $kind = [string]$Component.install_kind
    switch ($kind) {
        'python_exe' { return Install-PythonRuntime $Component $Layout $artifactPath $ProcessAction }
        { $_ -in @('zip','zip_overlay','source_bundle') } { return Install-ZipComponent $Component $Layout $artifactPath }
        'wheelhouse' { return Install-Wheelhouse $Component $Layout $artifactPath $WheelLockPath $ProcessAction }
        'gguf' {
            $bytes = [IO.File]::ReadAllBytes($artifactPath)
            if ($bytes.Length -lt 4 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'GGUF') { throw 'model file does not have a GGUF header' }
            return Copy-FileAtomically $artifactPath (Get-ComponentTarget $Component $Layout)
        }
        'google_drive' { return Copy-FileAtomically $artifactPath (Get-ComponentTarget $Component $Layout) }
        'google_drive_archive' { return Install-TarAvatar $Component $Layout $artifactPath $ProcessAction }
        default { throw "unsupported install kind '$kind'" }
    }
}

function New-ModelArtifact {
    param($Model)
    $version = if (Test-ObjectProperty $Model 'revision') { [string]$Model.revision } else { 'unversioned' }
    return [pscustomobject]@{
        id = [string]$Model.id
        install_kind = 'gguf'
        version = $version
        filename = [string]$Model.filename
        urls = @([string]$Model.url)
        bytes = [int64]$Model.bytes
        sha256 = [string]$Model.sha256
    }
}

function Get-LiveAvatarInstallOrder {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Components)
    $index = 0
    $ranked = foreach ($component in $Components) {
        $priority = switch ([string]$component.id) {
            'python-3-11-9' { 10 }
            'llama-cuda' { 20 }
            'llama-cudart' { 21 }
            'speech-to-speech-bundle' { 30 }
            'livetalking-bundle' { 31 }
            'wav2lip-model' { 40 }
            'default-avatar' { 41 }
            'python-wheelhouse' { 50 }
            default {
                switch ([string]$component.install_kind) {
                    'python_exe' { 10 }
                    'source_bundle' { 30 }
                    'wheelhouse' { 50 }
                    default { 45 }
                }
            }
        }
        [pscustomobject]@{component=$component;priority=$priority;index=$index}
        $index++
    }
    return @($ranked | Sort-Object priority,index | ForEach-Object { $_.component })
}

function Assert-LiveAvatarFreeSpace {
    param($Layout, $Hardware, [int64]$InstallRequired, [int64]$ModelRequired)
    if (-not (Test-ObjectProperty $Hardware 'install_free_bytes') -or -not (Test-ObjectProperty $Hardware 'model_free_bytes')) { return }
    $installFree = [int64]$Hardware.install_free_bytes
    $modelFree = [int64]$Hardware.model_free_bytes
    $installDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$Layout.install_root))
    $modelDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$Layout.data_root))
    if ($installDrive.Equals($modelDrive, [StringComparison]::OrdinalIgnoreCase)) {
        $required = $InstallRequired + $ModelRequired
        if ([Math]::Min($installFree,$modelFree) -lt $required) {
            throw "insufficient free space: $required bytes required on $installDrive"
        }
        return
    }
    if ($installFree -lt $InstallRequired) { throw "insufficient program disk space: $InstallRequired bytes required" }
    if ($modelFree -lt $ModelRequired) { throw "insufficient model disk space: $ModelRequired bytes required" }
}

function Invoke-LiveAvatarProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Hardware,
        [Parameter(Mandatory = $true)]$ModelSelection,
        [Parameter(Mandatory = $true)][object[]]$Components,
        [Parameter(Mandatory = $true)]$Ports,
        [ValidateSet('Official','China')][string]$Mirror = 'Official',
        [string]$WheelLockPath,
        [scriptblock]$DownloadAction,
        [scriptblock]$ComponentAction,
        [scriptblock]$SmokeTestAction,
        [scriptblock]$StateAction,
        [switch]$PlanOnly
    )
    $modelArtifact = New-ModelArtifact $ModelSelection.model
    $artifacts = @($Components) + @($modelArtifact)
    $downloads = @($artifacts | ForEach-Object {
        $url = if (Test-ObjectProperty $_ 'urls') { [string]@($_.urls)[0] } else { [string]$_.url }
        [pscustomobject]@{id=[string]$_.id;filename=[string]$_.filename;bytes=[int64]$_.bytes;url=$url}
    })
    $requiredBytes = [int64]0
    foreach ($item in $downloads) { $requiredBytes += [int64]$item.bytes }
    $componentBytes = [int64]0
    foreach ($component in $Components) { $componentBytes += [int64]$component.bytes }
    $installRequired = [int64]([Math]::Ceiling($componentBytes * 2.0)) + 512MB
    $modelRequired = [int64]([Math]::Ceiling([int64]$modelArtifact.bytes * 1.10))
    if ($PlanOnly) {
        return [pscustomobject]@{
            plan_only=$true;downloads=$downloads;required_bytes=$requiredBytes
            install_required_bytes=$installRequired;model_required_bytes=$modelRequired
            model=$ModelSelection.model;mode=$ModelSelection.mode
        }
    }

    $states = New-Object Collections.Generic.List[string]
    function Add-State([string]$Name) {
        $states.Add($Name)
        if ($null -ne $StateAction) { & $StateAction $Name }
    }
    Add-State 'detect'
    Add-State 'choose-model'
    Add-State 'confirm-space'
    Assert-LiveAvatarFreeSpace $Layout $Hardware $installRequired $modelRequired
    Add-State 'download'
    $downloadRoot = Join-Path $Layout.cache_root 'downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    foreach ($artifact in $artifacts) {
        $destination = Join-Path $downloadRoot ([string]$artifact.filename)
        Get-VerifiedArtifact -Artifact $artifact -Destination $destination -Mirror $Mirror -DownloadAction $DownloadAction | Out-Null
    }
    Add-State 'verify'
    Add-State 'stage'
    foreach ($component in @(Get-LiveAvatarInstallOrder $Components)) {
        if ($null -ne $ComponentAction) { & $ComponentAction $component $Layout $downloadRoot | Out-Null }
        else { Install-LiveAvatarComponent -Component $component -Layout $Layout -DownloadRoot $downloadRoot -WheelLockPath $WheelLockPath | Out-Null }
    }
    if ($null -ne $ComponentAction) { & $ComponentAction $modelArtifact $Layout $downloadRoot | Out-Null }
    else { Install-LiveAvatarComponent -Component $modelArtifact -Layout $Layout -DownloadRoot $downloadRoot | Out-Null }
    Add-State 'configure'
    Write-LiveAvatarConfig -Layout $Layout -Hardware $Hardware -ModelSelection $ModelSelection -Ports $Ports | Out-Null
    Add-State 'smoke-test'
    if ($null -ne $SmokeTestAction) {
        $smoke = & $SmokeTestAction $Layout
        if ($smoke -is [bool] -and -not $smoke) { throw 'installation smoke test failed' }
    }
    Add-State 'activate-version'
    Set-LiveAvatarCurrentVersion -InstallRoot $Layout.install_root -Version $Layout.version | Out-Null
    return [pscustomobject]@{states=$states.ToArray();layout=$Layout;model=$ModelSelection.model;mode=$ModelSelection.mode;required_bytes=$requiredBytes}
}

Export-ModuleMember -Function Install-LiveAvatarComponent, Get-LiveAvatarInstallOrder, Invoke-LiveAvatarProvisioning
