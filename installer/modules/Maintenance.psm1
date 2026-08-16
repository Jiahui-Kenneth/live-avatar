Set-StrictMode -Version 2.0

Import-Module "$PSScriptRoot\Download.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot\Provision.psm1" -ErrorAction Stop

function Get-StringHash {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-ServiceSpec {
    param([string]$Id,[string]$Executable,[string]$WorkingDirectory,[object[]]$Arguments,[hashtable]$Environment)
    return [pscustomobject]@{id=$Id;executable=$Executable;working_directory=$WorkingDirectory;arguments=$Arguments;environment=$Environment}
}

function Get-LiveAvatarServiceSpecs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Layout,[Parameter(Mandatory = $true)][string]$AdminToken)
    $ports = $Layout.config.ports
    $model = $Layout.config.model
    $avatarId = 'myavatar'
    $settingsPath = Join-Path $Layout.data_root 'config\settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.PSObject.Properties.Name -contains 'active_avatar' -and [string]$settings.active_avatar -match '^[A-Za-z0-9_-]+$') { $avatarId = [string]$settings.active_avatar }
        }
        catch {}
    }
    $llamaArguments = @('-m',$Layout.model_path,'--host','127.0.0.1','--port',[string]$ports.llm,'--n-gpu-layers',[string]$model.gpu_layers,'--ctx-size',[string]$model.ctx_size,'--parallel','1','--reasoning','off','--alias',[string]$model.id)
    if ([bool]$model.jinja) { $llamaArguments += '--jinja' }
    $commonAvatar = @{
        LIVE_AVATAR_DATA_DIR=[string]$Layout.data_root
        LIVE_AVATAR_ADMIN_TOKEN=$AdminToken
        LIVE_AVATAR_ALLOWED_ORIGINS="http://127.0.0.1:$($ports.demo),http://localhost:$($ports.demo)"
    }
    $ltPython = Join-Path $Layout.livetalking_root '.venv\Scripts\python.exe'
    $s2sPython = Join-Path $Layout.s2s_root '.venv\Scripts\python.exe'
    return @(
        (New-ServiceSpec 'llama' (Join-Path $Layout.llama_root 'llama-server.exe') $Layout.llama_root $llamaArguments @{}),
        (New-ServiceSpec 'livetalking' $ltPython $Layout.livetalking_root @('app.py','--transport','webrtc','--model','wav2lip','--avatar_id',$avatarId,'--listenport',[string]$ports.livetalking,'--listenhost','127.0.0.1') $commonAvatar),
        (New-ServiceSpec 's2s' $s2sPython $Layout.s2s_root @('-u','-m','speech_to_speech.s2s_pipeline','--mode','realtime','--stt','faster-whisper','--llm_backend','chat-completions','--tts','qwen3','--model_name',[string]$model.id,'--responses_api_base_url',"http://127.0.0.1:$($ports.llm)/v1",'--responses_api_api_key','dummy','--language','zh','--faster_whisper_stt_model_name','base','--faster_whisper_stt_device','cuda','--faster_whisper_stt_compute_type','float16','--faster_whisper_stt_gen_language','zh','--qwen3_tts_backend','torch','--qwen3_tts_device','cuda','--thresh','0.8','--min_silence_ms','600','--min_speech_ms','500','--log_level','INFO') @{HF_ENDPOINT='https://huggingface.co';HF_HOME=(Join-Path $Layout.data_root 'cache\huggingface');LIVETALKING_URL="http://127.0.0.1:$($ports.livetalking)"}),
        (New-ServiceSpec 'demo' $s2sPython $Layout.s2s_root @('-m','uvicorn','demo.server:app','--host','127.0.0.1','--port',[string]$ports.demo) ($commonAvatar + @{SPEECH_TO_SPEECH_URL="ws://localhost:$($ports.s2s)/v1/realtime";LIVETALKING_URL="http://127.0.0.1:$($ports.livetalking)"}))
    )
}

function ConvertTo-ProcessArgumentString {
    param([object[]]$Arguments)
    return (@($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -notmatch '[\s"]') { $value; return }
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq '\') { $slashes++; continue }
            if ($character -eq '"') {
                if ($slashes -gt 0) { [void]$builder.Append((('\' * ($slashes * 2)) -join '')) }
                [void]$builder.Append('\"')
                $slashes = 0
                continue
            }
            if ($slashes -gt 0) { [void]$builder.Append((('\' * $slashes) -join '')); $slashes = 0 }
            [void]$builder.Append($character)
        }
        if ($slashes -gt 0) { [void]$builder.Append((('\' * ($slashes * 2)) -join '')) }
        [void]$builder.Append('"')
        $builder.ToString()
    }) -join ' ')
}

function Invoke-WithEnvironment {
    param([hashtable]$Environment,[scriptblock]$Action)
    $saved = @{}
    try {
        foreach ($name in $Environment.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable([string]$name,'Process')
            [Environment]::SetEnvironmentVariable([string]$name,[string]$Environment[$name],'Process')
        }
        return & $Action
    }
    finally {
        foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable([string]$name,$saved[$name],'Process') }
    }
}

function Start-ServiceSpec {
    param($Spec,[string]$LogsRoot)
    if (-not (Test-Path -LiteralPath $Spec.executable -PathType Leaf)) { throw "service executable missing: $($Spec.executable)" }
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $stdout = Join-Path $LogsRoot "$($Spec.id)-$stamp.stdout.log"
    $stderr = Join-Path $LogsRoot "$($Spec.id)-$stamp.stderr.log"
    $arguments = ConvertTo-ProcessArgumentString $Spec.arguments
    $process = Invoke-WithEnvironment $Spec.environment {
        Start-Process -FilePath $Spec.executable -ArgumentList $arguments -WorkingDirectory $Spec.working_directory -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    }
    return [pscustomobject]@{
        pid=[int]$process.Id;executable=[IO.Path]::GetFullPath([string]$Spec.executable)
        arguments_hash=Get-StringHash ($Spec.arguments -join "`0")
        start_time=$process.StartTime.ToUniversalTime().ToString('o');component_id=[string]$Spec.id
        stdout=$stdout;stderr=$stderr
    }
}

function Wait-ServiceReady {
    param([string]$Id,$Layout,[int]$TimeoutSeconds=180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $port = switch ($Id) {'llama' {$Layout.config.ports.llm};'livetalking' {$Layout.config.ports.livetalking};'s2s' {$Layout.config.ports.s2s};default {$Layout.config.ports.demo}}
            $client = New-Object Net.Sockets.TcpClient
            try {
                $async = $client.BeginConnect('127.0.0.1',[int]$port,$null,$null)
                if ($async.AsyncWaitHandle.WaitOne(300)) { $client.EndConnect($async); return $true }
            }
            finally { $client.Dispose() }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "$Id did not become ready within $TimeoutSeconds seconds"
}

function Start-LiveAvatarServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,[Parameter(Mandatory = $true)][string]$AdminToken,
        [scriptblock]$ProcessStarter,[scriptblock]$HealthProbe,[scriptblock]$ProcessStopper
    )
    $started = New-Object Collections.Generic.List[object]
    if ($null -eq $ProcessStarter) { $ProcessStarter = { param($spec) Start-ServiceSpec $spec $Layout.logs_root }.GetNewClosure() }
    if ($null -eq $HealthProbe) { $HealthProbe = { param($id,$activeLayout) Wait-ServiceReady $id $activeLayout }.GetNewClosure() }
    if ($null -eq $ProcessStopper) { $ProcessStopper = { param($record) Stop-Process -Id ([int]$record.pid) -Force -ErrorAction Stop } }
    try {
        foreach ($spec in @(Get-LiveAvatarServiceSpecs $Layout $AdminToken)) {
            $record = & $ProcessStarter $spec
            $started.Add($record)
            & $HealthProbe ([string]$spec.id) $Layout | Out-Null
        }
        return $started.ToArray()
    }
    catch {
        for ($index=$started.Count-1; $index -ge 0; $index--) {
            try { & $ProcessStopper $started[$index] } catch {}
        }
        throw
    }
}

function Stop-LiveAvatarServices {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Layout,[Parameter(Mandatory = $true)][object[]]$ProcessRecords,[scriptblock]$ProcessInspector,[scriptblock]$ProcessStopper)
    if ($null -eq $ProcessInspector) {
        $ProcessInspector = {
            param($pidValue)
            $process = Get-Process -Id ([int]$pidValue) -ErrorAction Stop
            return [pscustomobject]@{pid=$process.Id;executable=$process.Path;start_time=$process.StartTime.ToUniversalTime().ToString('o')}
        }
    }
    if ($null -eq $ProcessStopper) { $ProcessStopper = { param($record) Stop-Process -Id ([int]$record.pid) -Force -ErrorAction Stop } }
    $results = New-Object Collections.Generic.List[object]
    foreach ($record in @($ProcessRecords | Sort-Object { [Array]::IndexOf(@('demo','s2s','livetalking','llama'),[string]$_.component_id) })) {
        try {
            $actual = & $ProcessInspector ([int]$record.pid)
            $samePath = [IO.Path]::GetFullPath([string]$actual.executable).Equals([IO.Path]::GetFullPath([string]$record.executable),[StringComparison]::OrdinalIgnoreCase)
            $sameStart = [datetime]::Parse([string]$actual.start_time).ToUniversalTime() -eq [datetime]::Parse([string]$record.start_time).ToUniversalTime()
            if (-not $samePath -or -not $sameStart) {
                $results.Add([pscustomobject]@{pid=[int]$record.pid;component_id=$record.component_id;status='refused';detail='PID identity mismatch'})
                continue
            }
            & $ProcessStopper $record
            $results.Add([pscustomobject]@{pid=[int]$record.pid;component_id=$record.component_id;status='stopped';detail='ok'})
        }
        catch {
            $results.Add([pscustomobject]@{pid=[int]$record.pid;component_id=$record.component_id;status='absent';detail=$_.Exception.Message})
        }
    }
    return $results.ToArray()
}

function Repair-LiveAvatarInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][object[]]$Components,
        [Parameter(Mandatory = $true)]$Model,
        [ValidateSet('Official','China')][string]$Mirror='Official',
        [string]$WheelLockPath,
        [scriptblock]$DownloadAction
    )
    $downloadRoot = Join-Path $Layout.data_root 'cache\downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $repaired = New-Object Collections.Generic.List[string]
    foreach ($component in @(Get-LiveAvatarInstallOrder $Components)) {
        $destination = Join-Path $downloadRoot ([string]$component.filename)
        Get-VerifiedArtifact -Artifact $component -Destination $destination -Mirror $Mirror -DownloadAction $DownloadAction | Out-Null
        Install-LiveAvatarComponent -Component $component -Layout $Layout -DownloadRoot $downloadRoot -WheelLockPath $WheelLockPath -Repair | Out-Null
        $repaired.Add([string]$component.id)
    }
    $modelArtifact = [pscustomobject]@{
        id=[string]$Model.id;install_kind='gguf';version=[string]$Model.revision;filename=[string]$Model.filename
        urls=@([string]$Model.url);bytes=[int64]$Model.bytes;sha256=[string]$Model.sha256
    }
    Get-VerifiedArtifact -Artifact $modelArtifact -Destination (Join-Path $Layout.data_root "models\$($Model.filename)") -Mirror $Mirror -DownloadAction $DownloadAction | Out-Null
    $repaired.Add([string]$Model.id)
    return [pscustomobject]@{repaired=$repaired.ToArray();completed_at=(Get-Date).ToUniversalTime().ToString('o')}
}

Export-ModuleMember -Function Get-LiveAvatarServiceSpecs, Start-LiveAvatarServices, Stop-LiveAvatarServices, Repair-LiveAvatarInstall
