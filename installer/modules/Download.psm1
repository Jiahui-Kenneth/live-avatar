Set-StrictMode -Version 2.0

function Get-ArtifactUrls {
    param($Artifact, [string]$Mirror)
    $urls = @()
    if ($Artifact.PSObject.Properties.Name -contains 'urls') { $urls = @($Artifact.urls) }
    if ($urls.Count -eq 0 -and $Artifact.PSObject.Properties.Name -contains 'file_id') {
        $id = [Uri]::EscapeDataString([string]$Artifact.file_id)
        $urls = @("https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t")
    }
    if ($urls.Count -eq 0) { throw "artifact '$($Artifact.id)' has no download URL" }
    foreach ($url in $urls) {
        $uri = $null
        if (-not [Uri]::TryCreate([string]$url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
            throw "artifact '$($Artifact.id)' has a non-HTTPS URL"
        }
    }
    if ($Mirror -eq 'China') {
        return @($urls | Sort-Object { if ([string]$_ -match '(hf-mirror|aliyun|gitee)') { 0 } else { 1 } })
    }
    return @($urls)
}

function Get-VerifiedFileState {
    param([string]$Path, [int64]$Bytes, [string]$Sha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    if ([int64](Get-Item -LiteralPath $Path).Length -ne $Bytes) { return 'wrong_size' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) { return 'wrong_hash' }
    return 'verified'
}

function Move-BadArtifact {
    param([string]$Path, [string]$BadBase = $Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $bad = "$BadBase.bad-$stamp"
    if (Test-Path -LiteralPath $bad) { $bad = "$bad-$([Guid]::NewGuid().ToString('N').Substring(0,8))" }
    Move-Item -LiteralPath $Path -Destination $bad
    return $bad
}

function Get-VerifiedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateSet('Official','China')][string]$Mirror = 'Official',
        [string]$CurlPath = 'curl.exe',
        [scriptblock]$DownloadAction,
        [ValidateRange(1,10)][int]$MaxAttemptsPerUrl = 2
    )
    foreach ($name in @('id','bytes','sha256')) {
        if ($Artifact.PSObject.Properties.Name -notcontains $name) { throw "artifact is missing '$name'" }
    }
    $bytes = [int64]$Artifact.bytes
    $sha256 = ([string]$Artifact.sha256).ToLowerInvariant()
    if ($bytes -le 0) { throw 'artifact bytes must be positive' }
    if ($sha256 -notmatch '^[0-9a-f]{64}$') { throw 'artifact sha256 is invalid' }
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $existingState = Get-VerifiedFileState $destinationPath $bytes $sha256
    if ($existingState -eq 'verified') { return $destinationPath }
    if ($existingState -ne 'missing') { Move-BadArtifact $destinationPath | Out-Null }

    $partial = "$destinationPath.partial"
    if ($null -eq $DownloadAction) {
        $DownloadAction = {
            param($url,$partialPath)
            & $CurlPath -L --fail --retry 5 --retry-delay 5 -C - -o $partialPath $url
            if ($LASTEXITCODE -ne 0) { throw "download failed with exit $LASTEXITCODE" }
        }
    }

    $errors = New-Object Collections.Generic.List[string]
    foreach ($url in @(Get-ArtifactUrls $Artifact $Mirror)) {
        for ($attempt = 1; $attempt -le $MaxAttemptsPerUrl; $attempt++) {
            try {
                & $DownloadAction ([string]$url) $partial
                if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) { throw 'download did not create the partial file' }
                $length = [int64](Get-Item -LiteralPath $partial).Length
                if ($length -ne $bytes) { throw "artifact size mismatch: expected $bytes bytes, got $length" }
                $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $sha256) {
                    $bad = Move-BadArtifact $partial $destinationPath
                    throw "artifact hash mismatch; retained as $bad"
                }
                Move-Item -LiteralPath $partial -Destination $destinationPath
                return $destinationPath
            }
            catch {
                $message = "URL $url attempt $attempt failed: $($_.Exception.Message)"
                $errors.Add($message)
                if ($_.Exception.Message -match '(size mismatch|hash mismatch)') { throw $message }
                if ($attempt -lt $MaxAttemptsPerUrl) { Start-Sleep -Milliseconds 100 }
            }
        }
    }
    throw "artifact '$($Artifact.id)' download failed: $($errors -join '; ')"
}

Export-ModuleMember -Function Get-VerifiedArtifact
