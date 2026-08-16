. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Layout.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\Provision.psm1" -Force

function New-TestZip {
    param([string]$Path, [hashtable]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $archive.CreateEntry($name)
                $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
                try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-Artifact {
    param([string]$Id, [string]$Kind, [string]$Path, [string[]]$RequiredFiles = @())
    $value = [ordered]@{
        id = $Id
        install_kind = $Kind
        version = '0.1.0'
        filename = [IO.Path]::GetFileName($Path)
        urls = @("https://fixture.invalid/$([IO.Path]::GetFileName($Path))")
        bytes = [int64](Get-Item -LiteralPath $Path).Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($RequiredFiles.Count -gt 0) { $value.required_files = @($RequiredFiles) }
    return [pscustomobject]$value
}

$zh = -join @([char]0x90e8,[char]0x7f72)
$base = Join-Path $env:TEMP ("Live Avatar $zh " + [guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $base 'Program Root'
$dataRoot = Join-Path $base 'User Data'
$downloads = Join-Path $base 'Downloads'
$sources = Join-Path $base 'Sources'
New-Item -ItemType Directory -Path $downloads,$sources -Force | Out-Null
$layout = New-LiveAvatarLayout -InstallRoot $installRoot -DataRoot $dataRoot -Version '0.1.0'

$s2sZip = Join-Path $sources 's2s.zip'
New-TestZip $s2sZip @{'demo/server.py'='app = object()';'demo/ui/avatar-api.js'='export const ok = true;'}
$s2sComponent = New-Artifact 'speech-to-speech-bundle' 'source_bundle' $s2sZip @('demo/server.py','demo/ui/avatar-api.js')
Copy-Item -LiteralPath $s2sZip -Destination (Join-Path $downloads $s2sComponent.filename)
$installedS2s = Install-LiveAvatarComponent -Component $s2sComponent -Layout $layout -DownloadRoot $downloads
Assert-Equal (Join-Path $layout.version_root 'speech-to-speech') $installedS2s 'source bundle target'
Assert-True (Test-Path -LiteralPath (Join-Path $installedS2s 'demo/server.py') -PathType Leaf) 'source bundle required file staged'
Remove-Item -LiteralPath (Join-Path $installedS2s 'demo/server.py') -Force
$repairedS2s = Install-LiveAvatarComponent -Component $s2sComponent -Layout $layout -DownloadRoot $downloads -Repair
Assert-True (Test-Path -LiteralPath (Join-Path $repairedS2s 'demo/server.py') -PathType Leaf) 'repair replaces an incomplete source bundle'
Assert-Equal 1 @(Get-ChildItem -LiteralPath $layout.version_root -Directory | Where-Object Name -like 'speech-to-speech.bad-*').Count 'repair retains the incomplete source as quarantine'

$badZip = Join-Path $sources 'bad.zip'
New-TestZip $badZip @{'../escape.txt'='unsafe'}
$badComponent = New-Artifact 'speech-to-speech-bundle' 'source_bundle' $badZip @('demo/server.py')
Copy-Item -LiteralPath $badZip -Destination (Join-Path $downloads $badComponent.filename)
Assert-Throws {
    Install-LiveAvatarComponent -Component $badComponent -Layout $layout -DownloadRoot $downloads
} 'archive traversal is rejected'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.version_root 'escape.txt'))) 'archive traversal writes nothing'

$modelFile = Join-Path $sources 'tiny.gguf'
[IO.File]::WriteAllBytes($modelFile, [Text.Encoding]::ASCII.GetBytes('GGUFfixture'))
$modelArtifact = New-Artifact 'qwen-test' 'gguf' $modelFile
Copy-Item -LiteralPath $modelFile -Destination (Join-Path $downloads $modelArtifact.filename)
$installedModel = Install-LiveAvatarComponent -Component $modelArtifact -Layout $layout -DownloadRoot $downloads
Assert-Equal (Join-Path $layout.models_root 'tiny.gguf') $installedModel 'model target'
Assert-Equal 'GGUF' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($installedModel),0,4)) 'model header verified'

$liveTalkingRoot = Join-Path $layout.version_root 'LiveTalking'
New-Item -ItemType Directory -Path $liveTalkingRoot -Force | Out-Null
$pythonPath = Join-Path $layout.python_root 'python.exe'
[IO.File]::WriteAllBytes($pythonPath, [byte[]](77,90))
$wheelZip = Join-Path $sources 'wheelhouse.zip'
New-TestZip $wheelZip @{'fixture-1.0-py3-none-any.whl'='wheel'}
$wheelComponent = New-Artifact 'python-wheelhouse' 'wheelhouse' $wheelZip
Copy-Item -LiteralPath $wheelZip -Destination (Join-Path $downloads $wheelComponent.filename)
$externalWheel = Join-Path $sources 'torch-2.11.0+cu128-cp311-cp311-win_amd64.whl'
[IO.File]::WriteAllText($externalWheel, 'external-wheel', (New-Object Text.UTF8Encoding($false)))
$externalComponent = New-Artifact 'torch-cu128-wheel' 'python_wheel' $externalWheel
Copy-Item -LiteralPath $externalWheel -Destination (Join-Path $downloads $externalComponent.filename)
$wheelLock = Join-Path $sources 'wheel-lock.json'
$archivedWheelBytes = [Text.Encoding]::UTF8.GetBytes('wheel')
$archivedWheelSha = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($archivedWheelBytes)).Replace('-','').ToLowerInvariant()
$lockValue = [ordered]@{
    schema_version=1
    groups=[ordered]@{s2s=@();livetalking=@()}
    wheels=@(
        [ordered]@{filename='fixture-1.0-py3-none-any.whl';bytes=$archivedWheelBytes.Length;sha256=$archivedWheelSha},
        [ordered]@{filename=$externalComponent.filename;bytes=$externalComponent.bytes;sha256=$externalComponent.sha256}
    )
}
[IO.File]::WriteAllText($wheelLock, ($lockValue | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
$processCalls = New-Object Collections.Generic.List[string]
$observedWheelFiles = New-Object Collections.Generic.List[string]
$fakeProcess = {
    param($file,$arguments)
    $processCalls.Add("$file $($arguments -join ' ')")
    if ($arguments.Count -ge 3 -and $arguments[0] -eq '-m' -and $arguments[1] -eq 'venv') {
        $fakeVenvPython = Join-Path ([string]$arguments[2]) 'Scripts/python.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fakeVenvPython) -Force | Out-Null
        [IO.File]::WriteAllBytes($fakeVenvPython, [byte[]](77,90))
    }
    $findLinksIndex = [Array]::IndexOf([object[]]$arguments, '--find-links')
    if ($findLinksIndex -ge 0 -and $findLinksIndex + 1 -lt $arguments.Count) {
        foreach ($wheelFile in @(Get-ChildItem -LiteralPath ([string]$arguments[$findLinksIndex + 1]) -Filter '*.whl' -File)) {
            if (-not $observedWheelFiles.Contains($wheelFile.Name)) { $observedWheelFiles.Add($wheelFile.Name) }
        }
    }
    return 0
}
$wheelMarker = Install-LiveAvatarComponent -Component $wheelComponent -Layout $layout -DownloadRoot $downloads `
    -WheelLockPath $wheelLock -ProcessAction $fakeProcess
Assert-True (Test-Path -LiteralPath $wheelMarker -PathType Leaf) 'wheelhouse writes installation marker'
Assert-True (($processCalls -join "`n") -match '--no-index --find-links') 'wheelhouse installs without package indexes'
Assert-True ($observedWheelFiles.Contains($externalComponent.filename)) 'external PyTorch wheel is merged into the verified local wheel directory'
Assert-True (($processCalls -join "`n") -match '--no-build-isolation --no-deps -e') 'speech pipeline is installed editable from the bundled source'
Assert-Equal 2 @(Get-ChildItem -Path $layout.version_root -Filter python.exe -Recurse | Where-Object FullName -match '\\.venv\\').Count 'wheelhouse creates two isolated environments'

$productionOrder = Get-LiveAvatarInstallOrder @(
    [pscustomobject]@{id='wav2lip-model';install_kind='google_drive'},
    [pscustomobject]@{id='python-wheelhouse';install_kind='wheelhouse'},
    [pscustomobject]@{id='torch-cu128-wheel';install_kind='python_wheel'},
    [pscustomobject]@{id='livetalking-bundle';install_kind='source_bundle'},
    [pscustomobject]@{id='llama-cudart';install_kind='zip_overlay'},
    [pscustomobject]@{id='llama-cuda';install_kind='zip'},
    [pscustomobject]@{id='python-3-11-9';install_kind='python_exe'},
    [pscustomobject]@{id='default-avatar';install_kind='google_drive_archive'},
    [pscustomobject]@{id='speech-to-speech-bundle';install_kind='source_bundle'}
)
Assert-Equal 'python-3-11-9,llama-cuda,llama-cudart,speech-to-speech-bundle,livetalking-bundle,wav2lip-model,default-avatar,torch-cu128-wheel,python-wheelhouse' `
    (($productionOrder | ForEach-Object id) -join ',') 'components are staged in dependency order'

$hardware = [pscustomobject]@{gpu_name='Fixture RTX';vram_mib=16384;compute_capability='8.6'}
$selection = [pscustomobject]@{
    model = [pscustomobject]@{
        id='qwen-test';filename='tiny.gguf';url='https://fixture.invalid/tiny.gguf'
        bytes=$modelArtifact.bytes;sha256=$modelArtifact.sha256;ctx_size=8192;gpu_layers=999
        hybrid_gpu_layers=20;reasoning='off';jinja=$true
    }
    mode='full_gpu';gpu_layers=999;reason='fixture selection';warning=''
}
$ports = [pscustomobject]@{llm=8080;livetalking=8010;s2s=8765;demo=7860}
$sourceMap = @{'s2s.zip'=$s2sZip;'tiny.gguf'=$modelFile}
$downloadAction = {
    param($url,$partial)
    $name = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
    Copy-Item -LiteralPath $sourceMap[$name] -Destination $partial
}

$result = Invoke-LiveAvatarProvisioning -Layout $layout -Hardware $hardware -ModelSelection $selection `
    -Components @($s2sComponent) -Ports $ports -DownloadAction $downloadAction -SmokeTestAction { $true }
$expectedStates = 'detect,choose-model,confirm-space,download,verify,stage,configure,smoke-test,activate-version'
Assert-Equal $expectedStates ($result.states -join ',') 'provisioning state order'
Assert-Equal '0.1.0' (Get-LiveAvatarCurrentVersion -InstallRoot $installRoot).version 'successful provisioning activates version'
Assert-True (Test-Path -LiteralPath (Join-Path $layout.cache_root 'downloads/s2s.zip')) 'verified download remains cached'

$failedLayout = New-LiveAvatarLayout -InstallRoot $installRoot -DataRoot $dataRoot -Version '0.2.0'
Assert-Throws {
    Invoke-LiveAvatarProvisioning -Layout $failedLayout -Hardware $hardware -ModelSelection $selection `
        -Components @($s2sComponent) -Ports $ports -DownloadAction $downloadAction `
        -ComponentAction { param($component,$activeLayout,$downloadRoot) throw 'fixture stage failure' } `
        -SmokeTestAction { $true }
} 'stage failure aborts provisioning'
Assert-Equal '0.1.0' (Get-LiveAvatarCurrentVersion -InstallRoot $installRoot).version 'stage failure keeps previous current version'
Assert-True (Test-Path -LiteralPath (Join-Path $failedLayout.cache_root 'downloads/s2s.zip')) 'stage failure preserves verified cache'

$plan = Invoke-LiveAvatarProvisioning -Layout $failedLayout -Hardware $hardware -ModelSelection $selection `
    -Components @($s2sComponent) -Ports $ports -PlanOnly
Assert-Equal 2 $plan.downloads.Count 'plan includes component and selected model'
Assert-True ([int64]$plan.required_bytes -ge ([int64]$s2sComponent.bytes + [int64]$selection.model.bytes)) 'plan reports required bytes'
Assert-True (($plan.downloads.url -join ',') -match '^https://') 'plan reports HTTPS URLs'

$lowDiskHardware = [pscustomobject]@{
    gpu_name='Fixture RTX';vram_mib=16384;compute_capability='8.6';install_free_bytes=1;model_free_bytes=1
}
$downloadWasCalled = $false
Assert-Throws {
    Invoke-LiveAvatarProvisioning -Layout $failedLayout -Hardware $lowDiskHardware -ModelSelection $selection `
        -Components @($s2sComponent) -Ports $ports -DownloadAction { $downloadWasCalled = $true } -SmokeTestAction { $true }
} 'insufficient disk is rejected before download'
Assert-True (-not $downloadWasCalled) 'disk rejection performs no download'

Complete-TestRun
