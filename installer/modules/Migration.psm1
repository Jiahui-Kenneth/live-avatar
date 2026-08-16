Set-StrictMode -Version 2.0

function Assert-SafeMigrationEntry {
    param([string]$Name)
    $normalized = $Name.Replace('\','/')
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or @($normalized.Split('/')) -contains '..') { throw "unsafe migration entry: $Name" }
    if ($normalized -ne 'config/settings.json' -and $normalized -notmatch '^avatars/[A-Za-z0-9_-]+(?:/.*)?$') { throw "migration entry is not allowed: $Name" }
    return $normalized
}

function Remove-MigrationStage {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'live-avatar-migration-*') { throw "unsafe migration cleanup: $full" }
    if (Test-Path -LiteralPath $full -PathType Container) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function Write-MigrationJson {
    param([string]$Path,$Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporary = "$Path.new-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $temporary -Destination $Path
}

function Export-LiveAvatarData {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot,[Parameter(Mandatory = $true)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $data = [IO.Path]::GetFullPath($DataRoot)
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("live-avatar-migration-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $avatars = Join-Path $data 'avatars'
        if (Test-Path -LiteralPath $avatars -PathType Container) { Copy-Item -LiteralPath $avatars -Destination (Join-Path $stage 'avatars') -Recurse }
        $settings = Join-Path $data 'config\settings.json'
        if (Test-Path -LiteralPath $settings -PathType Leaf) {
            New-Item -ItemType Directory -Path (Join-Path $stage 'config') -Force | Out-Null
            Copy-Item -LiteralPath $settings -Destination (Join-Path $stage 'config\settings.json')
        }
        $destinationFull = [IO.Path]::GetFullPath($Destination)
        New-Item -ItemType Directory -Path (Split-Path -Parent $destinationFull) -Force | Out-Null
        if (Test-Path -LiteralPath $destinationFull -PathType Leaf) { throw "migration archive already exists: $destinationFull" }
        [IO.Compression.ZipFile]::CreateFromDirectory($stage,$destinationFull,[IO.Compression.CompressionLevel]::Optimal,$false)
        return $destinationFull
    }
    finally { Remove-MigrationStage $stage }
}

function Import-LiveAvatarData {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DataRoot,[Parameter(Mandatory = $true)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveFull = [IO.Path]::GetFullPath($ArchivePath)
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("live-avatar-migration-" + [guid]::NewGuid().ToString('N'))
    $zip = [IO.Compression.ZipFile]::OpenRead($archiveFull)
    try { foreach ($entry in $zip.Entries) { Assert-SafeMigrationEntry $entry.FullName | Out-Null } } finally { $zip.Dispose() }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($archiveFull,$stage)
        $data = [IO.Path]::GetFullPath($DataRoot)
        $avatarRoot = Join-Path $data 'avatars'
        New-Item -ItemType Directory -Path $avatarRoot -Force | Out-Null
        $imported = New-Object Collections.Generic.List[string]
        $idMap = @{}
        $sourceAvatars = Join-Path $stage 'avatars'
        if (Test-Path -LiteralPath $sourceAvatars -PathType Container) {
            foreach ($avatar in @(Get-ChildItem -LiteralPath $sourceAvatars -Directory)) {
                $oldId = [string]$avatar.Name
                $newId = $oldId
                if ($newId -notmatch '^[A-Za-z0-9_-]+$') { $newId = 'avatar_import_' + [guid]::NewGuid().ToString('N').Substring(0,8) }
                while (Test-Path -LiteralPath (Join-Path $avatarRoot $newId)) { $newId = $oldId + '_import_' + [guid]::NewGuid().ToString('N').Substring(0,8) }
                $target = Join-Path $avatarRoot $newId
                Move-Item -LiteralPath $avatar.FullName -Destination $target
                $metadataPath = Join-Path $target 'metadata.json'
                if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
                    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($metadata.PSObject.Properties.Name -contains 'id') { $metadata.id = $newId }
                    else { $metadata | Add-Member -NotePropertyName id -NotePropertyValue $newId }
                    Write-MigrationJson $metadataPath $metadata
                }
                $idMap[$oldId] = $newId
                $imported.Add($newId)
            }
        }
        $settingsPath = Join-Path $stage 'config\settings.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.PSObject.Properties.Name -contains 'active_avatar' -and $idMap.ContainsKey([string]$settings.active_avatar)) { $settings.active_avatar = $idMap[[string]$settings.active_avatar] }
            Write-MigrationJson (Join-Path $data 'config\settings.json') $settings
        }
        return [pscustomobject]@{imported_avatars=$imported.ToArray();settings_imported=(Test-Path -LiteralPath $settingsPath -PathType Leaf)}
    }
    finally { Remove-MigrationStage $stage }
}

Export-ModuleMember -Function Export-LiveAvatarData, Import-LiveAvatarData
