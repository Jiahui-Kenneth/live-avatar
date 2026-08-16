. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Hardware.psm1" -Force

$profile = Get-LiveAvatarHardwareProfile `
    -NvidiaSmiPath "$PSScriptRoot\fixtures\nvidia-smi.cmd" `
    -InstallPath $env:TEMP `
    -ModelPath $env:TEMP

Assert-Equal 'NVIDIA GeForce RTX 5090' $profile.gpu_name 'gpu name'
Assert-Equal 32607 $profile.vram_mib 'reported VRAM'
Assert-Equal '610.62' $profile.driver_version 'driver version'
Assert-Equal '12.0' $profile.compute_capability 'compute capability'
Assert-True ($profile.ram_mib -ge 0) 'RAM probe returns a number'
Assert-True ($profile.install_free_bytes -gt 0) 'install disk free bytes'
Assert-True ($profile.model_free_bytes -gt 0) 'model disk free bytes'
Assert-Equal 4 @($profile.occupied_service_ports).Count 'four service ports are reported'

Complete-TestRun
