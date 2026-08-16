Set-StrictMode -Version 2.0

function Get-SortedModels {
    param($Catalog)
    if ($null -eq $Catalog -or $null -eq $Catalog.models) { throw 'model catalog is required' }
    $models = @($Catalog.models | Sort-Object {[int64]$_.full_gpu_min_vram_mib}, id)
    if ($models.Count -eq 0) { throw 'model catalog is empty' }
    return $models
}

function New-Selection {
    param($Model, [string]$Mode, [bool]$PreferenceAvailable, [string]$DisabledReason, [string]$Reason, [string]$Warning)
    $layers = switch ($Mode) {
        'full_gpu' { [int]$Model.gpu_layers }
        'hybrid' { [int]$Model.hybrid_gpu_layers }
        default { 0 }
    }
    return [pscustomobject]@{
        model = $Model
        mode = $Mode
        gpu_layers = $layers
        preference_available = $PreferenceAvailable
        disabled_reason = $DisabledReason
        reason = $Reason
        warning = $Warning
    }
}

function Get-LiveAvatarModelChoices {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Profile, [Parameter(Mandatory = $true)]$Catalog)
    $vram = [int64]$Profile.vram_mib
    $models = Get-SortedModels $Catalog
    $lowest = $models[0]
    $choices = foreach ($model in $models) {
        if ($vram -ge [int64]$model.full_gpu_min_vram_mib) {
            [pscustomobject]@{ model=$model; enabled=$true; mode='full_gpu'; reason='Fits with full GPU offload and reserved stack memory.' }
        }
        elseif ($model.id -eq $lowest.id -and $vram -ge [int64]$model.hybrid_min_vram_mib) {
            [pscustomobject]@{ model=$model; enabled=$true; mode='hybrid'; reason='Uses partial GPU offload; the remaining layers run on CPU.' }
        }
        elseif ($model.id -eq $lowest.id) {
            [pscustomobject]@{ model=$model; enabled=$true; mode='cpu'; reason='CPU-only slow mode; NVIDIA acceleration remains available to speech and avatar services.' }
        }
        else {
            [pscustomobject]@{ model=$model; enabled=$false; mode='unsafe'; reason="Requires at least $($model.full_gpu_min_vram_mib) MiB VRAM for this complete stack." }
        }
    }
    return @($choices)
}

function Select-LiveAvatarModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Catalog,
        [ValidateSet('Recommended','Faster','HigherQuality')][string]$Preference = 'Recommended'
    )
    $vram = [int64]$Profile.vram_mib
    $models = Get-SortedModels $Catalog
    $full = @($models | Where-Object { $vram -ge [int64]$_.full_gpu_min_vram_mib })
    if ($full.Count -gt 0) {
        $model = $full[-1]
        $mode = 'full_gpu'
    }
    else {
        $model = $models[0]
        $mode = if ($vram -ge [int64]$model.hybrid_min_vram_mib) { 'hybrid' } else { 'cpu' }
    }

    $available = $true
    $disabled = ''
    if ($Preference -eq 'Faster' -and $mode -eq 'full_gpu' -and $full.Count -gt 1) {
        $model = $full[$full.Count - 2]
    }
    elseif ($Preference -eq 'HigherQuality') {
        $index = [Array]::IndexOf([object[]]$models, $model)
        if ($index -ge 0 -and $index + 1 -lt $models.Count) {
            $next = $models[$index + 1]
            if ($vram -ge [int64]$next.full_gpu_min_vram_mib) {
                $model = $next
                $mode = 'full_gpu'
            }
            else {
                $available = $false
                $disabled = "Higher quality requires at least $($next.full_gpu_min_vram_mib) MiB VRAM."
            }
        }
        else {
            $available = $false
            $disabled = 'The highest quality tier is already selected.'
        }
    }

    $warning = ''
    if ($mode -eq 'hybrid') { $warning = 'Hybrid mode is slower because some LLM layers run on CPU.' }
    if ($mode -eq 'cpu') { $warning = 'CPU slow mode may have long response latency.' }
    $reason = switch ($mode) {
        'full_gpu' { "Selected the highest full-GPU tier that fits $vram MiB while reserving memory for speech and avatar services." }
        'hybrid' { "No full-GPU tier fits $vram MiB; selected the 4B hybrid fallback." }
        default { "VRAM is below the hybrid threshold; selected the 4B CPU slow fallback." }
    }
    return New-Selection $model $mode $available $disabled $reason $warning
}

Export-ModuleMember -Function Select-LiveAvatarModel, Get-LiveAvatarModelChoices
