. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Layout.psm1" -Force

$fixtureRoot = Join-Path $env:TEMP ("Live Avatar Launcher " + [guid]::NewGuid().ToString('N'))
$launcherRoot = Join-Path $fixtureRoot 'launcher'
$moduleRoot = Join-Path $fixtureRoot 'installer\modules'
New-Item -ItemType Directory -Path $launcherRoot,$moduleRoot -Force | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot\..\..\launcher\LiveAvatar.ps1" -Destination $launcherRoot
Copy-Item -Path "$PSScriptRoot\..\modules\*.psm1" -Destination $moduleRoot

$layout = New-LiveAvatarLayout -InstallRoot $fixtureRoot -DataRoot (Join-Path $fixtureRoot 'data') -Version '0.1.0'
$hardware = [pscustomobject]@{gpu_name='Fixture GPU';vram_mib=8192;compute_capability='8.6'}
$selection = [pscustomobject]@{
    model=[pscustomobject]@{id='fixture-model';filename='fixture.gguf';ctx_size=8192;reasoning='off';jinja=$true}
    mode='hybrid';gpu_layers=20
}
$ports = [pscustomobject]@{llm=18080;livetalking=18010;s2s=18765;demo=17860}
Write-LiveAvatarConfig -Layout $layout -Hardware $hardware -ModelSelection $selection -Ports $ports | Out-Null
Set-LiveAvatarCurrentVersion -InstallRoot $fixtureRoot -Version '0.1.0' | Out-Null

$output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $launcherRoot 'LiveAvatar.ps1') -Command status -NoBrowser 2>&1)
Assert-Equal 0 $LASTEXITCODE 'launcher derives its install root when invoked with -File and no InstallRoot argument'
$json = $null
try { $json = ($output -join "`n") | ConvertFrom-Json } catch {}
Assert-Equal 'degraded' $json.status 'derived install root resolves the fixture active version'
Assert-Equal '0.1.0' $json.version 'launcher reports the active fixture version'

Complete-TestRun
