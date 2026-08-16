[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('start','stop','status','doctor','repair','update','export-data','import-data')][string]$Command='start',
    [string]$InstallRoot=(Split-Path -Parent $PSScriptRoot),
    [string]$ArchivePath,
    [string]$ManifestPath,
    [string]$ModelManifestPath,
    [ValidateSet('Official','China')][string]$Mirror='Official',
    [switch]$NoBrowser
)

$ErrorActionPreference='Stop'
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
$installerRoot=Join-Path $InstallRoot 'installer'
$moduleRoot=Join-Path $installerRoot 'modules'
Import-Module (Join-Path $moduleRoot 'Layout.psm1') -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'Health.psm1') -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'Maintenance.psm1') -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'Migration.psm1') -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'Manifest.psm1') -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath=Join-Path $installerRoot 'manifests\components-v0.1.0.json' }
if ([string]::IsNullOrWhiteSpace($ModelManifestPath)) { $ModelManifestPath=Join-Path $installerRoot 'manifests\models.json' }
$wheelLockPath=Join-Path $installerRoot 'manifests\python-requirements.lock.json'

function Write-LauncherJson {
    param([string]$Path,$Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporary="$Path.new-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup="$Path.old-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::Replace($temporary,$Path,$backup,$true)
        if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force }
    } else { Move-Item -LiteralPath $temporary -Destination $Path }
}

function Get-AdminToken {
    param([string]$DataRoot)
    $path=Join-Path $DataRoot 'config\security\avatar-admin-token.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if ([string]$data.token -match '^[A-Za-z0-9_-]{43}$') { return [string]$data.token }
        throw 'avatar management token file is invalid'
    }
    $bytes=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try {$rng.GetBytes($bytes)} finally {$rng.Dispose()}
    $token=[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    Write-LauncherJson $path ([ordered]@{schema_version=1;token=$token;created_at=(Get-Date).ToUniversalTime().ToString('o')})
    return $token
}

function Get-ProcessFile([string]$DataRoot) { return Join-Path $DataRoot 'config\processes.json' }
function Read-ProcessRecords([string]$DataRoot) {
    $path=Get-ProcessFile $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $value=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    return @($value.records)
}
function Write-ProcessRecords([string]$DataRoot,[object[]]$Records) {
    Write-LauncherJson (Get-ProcessFile $DataRoot) ([ordered]@{schema_version=1;records=@($Records);updated_at=(Get-Date).ToUniversalTime().ToString('o')})
}

function Get-DoctorReport($Layout) {
    $checks=New-Object Collections.Generic.List[object]
    foreach ($item in @(
        @{id='python';path=$Layout.python_path;kind='file'},@{id='llama';path=(Join-Path $Layout.llama_root 'llama-server.exe');kind='file'},
        @{id='s2s';path=(Join-Path $Layout.s2s_root '.venv\Scripts\python.exe');kind='file'},@{id='livetalking';path=(Join-Path $Layout.livetalking_root '.venv\Scripts\python.exe');kind='file'},
        @{id='model';path=$Layout.model_path;kind='file'},@{id='avatars';path=(Join-Path $Layout.data_root 'avatars');kind='dir'}
    )) {
        $ok=if ($item.kind -eq 'file') {Test-Path -LiteralPath $item.path -PathType Leaf} else {Test-Path -LiteralPath $item.path -PathType Container}
        $checks.Add([pscustomobject]@{id=$item.id;healthy=[bool]$ok;path=$item.path})
    }
    if (Test-Path -LiteralPath $Layout.model_path -PathType Leaf) {
        $stream=[IO.File]::OpenRead($Layout.model_path)
        try {$header=New-Object byte[] 4;$count=$stream.Read($header,0,4);$gguf=$count -eq 4 -and [Text.Encoding]::ASCII.GetString($header) -eq 'GGUF'} finally {$stream.Dispose()}
        if (-not $gguf) {($checks|Where-Object id -eq 'model').healthy=$false}
    }
    $runtime=Test-LiveAvatarHealth -Layout $Layout
    return [pscustomobject]@{healthy=@($checks|Where-Object {-not $_.healthy}).Count -eq 0 -and $runtime.healthy;files=$checks.ToArray();runtime=$runtime}
}

$layout=Resolve-LiveAvatarLayout -InstallRoot $InstallRoot
switch ($Command) {
    'start' {
        $existing=Read-ProcessRecords $layout.data_root
        if ($existing.Count -gt 0) {
            $health=Test-LiveAvatarHealth -Layout $layout
            if ($health.healthy) {[pscustomobject]@{status='already-running';health=$health}|ConvertTo-Json -Depth 10;break}
            $stale=Stop-LiveAvatarServices -Layout $layout -ProcessRecords $existing
            $refused=@($stale|Where-Object status -eq 'refused')
            if ($refused.Count -gt 0) {throw 'refusing to replace process records with PID identity mismatches'}
        }
        $token=Get-AdminToken $layout.data_root
        $records=Start-LiveAvatarServices -Layout $layout -AdminToken $token
        Write-ProcessRecords $layout.data_root $records
        $health=Test-LiveAvatarHealth -Layout $layout
        if (-not $health.healthy) {
            Stop-LiveAvatarServices -Layout $layout -ProcessRecords $records|Out-Null
            throw 'services started but full health verification failed'
        }
        if (-not $NoBrowser) {Start-Process "http://127.0.0.1:$($layout.config.ports.demo)/"|Out-Null}
        [pscustomobject]@{status='started';records=$records;health=$health}|ConvertTo-Json -Depth 10
    }
    'stop' {
        $records=Read-ProcessRecords $layout.data_root
        if ($records.Count -eq 0) {[pscustomobject]@{status='stopped';detail='no process records'}|ConvertTo-Json;break}
        $result=Stop-LiveAvatarServices -Layout $layout -ProcessRecords $records
        $keepIds=@($result|Where-Object status -eq 'refused'|ForEach-Object pid)
        $keep=@($records|Where-Object {$keepIds -contains $_.pid})
        if ($keep.Count -gt 0) {Write-ProcessRecords $layout.data_root $keep} else {Remove-Item -LiteralPath (Get-ProcessFile $layout.data_root) -Force -ErrorAction SilentlyContinue}
        [pscustomobject]@{status=$(if($keep.Count){'partial'}else{'stopped'});results=$result}|ConvertTo-Json -Depth 10
    }
    'status' {
        $health=Test-LiveAvatarHealth -Layout $layout
        [pscustomobject]@{status=$(if($health.healthy){'running'}else{'degraded'});version=$layout.config.app_version;model=$layout.config.model.id;processes=(Read-ProcessRecords $layout.data_root);health=$health}|ConvertTo-Json -Depth 10
    }
    'doctor' {Get-DoctorReport $layout|ConvertTo-Json -Depth 10}
    'repair' {
        $componentCatalog=Import-LiveAvatarManifest -Path $ManifestPath -Kind Component
        $modelCatalog=Import-LiveAvatarManifest -Path $ModelManifestPath -Kind Model
        $model=$modelCatalog.models|Where-Object id -eq $layout.config.model.id|Select-Object -First 1
        if ($null -eq $model) {throw "active model is absent from model manifest: $($layout.config.model.id)"}
        $result=Repair-LiveAvatarInstall -Layout $layout -Components @($componentCatalog.components) -Model $model -Mirror $Mirror -WheelLockPath $wheelLockPath
        [pscustomobject]@{status='repaired';result=$result;doctor=(Get-DoctorReport $layout)}|ConvertTo-Json -Depth 12
    }
    'update' {
        $oldVersion=[string]$layout.config.app_version
        $bootstrap=Join-Path $installerRoot 'bootstrap.ps1'
        $profile=Join-Path $layout.data_root 'hardware\profile.json'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -InstallRoot $layout.install_root -DataRoot $layout.data_root -Unattended -ManifestPath $ManifestPath -ModelManifestPath $ModelManifestPath -HardwareProfilePath $profile -Mirror $Mirror
        if ($LASTEXITCODE -ne 0) {throw "update bootstrap failed with exit $LASTEXITCODE"}
        $oldRecords=Read-ProcessRecords $layout.data_root
        if ($oldRecords.Count -gt 0) {Stop-LiveAvatarServices -Layout $layout -ProcessRecords $oldRecords|Out-Null}
        try {
            $newLayout=Resolve-LiveAvatarLayout -InstallRoot $InstallRoot
            $records=Start-LiveAvatarServices -Layout $newLayout -AdminToken (Get-AdminToken $newLayout.data_root)
            Write-ProcessRecords $newLayout.data_root $records
            [pscustomobject]@{status='updated';old_version=$oldVersion;new_version=$newLayout.config.app_version}|ConvertTo-Json
        } catch {
            Set-LiveAvatarCurrentVersion -InstallRoot $InstallRoot -Version $oldVersion|Out-Null
            $oldLayout=Resolve-LiveAvatarLayout -InstallRoot $InstallRoot
            $records=Start-LiveAvatarServices -Layout $oldLayout -AdminToken (Get-AdminToken $oldLayout.data_root)
            Write-ProcessRecords $oldLayout.data_root $records
            throw
        }
    }
    'export-data' {
        if ([string]::IsNullOrWhiteSpace($ArchivePath)) {throw '-ArchivePath is required for export-data'}
        [pscustomobject]@{status='exported';archive=(Export-LiveAvatarData -DataRoot $layout.data_root -Destination $ArchivePath)}|ConvertTo-Json
    }
    'import-data' {
        if ([string]::IsNullOrWhiteSpace($ArchivePath)) {throw '-ArchivePath is required for import-data'}
        if ((Read-ProcessRecords $layout.data_root).Count -gt 0) {throw 'stop Live Avatar before importing data'}
        [pscustomobject]@{status='imported';result=(Import-LiveAvatarData -DataRoot $layout.data_root -ArchivePath $ArchivePath)}|ConvertTo-Json -Depth 10
    }
}
