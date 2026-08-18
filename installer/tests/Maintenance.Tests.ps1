. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Maintenance.psm1" -Force

$root = Join-Path $env:TEMP ('Live Avatar Lifecycle ' + [guid]::NewGuid().ToString('N'))
$versionRoot = Join-Path $root 'app/versions/0.1.0'
$python = Join-Path $root 'runtime/Python311/python.exe'
$llamaRoot = Join-Path $versionRoot 'llama'
$s2sRoot = Join-Path $versionRoot 'speech-to-speech'
$ltRoot = Join-Path $versionRoot 'LiveTalking'
$dataRoot = Join-Path $root 'data'
foreach ($path in @($llamaRoot,$s2sRoot,$ltRoot,(Split-Path -Parent $python),$dataRoot)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
foreach ($path in @((Join-Path $llamaRoot 'llama-server.exe'),$python,(Join-Path $s2sRoot '.venv/Scripts/python.exe'),(Join-Path $ltRoot '.venv/Scripts/python.exe'))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllBytes($path, [byte[]](77,90))
}
$modelPath = Join-Path $dataRoot 'models/model.gguf'
New-Item -ItemType Directory -Path (Split-Path -Parent $modelPath) -Force | Out-Null
[IO.File]::WriteAllBytes($modelPath, [Text.Encoding]::ASCII.GetBytes('GGUFfixture'))
$layout = [pscustomobject]@{
    install_root=$root;data_root=$dataRoot;version_root=$versionRoot;llama_root=$llamaRoot;s2s_root=$s2sRoot
    livetalking_root=$ltRoot;python_path=$python;model_path=$modelPath;logs_root=(Join-Path $dataRoot 'logs');temp_root=(Join-Path $dataRoot 'temp')
    config=[pscustomobject]@{
        model=[pscustomobject]@{id='qwen35-test';ctx_size=8192;gpu_layers=999;reasoning='off';jinja=$true}
        ports=[pscustomobject]@{llm=8080;livetalking=8010;s2s=8765;demo=7860}
    }
}

$specs = Get-LiveAvatarServiceSpecs -Layout $layout -AdminToken ('x' * 43)
Assert-Equal 'llama,livetalking,s2s,demo' (($specs | ForEach-Object id) -join ',') 'service dependency order'
Assert-True (($specs | Where-Object id -eq 'llama').arguments -contains '--reasoning') 'llama keeps reasoning disabled'
Assert-True (($specs | Where-Object id -eq 's2s').environment.LIVETALKING_URL -eq 'http://127.0.0.1:8010') 's2s bridge URL is explicit'
Assert-True (($specs | Where-Object id -eq 's2s').environment.HF_HOME -eq (Join-Path $dataRoot 'cache/huggingface')) 'speech model cache moves with user data'
Assert-True (($specs | Where-Object id -eq 'livetalking').environment.LIVE_AVATAR_DATA_DIR -eq $dataRoot) 'avatar data root is externalized'

$serviceExecutables = @((Join-Path $llamaRoot 'llama-server.exe'),(Join-Path $s2sRoot '.venv/Scripts/python.exe'),(Join-Path $ltRoot '.venv/Scripts/python.exe'))
foreach ($serviceExecutable in $serviceExecutables) { Copy-Item -LiteralPath $env:ComSpec -Destination $serviceExecutable -Force }
$defaultStarted = Start-LiveAvatarServices -Layout $layout -AdminToken ('x' * 43) -HealthProbe { $true }
Assert-Equal 'llama,livetalking,s2s,demo' (($defaultStarted | ForEach-Object component_id) -join ',') 'default service starter retains access to module-private helpers'
foreach ($record in $defaultStarted) { Stop-Process -Id ([int]$record.pid) -Force -ErrorAction SilentlyContinue }

$started = New-Object Collections.Generic.List[object]
$stopped = New-Object Collections.Generic.List[int]
$nextPid = [ref]100
$starter = {
    param($spec)
    $nextPid.Value++
    $record = [pscustomobject]@{pid=$nextPid.Value;executable=$spec.executable;start_time='2026-08-16T00:00:00Z';component_id=$spec.id;arguments_hash='hash'}
    $started.Add($record)
    return $record
}
Assert-Throws {
    Start-LiveAvatarServices -Layout $layout -AdminToken ('x' * 43) -ProcessStarter $starter `
        -HealthProbe { param($id,$activeLayout) if ($id -eq 's2s') { throw 'fixture health failure' } } `
        -ProcessStopper { param($record) $stopped.Add([int]$record.pid) }
} 'failed service health aborts startup'
Assert-Equal '103,102,101' (($stopped | ForEach-Object { [string]$_ }) -join ',') 'startup failure rolls back only started services in reverse order'

$records = @(
    [pscustomobject]@{pid=201;executable=(Join-Path $llamaRoot 'llama-server.exe');start_time='2026-08-16T00:00:00Z';component_id='llama';arguments_hash='a'},
    [pscustomobject]@{pid=202;executable=(Join-Path $s2sRoot '.venv/Scripts/python.exe');start_time='2026-08-16T00:00:00Z';component_id='s2s';arguments_hash='b'}
)
$stopCalls = New-Object Collections.Generic.List[int]
$stopResult = Stop-LiveAvatarServices -Layout $layout -ProcessRecords $records `
    -ProcessInspector { param($pidValue) if ($pidValue -eq 201) { return [pscustomobject]@{pid=$pidValue;executable='C:\Windows\System32\notepad.exe';start_time='2026-08-16T00:00:00Z'} }; return [pscustomobject]@{pid=$pidValue;executable=$records[1].executable;start_time=$records[1].start_time} } `
    -ProcessStopper { param($record) $stopCalls.Add([int]$record.pid) }
Assert-Equal '202' (($stopCalls | ForEach-Object { [string]$_ }) -join ',') 'stop refuses unrelated PID and stops matching service'
Assert-True (($stopResult | Where-Object pid -eq 201).status -eq 'refused') 'unrelated PID is reported refused'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repairSource = Join-Path $root 'repair-source'
New-Item -ItemType Directory -Path $repairSource -Force | Out-Null
$repairZip = Join-Path $repairSource 's2s.zip'
$zipStream = [IO.File]::Open($repairZip,[IO.FileMode]::Create)
try {
    $zip = New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create)
    try { $entry=$zip.CreateEntry('demo/server.py'); $writer=New-Object IO.StreamWriter($entry.Open()); try {$writer.Write('app=1')} finally {$writer.Dispose()} } finally {$zip.Dispose()}
} finally {$zipStream.Dispose()}
$modelSource = Join-Path $repairSource 'model.gguf'
[IO.File]::WriteAllBytes($modelSource,[Text.Encoding]::ASCII.GetBytes('GGUFhealthy'))
[IO.File]::WriteAllBytes($modelPath,[Text.Encoding]::ASCII.GetBytes('BROKEN'))
$repairComponent = [pscustomobject]@{
    id='speech-to-speech-bundle';install_kind='source_bundle';version='0.1.0';filename='s2s.zip'
    urls=@('https://fixture.invalid/s2s.zip');bytes=[int64](Get-Item $repairZip).Length
    sha256=(Get-FileHash $repairZip -Algorithm SHA256).Hash.ToLowerInvariant();required_files=@('demo/server.py')
}
$repairModel = [pscustomobject]@{
    id='qwen35-test';revision=('a'*40);filename='model.gguf';url='https://fixture.invalid/model.gguf'
    bytes=[int64](Get-Item $modelSource).Length;sha256=(Get-FileHash $modelSource -Algorithm SHA256).Hash.ToLowerInvariant()
}
$repairSources=@{'s2s.zip'=$repairZip;'model.gguf'=$modelSource}
$repairResult=Repair-LiveAvatarInstall -Layout $layout -Components @($repairComponent) -Model $repairModel `
    -DownloadAction { param($url,$partial);$name=[IO.Path]::GetFileName(([Uri]$url).AbsolutePath);Copy-Item -LiteralPath $repairSources[$name] -Destination $partial }
Assert-True (Test-Path -LiteralPath (Join-Path $s2sRoot 'demo/server.py') -PathType Leaf) 'repair restores incomplete source component'
Assert-Equal 'GGUF' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($modelPath),0,4)) 'repair restores corrupt model'
Assert-Equal 'speech-to-speech-bundle,qwen35-test' (($repairResult.repaired -join ',')) 'repair reports restored artifacts'

Complete-TestRun
