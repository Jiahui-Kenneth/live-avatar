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

function Install-LiveAvatarOverlays {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$OverlayRoot
    )
    $applied = New-Object Collections.Generic.List[string]
    $relativePaths = @('LiveTalking\web\embed.html')
    foreach ($relativePath in $relativePaths) {
        $source = Join-Path $OverlayRoot $relativePath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $destination = Assert-PathBelowRoot $Layout.version_root (Join-Path $Layout.version_root $relativePath) 'overlay destination'
        Copy-FileAtomically $source $destination | Out-Null
        $applied.Add($destination)
    }
    return $applied.ToArray()
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
    param([string]$FilePath, [string[]]$Arguments, [scriptblock]$ProcessAction, [switch]$WaitForExit)
    if ($null -ne $ProcessAction) {
        $result = & $ProcessAction $FilePath $Arguments ([bool]$WaitForExit)
        if ($null -ne $result -and [int]$result -ne 0) { throw "process failed with exit ${result}: $FilePath" }
        return
    }
    if ($WaitForExit) {
        $quotedArguments = @($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' })
        $process = Start-Process -FilePath $FilePath -ArgumentList $quotedArguments -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "process failed with exit $($process.ExitCode): $FilePath" }
        return
    }
    $global:LASTEXITCODE = 0
    & $FilePath @Arguments
    $exitCode = [int]$global:LASTEXITCODE
    if ($exitCode -ne 0) { throw "process failed with exit ${exitCode}: $FilePath" }
}

function Test-PythonRuntime3119 {
    param([string]$PythonPath, [scriptblock]$ValidationAction)
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { return $false }
    if ($null -ne $ValidationAction) { return [bool](& $ValidationAction $PythonPath) }
    $process = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = [IO.Path]::GetFullPath($PythonPath)
        $startInfo.Arguments = '--version'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { return $false }
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $version = "$standardOutput $standardError".Trim()
        return $process.ExitCode -eq 0 -and $version -match '^Python 3\.11\.9'
    }
    catch { return $false }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Get-PythonRootsFromInstallerLog {
    param([string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    $seen = @{}
    $roots = New-Object Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $LogPath -Encoding UTF8)) {
        if ([string]$line -notmatch "Setting string variable 'TargetDir' to value '([^']+)'") { continue }
        try { $root = [IO.Path]::GetFullPath([string]$Matches[1]).TrimEnd('\') } catch { continue }
        if (-not $seen.ContainsKey($root)) {
            $seen[$root] = $true
            $roots.Add($root)
        }
    }
    return @($roots)
}

function Import-PythonRuntime {
    param([string]$SourceRoot, $Layout, [scriptblock]$ValidationAction)
    $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $target = [IO.Path]::GetFullPath([string]$Layout.python_root).TrimEnd('\')
    if ($source.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-PythonRuntime3119 (Join-Path $source 'python.exe') $ValidationAction)) { return $false }

    $stage = "$target.import-$([guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $source -Destination $stage -Recurse
        if (-not (Test-PythonRuntime3119 (Join-Path $stage 'python.exe') $ValidationAction)) {
            throw 'Imported Python runtime is not exactly 3.11.9'
        }
        if (Test-Path -LiteralPath $target -PathType Container) {
            $quarantine = "$target.incomplete-$([guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $target -Destination $quarantine
            try { Move-Item -LiteralPath $stage -Destination $target }
            catch {
                if (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $quarantine)) {
                    Move-Item -LiteralPath $quarantine -Destination $target
                }
                throw
            }
            if (Test-Path -LiteralPath $quarantine -PathType Container) {
                Remove-Item -LiteralPath $quarantine -Recurse -Force
            }
        }
        else { Move-Item -LiteralPath $stage -Destination $target }
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Install-PythonRuntime {
    param($Component, $Layout, [string]$ArtifactPath, [scriptblock]$ProcessAction, [scriptblock]$PythonValidationAction)
    $python = Join-Path $Layout.python_root 'python.exe'
    if (Test-PythonRuntime3119 $python $PythonValidationAction) { return $python }

    $logPath = Join-Path $Layout.logs_root ("python-3.11.9-install-$([guid]::NewGuid().ToString('N')).log")
    $arguments = @('/quiet','InstallAllUsers=0','PrependPath=0','Include_launcher=0','Include_test=0',"TargetDir=$($Layout.python_root)",'/log',$logPath)
    Invoke-CheckedProcess $ArtifactPath $arguments $ProcessAction -WaitForExit
    if (Test-PythonRuntime3119 $python $PythonValidationAction) { return $python }

    foreach ($existingRoot in @(Get-PythonRootsFromInstallerLog $logPath)) {
        if (Import-PythonRuntime $existingRoot $Layout $PythonValidationAction) {
            if (Test-PythonRuntime3119 $python $PythonValidationAction) { return $python }
        }
    }
    throw 'Python installer did not create or expose a usable Python 3.11.9 runtime'
}

function Install-ZipComponent {
    param($Component, $Layout, [string]$ArtifactPath, [switch]$Repair)
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
            if (-not $Repair) { throw "component target already exists but is incomplete: $target" }
            $quarantine = "$target.bad-$(Get-Date -Format 'yyyyMMdd-HHmmssfff')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            Move-Item -LiteralPath $target -Destination $quarantine
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
    param($Component, $Layout, [string]$ArtifactPath, [string]$DownloadRoot, [string]$WheelLockPath, [scriptblock]$ProcessAction)
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
        foreach ($wheel in @($lock.wheels)) {
            $filename = [string]$wheel.filename
            if ([IO.Path]::GetFileName($filename) -ne $filename -or $filename -notmatch '\.whl$') {
                throw "unsafe wheel lock filename: $filename"
            }
            $destination = Join-Path $wheelRoot $filename
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                $external = Join-Path ([IO.Path]::GetFullPath($DownloadRoot)) $filename
                if (-not (Test-Path -LiteralPath $external -PathType Leaf)) { throw "locked wheel is missing: $filename" }
                Copy-Item -LiteralPath $external -Destination $destination
            }
            $file = Get-Item -LiteralPath $destination
            if ([int64]$file.Length -ne [int64]$wheel.bytes) { throw "wheel size mismatch: $filename" }
            $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne [string]$wheel.sha256) { throw "wheel hash mismatch: $filename" }
        }
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
        [scriptblock]$ProcessAction,
        [scriptblock]$PythonValidationAction,
        [switch]$Repair
    )
    $artifactPath = Join-Path ([IO.Path]::GetFullPath($DownloadRoot)) ([string]$Component.filename)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "verified artifact is missing: $artifactPath" }
    $kind = [string]$Component.install_kind
    switch ($kind) {
        'python_exe' { return Install-PythonRuntime $Component $Layout $artifactPath $ProcessAction $PythonValidationAction }
        { $_ -in @('zip','zip_overlay','source_bundle') } { return Install-ZipComponent $Component $Layout $artifactPath -Repair:$Repair }
        'python_wheel' { return $artifactPath }
        'wheelhouse' { return Install-Wheelhouse $Component $Layout $artifactPath $DownloadRoot $WheelLockPath $ProcessAction }
        'gguf' {
            $header = New-Object byte[] 4
            $stream = [IO.File]::OpenRead($artifactPath)
            try {
                $offset = 0
                while ($offset -lt $header.Length) {
                    $read = $stream.Read($header, $offset, $header.Length - $offset)
                    if ($read -eq 0) { break }
                    $offset += $read
                }
            }
            finally { $stream.Dispose() }
            if ($offset -lt 4 -or [Text.Encoding]::ASCII.GetString($header) -ne 'GGUF') { throw 'model file does not have a GGUF header' }
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
            { $_ -like '*-cu128-wheel' } { 49 }
            'python-wheelhouse' { 50 }
            default {
                switch ([string]$component.install_kind) {
                    'python_exe' { 10 }
                    'source_bundle' { 30 }
                    'python_wheel' { 49 }
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
        [string]$OverlayRoot,
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
    $modelRequired = [int64]([Math]::Ceiling([int64]$modelArtifact.bytes * 1.10)) + 6GB
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
    if (-not [string]::IsNullOrWhiteSpace($OverlayRoot)) {
        Add-State 'apply-overlays'
        Install-LiveAvatarOverlays -Layout $Layout -OverlayRoot $OverlayRoot | Out-Null
    }
    Add-State 'smoke-test'
    if ($null -ne $SmokeTestAction) {
        $smoke = & $SmokeTestAction $Layout
        if ($smoke -is [bool] -and -not $smoke) { throw 'installation smoke test failed' }
    }
    Add-State 'activate-version'
    Set-LiveAvatarCurrentVersion -InstallRoot $Layout.install_root -Version $Layout.version | Out-Null
    return [pscustomobject]@{states=$states.ToArray();layout=$Layout;model=$ModelSelection.model;mode=$ModelSelection.mode;required_bytes=$requiredBytes}
}

Export-ModuleMember -Function Install-LiveAvatarComponent, Install-LiveAvatarOverlays, Get-LiveAvatarInstallOrder, Invoke-LiveAvatarProvisioning
