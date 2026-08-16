. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Health.psm1" -Force

$layout = [pscustomobject]@{
    config = [pscustomobject]@{
        ports = [pscustomobject]@{llm=8080;livetalking=8010;s2s=8765;demo=7860}
    }
}
$httpAction = {
    param($url)
    if ($url -match ':8080/health$') { return [pscustomobject]@{status_code=200;body='{"status":"ok"}'} }
    if ($url -match ':8010/api/admin/config$') { return [pscustomobject]@{status_code=200;body='{"code":0,"msg":"ok"}'} }
    if ($url -match ':7860/api/config$') {
        return [pscustomobject]@{status_code=200;body='{"s2sUrl":"ws://localhost:8765/v1/realtime","avatarUrl":"http://127.0.0.1:8010"}'}
    }
    throw "unexpected URL $url"
}
$healthy = Test-LiveAvatarHealth -Layout $layout -HttpAction $httpAction -TcpAction { param($hostName,$port) $port -eq 8765 }
Assert-True $healthy.healthy 'all four services are healthy'
Assert-Equal 'llama,livetalking,s2s,demo' (($healthy.services | ForEach-Object id) -join ',') 'health report order'

$unhealthy = Test-LiveAvatarHealth -Layout $layout -HttpAction $httpAction -TcpAction { $false }
Assert-True (-not $unhealthy.healthy) 'failed websocket port makes stack unhealthy'
Assert-True (-not ($unhealthy.services | Where-Object id -eq 's2s').healthy) 's2s failure is identified'

Complete-TestRun
