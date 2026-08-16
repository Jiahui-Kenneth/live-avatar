param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$DistDir = (Join-Path $PSScriptRoot '..\dist'),
    [string]$S2sSource = 'https://github.com/huggingface/speech-to-speech.git',
    [string]$LiveTalkingSource = 'https://gitee.com/lipku/LiveTalking.git',
    [string]$Version = '0.1.0'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$s2sRevision = '656099afffda445a3a3cef8ffee55871c9b6123c'
$ltRevision = 'c963ad409c556918b7d23999bf87c47a7c05c932'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("live-avatar-source-build-" + [Guid]::NewGuid().ToString('N'))

function Invoke-Git([string[]]$Arguments) {
    & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git failed with exit ${LASTEXITCODE}: $($Arguments -join ' ')" }
}

function Remove-SafeBuildTree([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $safe = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
    if (-not $full.StartsWith($safe + '\', [StringComparison]::OrdinalIgnoreCase) -and -not $full.Equals($safe, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to remove path outside build root: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function Apply-TrackedPatch([string]$PatchName, [string]$Target) {
    $check = 'git -C "{0}" cat-file blob HEAD:patches/{1} | git -C "{2}" apply --check --binary -' -f $RepoRoot,$PatchName,$Target
    cmd.exe /d /s /c $check
    if ($LASTEXITCODE -ne 0) { throw "$PatchName preflight failed" }
    $apply = 'git -C "{0}" cat-file blob HEAD:patches/{1} | git -C "{2}" apply --binary -' -f $RepoRoot,$PatchName,$Target
    cmd.exe /d /s /c $apply
    if ($LASTEXITCODE -ne 0) { throw "$PatchName apply failed" }
    Invoke-Git @('-C',$Target,'diff','--check')
}

function New-PatchedBundle([string]$Source, [string]$Revision, [string]$PatchName, [string]$WorkName, [string]$ArchiveName, [bool]$CopyEmbed) {
    $work = Join-Path $temporaryRoot $WorkName
    Invoke-Git @('clone','--no-hardlinks',$Source,$work)
    Invoke-Git @('-C',$work,'checkout','--detach',$Revision)
    $actual = (& git -C $work rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Revision) { throw "$WorkName revision mismatch: $actual" }
    Apply-TrackedPatch $PatchName $work
    if ($CopyEmbed) { Copy-Item -LiteralPath (Join-Path $RepoRoot 'web\embed.html') -Destination (Join-Path $work 'web\embed.html') -Force }
    foreach ($name in @('.git','.venv','logs','models','data','cache','temp')) {
        $target = Join-Path $work $name
        if (Test-Path -LiteralPath $target) { Remove-SafeBuildTree $target }
    }
    $archive = Join-Path $DistDir $ArchiveName
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($work, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
    return $archive
}

New-Item -ItemType Directory -Path $temporaryRoot,$DistDir -Force | Out-Null
try {
    $s2s = New-PatchedBundle $S2sSource $s2sRevision 's2s-integration.patch' 'speech-to-speech' "speech-to-speech-656099a-live-avatar-v$Version.zip" $false
    $lt = New-PatchedBundle $LiveTalkingSource $ltRevision 'livetalking-integration.patch' 'LiveTalking' "LiveTalking-c963ad4-live-avatar-v$Version.zip" $true
    [pscustomobject]@{speech_to_speech=$s2s;livetalking=$lt} | ConvertTo-Json -Compress
}
finally { Remove-SafeBuildTree $temporaryRoot }
