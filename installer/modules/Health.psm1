Set-StrictMode -Version 2.0

function Invoke-HealthHttp {
    param([string]$Url, [scriptblock]$HttpAction)
    if ($null -ne $HttpAction) { return & $HttpAction $Url }
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
    return [pscustomobject]@{status_code=[int]$response.StatusCode;body=[string]$response.Content}
}

function Test-HealthTcp {
    param([string]$HostName, [int]$Port, [scriptblock]$TcpAction)
    if ($null -ne $TcpAction) { return [bool](& $TcpAction $HostName $Port) }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($HostName,$Port,$null,$null)
        if (-not $connect.AsyncWaitHandle.WaitOne(1500)) { return $false }
        try { $client.EndConnect($connect); return $true } catch { return $false }
    }
    finally { $client.Dispose() }
}

function New-HealthResult {
    param([string]$Id, [bool]$Healthy, [string]$Detail)
    return [pscustomobject]@{id=$Id;healthy=$Healthy;detail=$Detail}
}

function Test-LiveAvatarHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [scriptblock]$HttpAction,
        [scriptblock]$TcpAction
    )
    $ports = $Layout.config.ports
    $results = New-Object Collections.Generic.List[object]
    try {
        $response = Invoke-HealthHttp "http://127.0.0.1:$($ports.llm)/health" $HttpAction
        $body = $response.body | ConvertFrom-Json
        $ok = [int]$response.status_code -eq 200 -and [string]$body.status -eq 'ok'
        $results.Add((New-HealthResult 'llama' $ok $(if ($ok) {'ok'} else {'unexpected health response'})))
    }
    catch { $results.Add((New-HealthResult 'llama' $false $_.Exception.Message)) }
    try {
        $response = Invoke-HealthHttp "http://127.0.0.1:$($ports.livetalking)/api/admin/config" $HttpAction
        $body = $response.body | ConvertFrom-Json
        $ok = [int]$response.status_code -eq 200 -and [int]$body.code -eq 0
        $results.Add((New-HealthResult 'livetalking' $ok $(if ($ok) {'ok'} else {'unexpected config response'})))
    }
    catch { $results.Add((New-HealthResult 'livetalking' $false $_.Exception.Message)) }
    $s2sOk = Test-HealthTcp '127.0.0.1' ([int]$ports.s2s) $TcpAction
    $results.Add((New-HealthResult 's2s' $s2sOk $(if ($s2sOk) {'tcp ready'} else {'tcp unavailable'})))
    try {
        $response = Invoke-HealthHttp "http://127.0.0.1:$($ports.demo)/api/config" $HttpAction
        $body = $response.body | ConvertFrom-Json
        $expectedS2s = "ws://localhost:$($ports.s2s)/v1/realtime"
        $avatarOrigin = if ($body.PSObject.Properties.Name -contains 'avatarOrigin') { [string]$body.avatarOrigin } else { [string]$body.avatarUrl }
        $ok = [int]$response.status_code -eq 200 -and [string]$body.s2sUrl -eq $expectedS2s -and $avatarOrigin -eq "http://127.0.0.1:$($ports.livetalking)"
        $results.Add((New-HealthResult 'demo' $ok $(if ($ok) {'ok'} else {'runtime URLs do not match configuration'})))
    }
    catch { $results.Add((New-HealthResult 'demo' $false $_.Exception.Message)) }
    $services = $results.ToArray()
    return [pscustomobject]@{healthy=@($services | Where-Object { -not $_.healthy }).Count -eq 0;services=$services;checked_at=(Get-Date).ToUniversalTime().ToString('o')}
}

Export-ModuleMember -Function Test-LiveAvatarHealth
