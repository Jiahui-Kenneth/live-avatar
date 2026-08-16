. "$PSScriptRoot\TestHarness.ps1"
Import-Module "$PSScriptRoot\..\modules\Manifest.psm1" -Force
Import-Module "$PSScriptRoot\..\modules\ModelSelection.psm1" -Force

$catalog = Import-LiveAvatarManifest -Path "$PSScriptRoot\..\manifests\models.json" -Kind Model
$cases = @(
    @{ vram=32607; expected='qwen35-35b-a3b-q4km'; mode='full_gpu' },
    @{ vram=30000; expected='qwen35-27b-q4km'; mode='full_gpu' },
    @{ vram=24576; expected='qwen35-9b-q4km'; mode='full_gpu' },
    @{ vram=16384; expected='qwen35-9b-q4km'; mode='full_gpu' },
    @{ vram=12288; expected='qwen35-4b-q4km'; mode='full_gpu' },
    @{ vram=8192; expected='qwen35-4b-q4km'; mode='hybrid' },
    @{ vram=6144; expected='qwen35-4b-q4km'; mode='cpu' }
)
foreach ($case in $cases) {
    $profile = [pscustomobject]@{ gpu_name='NVIDIA test GPU'; vram_mib=$case.vram }
    $selection = Select-LiveAvatarModel -Profile $profile -Catalog $catalog -Preference Recommended
    Assert-Equal $case.expected $selection.model.id "recommended model for $($case.vram) MiB"
    Assert-Equal $case.mode $selection.mode "execution mode for $($case.vram) MiB"
}

$profile32 = [pscustomobject]@{ gpu_name='NVIDIA GeForce RTX 5090'; vram_mib=32607 }
$faster = Select-LiveAvatarModel -Profile $profile32 -Catalog $catalog -Preference Faster
Assert-Equal 'qwen35-27b-q4km' $faster.model.id 'faster selects one lower tier'

$profile24 = [pscustomobject]@{ gpu_name='NVIDIA GeForce RTX 4090'; vram_mib=24576 }
$higher = Select-LiveAvatarModel -Profile $profile24 -Catalog $catalog -Preference HigherQuality
Assert-Equal 'qwen35-9b-q4km' $higher.model.id 'unsafe higher-quality choice is not selected'
Assert-True (-not $higher.preference_available) 'unsafe higher-quality choice is disabled'
Assert-True ($higher.disabled_reason -match '28672') 'disabled reason contains required VRAM'

$cpu = Select-LiveAvatarModel -Profile ([pscustomobject]@{gpu_name='NVIDIA test';vram_mib=6144}) -Catalog $catalog
Assert-Equal 0 $cpu.gpu_layers 'CPU mode disables GPU layers'
Assert-True ($cpu.warning -match 'slow') 'CPU mode warns about speed'

Complete-TestRun
