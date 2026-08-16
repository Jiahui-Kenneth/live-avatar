. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Migration.psm1" -Force

function Write-Json {
    param([string]$Path, $Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

$root = Join-Path $env:TEMP ('Live Avatar Migration ' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$destination = Join-Path $root 'destination'
$avatar = Join-Path $source 'avatars/custom_one'
New-Item -ItemType Directory -Path (Join-Path $avatar 'full_imgs') -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $avatar 'full_imgs/00000000.png'), [byte[]](1,2,3))
Write-Json (Join-Path $avatar 'metadata.json') ([ordered]@{id='custom_one';name='Custom One'})
$legacyAvatar = Join-Path $source 'avatars/legacy_avatar'
New-Item -ItemType Directory -Path (Join-Path $legacyAvatar 'full_imgs') -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $legacyAvatar 'full_imgs/00000000.png'), [byte[]](4,5,6))
Write-Json (Join-Path $legacyAvatar 'metadata.json') ([ordered]@{name='Legacy Avatar'})
Write-Json (Join-Path $source 'config/settings.json') ([ordered]@{active_avatar='custom_one';language='zh'})
Write-Json (Join-Path $source 'config/security/avatar-admin-token.json') ([ordered]@{token='secret'})
Write-Json (Join-Path $source 'hardware/profile.json') ([ordered]@{gpu='machine'})
New-Item -ItemType Directory -Path (Join-Path $source 'logs') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $source 'logs/runtime.log'),'secret log')

$archive = Join-Path $root 'migration.zip'
Export-LiveAvatarData -DataRoot $source -Destination $archive | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try { $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\','/') }) } finally { $zip.Dispose() }
Assert-True (($entries -join ',') -match 'avatars/custom_one/metadata.json') 'custom avatar metadata is exported'
Assert-True (($entries -join ',') -match 'config/settings.json') 'nonsecret settings are exported'
Assert-True (-not (($entries -join ',') -match 'avatar-admin-token|hardware/|logs/|cache/|temp/')) 'secrets and machine state are excluded'

New-Item -ItemType Directory -Path (Join-Path $destination 'avatars/custom_one/full_imgs') -Force | Out-Null
Write-Json (Join-Path $destination 'avatars/custom_one/metadata.json') ([ordered]@{id='custom_one';name='Existing'})
$import = Import-LiveAvatarData -DataRoot $destination -ArchivePath $archive
Assert-Equal 2 $import.imported_avatars.Count 'both current and legacy avatars are imported'
$renamedId = @($import.imported_avatars | Where-Object { $_ -like 'custom_one_import_*' })[0]
Assert-True ($renamedId -ne 'custom_one') 'avatar conflict receives a new ID'
$importedMetadata = Get-Content -LiteralPath (Join-Path $destination "avatars/$renamedId/metadata.json") -Raw | ConvertFrom-Json
Assert-Equal $renamedId $importedMetadata.id 'renamed avatar metadata ID is updated'
$legacyMetadata = Get-Content -LiteralPath (Join-Path $destination 'avatars/legacy_avatar/metadata.json') -Raw | ConvertFrom-Json
Assert-Equal 'legacy_avatar' $legacyMetadata.id 'legacy metadata receives a missing ID'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $destination 'config/security/avatar-admin-token.json'))) 'import never creates management token'

Complete-TestRun
