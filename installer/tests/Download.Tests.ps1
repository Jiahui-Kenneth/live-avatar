. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Download.psm1" -Force

function New-TestRoot {
    $path = Join-Path $env:TEMP ("live-avatar-download-tests-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

$helloHash = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
$artifact = [pscustomobject]@{
    id='tiny'; urls=@('https://example.invalid/tiny.bin'); bytes=5; sha256=$helloHash
}

$root = New-TestRoot
$dest = Join-Path $root 'tiny.bin'
$result = Get-VerifiedArtifact -Artifact $artifact -Destination $dest -DownloadAction {
    param($url,$partial) [IO.File]::WriteAllBytes($partial,[Text.Encoding]::UTF8.GetBytes('hello'))
}
Assert-Equal 'hello' ([IO.File]::ReadAllText($result)) 'verified content'
Assert-True (-not (Test-Path "$dest.partial")) 'partial promoted'

$root = New-TestRoot
$dest = Join-Path $root 'resume.bin'
[IO.File]::WriteAllText("$dest.partial", 'he')
$sawResume = $false
$result = Get-VerifiedArtifact -Artifact $artifact -Destination $dest -DownloadAction {
    param($url,$partial)
    $script:sawResume = ([IO.File]::ReadAllText($partial) -eq 'he')
    [IO.File]::AppendAllText($partial, 'llo')
}
Assert-True $sawResume 'existing partial is offered for resume'
Assert-Equal 'hello' ([IO.File]::ReadAllText($result)) 'resumed content verifies'

$root = New-TestRoot
$dest = Join-Path $root 'short.bin'
Assert-Throws {
    Get-VerifiedArtifact -Artifact $artifact -Destination $dest -DownloadAction {
        param($url,$partial) [IO.File]::WriteAllText($partial, 'hell')
    }
} 'wrong byte size is rejected'
Assert-True (Test-Path "$dest.partial") 'wrong-size partial is retained'

$root = New-TestRoot
$dest = Join-Path $root 'wrong-hash.bin'
Assert-Throws {
    Get-VerifiedArtifact -Artifact $artifact -Destination $dest -DownloadAction {
        param($url,$partial) [IO.File]::WriteAllText($partial, 'world')
    }
} 'wrong hash is rejected'
Assert-Equal 1 @(Get-ChildItem -LiteralPath $root -Filter 'wrong-hash.bin.bad-*').Count 'bad hash is quarantined'

$root = New-TestRoot
$dest = Join-Path $root 'fallback.bin'
$fallbackArtifact = [pscustomobject]@{
    id='fallback';
    urls=@('https://official.example.invalid/tiny.bin','https://hf-mirror.com/tiny.bin');
    bytes=5; sha256=$helloHash
}
$called = @()
$result = Get-VerifiedArtifact -Artifact $fallbackArtifact -Destination $dest -MaxAttemptsPerUrl 1 -DownloadAction {
    param($url,$partial)
    $script:called += $url
    if ($url -match 'official') { throw 'network unavailable' }
    [IO.File]::WriteAllText($partial, 'hello')
}
Assert-Equal 2 $called.Count 'mirror fallback tries two URLs'
Assert-True ($called[0] -match 'official') 'official preference tries official first'
Assert-Equal 'hello' ([IO.File]::ReadAllText($result)) 'fallback download verifies'

$root = New-TestRoot
$dest = Join-Path $root 'china.bin'
$called = @()
Get-VerifiedArtifact -Artifact $fallbackArtifact -Destination $dest -Mirror China -MaxAttemptsPerUrl 1 -DownloadAction {
    param($url,$partial)
    $script:called += $url
    [IO.File]::WriteAllText($partial, 'hello')
} | Out-Null
Assert-True ($called[0] -match 'hf-mirror') 'China preference tries mirror first'

$root = New-TestRoot
$dest = Join-Path $root 'retry.bin'
$attempts = 0
$result = Get-VerifiedArtifact -Artifact $artifact -Destination $dest -MaxAttemptsPerUrl 2 -DownloadAction {
    param($url,$partial)
    $script:attempts++
    if ($script:attempts -eq 1) { throw 'transient network failure' }
    [IO.File]::WriteAllText($partial, 'hello')
}
Assert-Equal 2 $attempts 'transient network exception is retried'
Assert-Equal 'hello' ([IO.File]::ReadAllText($result)) 'retry result verifies'

Complete-TestRun
