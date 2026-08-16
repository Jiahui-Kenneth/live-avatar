Set-StrictMode -Version 2.0

function ConvertTo-FirstInteger {
    param([string]$Value, [string]$Context)
    if ($Value -notmatch '(\d+)') { throw "Unable to parse $Context from '$Value'" }
    return [int64]$matches[1]
}

function Invoke-NvidiaQuery {
    param([string]$Path, [string]$Fields)
    $output = @(& $Path "--query-gpu=$Fields" '--format=csv,noheader,nounits' 2>$null)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ output=$output; exit_code=$exitCode }
}

function Test-LiveAvatarPort {
    param([int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(200)) { return $false }
        try { $client.EndConnect($async); return $true } catch { return $false }
    }
    finally { $client.Dispose() }
}

function Get-FreeBytes {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Cannot resolve drive for '$Path'" }
    $drive = New-Object IO.DriveInfo($root)
    return [int64]$drive.AvailableFreeSpace
}

function Get-LiveAvatarHardwareProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NvidiaSmiPath,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][string]$ModelPath
    )
    if (-not (Test-Path -LiteralPath $NvidiaSmiPath -PathType Leaf)) { throw "nvidia-smi not found: $NvidiaSmiPath" }

    $query = Invoke-NvidiaQuery $NvidiaSmiPath 'name,memory.total,driver_version,compute_cap'
    $hasCapability = $query.exit_code -eq 0
    if (-not $hasCapability) {
        $query = Invoke-NvidiaQuery $NvidiaSmiPath 'name,memory.total,driver_version'
        if ($query.exit_code -ne 0) { throw 'Unable to query NVIDIA GPU. Install or update the NVIDIA driver.' }
    }
    $rows = @($query.output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($rows.Count -eq 0) { throw 'No NVIDIA GPU was detected.' }
    if ($rows.Count -ne 1) { throw "Multiple NVIDIA GPUs are not supported by installer v0.1.0 (detected $($rows.Count))." }
    $parts = @([string]$rows[0] -split ',' | ForEach-Object { $_.Trim() })
    $minimum = if ($hasCapability) { 4 } else { 3 }
    if ($parts.Count -lt $minimum) { throw "Unexpected nvidia-smi output: $($rows[0])" }

    $ramMiB = 0
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ramMiB = [int64][Math]::Floor([double]$computer.TotalPhysicalMemory / 1MB)
    }
    catch { $ramMiB = 0 }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'X64' } else { 'X86' }
    try { $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch {}
    $ports = foreach ($port in @(8080,8010,8765,7860)) {
        [pscustomobject]@{ port=$port; occupied=(Test-LiveAvatarPort $port) }
    }

    return [pscustomobject]@{
        windows_version = [Environment]::OSVersion.Version.ToString()
        os_arch = $arch
        gpu_name = $parts[0]
        vram_mib = [int](ConvertTo-FirstInteger $parts[1] 'VRAM')
        driver_version = $parts[2]
        compute_capability = if ($hasCapability) { $parts[3] } else { $null }
        ram_mib = $ramMiB
        install_free_bytes = Get-FreeBytes $InstallPath
        model_free_bytes = Get-FreeBytes $ModelPath
        occupied_service_ports = @($ports)
    }
}

Export-ModuleMember -Function Get-LiveAvatarHardwareProfile
