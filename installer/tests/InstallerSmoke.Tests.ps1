. "$PSScriptRoot\TestHarness.ps1"

$issPath = Join-Path $PSScriptRoot '..\LiveAvatar.iss'
$setupPath = Join-Path $PSScriptRoot '..\dist\LiveAvatar-Setup-0.1.0.exe'
Assert-True (Test-Path -LiteralPath $issPath -PathType Leaf) 'Inno Setup source exists'
Assert-True (Test-Path -LiteralPath $setupPath -PathType Leaf) 'compiled setup exists'
if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
    $setup = Get-Item -LiteralPath $setupPath
    Assert-True ($setup.Length -lt 50MB) 'setup stays below 50 MiB'
    Assert-True ([string]$setup.VersionInfo.ProductVersion -match '^0\.1\.0') 'setup embeds version 0.1.0'
}

if (Test-Path -LiteralPath $issPath -PathType Leaf) {
    $iss = Get-Content -LiteralPath $issPath -Raw -Encoding UTF8
    Assert-True ($iss -match '(?im)^PrivilegesRequired=lowest$') 'setup is per-user without elevation'
    Assert-True ($iss -match '(?im)^ArchitecturesAllowed=x64compatible$') 'setup is restricted to x64-compatible Windows'
    Assert-True ($iss -match 'https://github\.com/Jiahui-Kenneth/live-avatar') 'setup metadata points to the publishing fork'
    Assert-Equal 3 @([regex]::Matches($iss,'(?im)^Name: "\{userprograms\}\\Live Avatar\\')).Count 'setup creates three user shortcuts'
    Assert-True ($iss -match '-InstallRoot.+-DataRoot') 'setup passes selected program and data roots to bootstrap'
    Assert-True ($iss -match 'DeleteModels\.Checked := False') 'model deletion is opt-in'
    Assert-True ($iss -match 'DeleteAvatars\.Checked := False') 'avatar deletion is opt-in'
    Assert-True ($iss -match 'DeleteSettings\.Checked := False') 'settings deletion is opt-in'
    Assert-True ($iss -match 'function InitializeUninstall\(\): Boolean') 'uninstall choices are shown before removal starts'
    Assert-True ($iss -match 'skipifsilent') 'silent fixture install skips online bootstrap'
}

if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
    $fixtureRoot = Join-Path $env:TEMP ("Live Avatar Setup Smoke " + [guid]::NewGuid().ToString('N'))
    $installRoot = Join-Path $fixtureRoot 'Program Files'
    $dataRoot = Join-Path $fixtureRoot 'User Data'
    $shortcutRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Live Avatar'
    $shortcutBackup = Join-Path $fixtureRoot 'shortcut-backup'
    $hadShortcutRoot = Test-Path -LiteralPath $shortcutRoot -PathType Container
    if ($hadShortcutRoot) {
        New-Item -ItemType Directory -Path $shortcutBackup -Force | Out-Null
        Copy-Item -Path (Join-Path $shortcutRoot '*') -Destination $shortcutBackup -Recurse -Force
    }
    try {
        $setupArguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$installRoot`" /DataRoot=`"$dataRoot`""
        $setupProcess = Start-Process -FilePath $setupPath -ArgumentList $setupArguments -WindowStyle Hidden -Wait -PassThru
        Assert-Equal 0 $setupProcess.ExitCode 'silent per-user fixture install succeeds'
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'installer/bootstrap.ps1') -PathType Leaf) 'fixture install contains bootstrap'
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'launcher/LiveAvatar.ps1') -PathType Leaf) 'fixture install contains launcher'
        $shortcuts = @(Get-ChildItem -LiteralPath $shortcutRoot -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
        Assert-Equal 3 $shortcuts.Count 'fixture install creates three shortcuts'
        $shell = New-Object -ComObject WScript.Shell
        $shortcutTargets = @($shortcuts | ForEach-Object { $shell.CreateShortcut($_.FullName).TargetPath })
        Assert-Equal 3 @($shortcutTargets | Where-Object { $_.StartsWith((Join-Path $installRoot 'launcher'), [StringComparison]::OrdinalIgnoreCase) }).Count 'fixture shortcuts target the selected install root'

        foreach ($relative in @('models/model.gguf','avatars/custom/metadata.json','config/settings.json')) {
            $path = Join-Path $dataRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path,'preserve')
        }
        $uninstaller = Join-Path $installRoot 'unins000.exe'
        $uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -Wait -PassThru
        Assert-Equal 0 $uninstallProcess.ExitCode 'silent fixture uninstall succeeds'
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'models/model.gguf') -PathType Leaf) 'default uninstall preserves models'
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'avatars/custom/metadata.json') -PathType Leaf) 'default uninstall preserves avatars'
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'config/settings.json') -PathType Leaf) 'default uninstall preserves settings'
    }
    finally {
        if (Test-Path -LiteralPath $shortcutRoot -PathType Container) { Remove-Item -LiteralPath $shortcutRoot -Recurse -Force }
        if ($hadShortcutRoot) {
            New-Item -ItemType Directory -Path $shortcutRoot -Force | Out-Null
            Copy-Item -Path (Join-Path $shortcutBackup '*') -Destination $shortcutRoot -Recurse -Force
        }
    }
    Assert-Equal $hadShortcutRoot (Test-Path -LiteralPath $shortcutRoot -PathType Container) 'fixture restores the pre-existing shortcut group state'
}

Complete-TestRun
