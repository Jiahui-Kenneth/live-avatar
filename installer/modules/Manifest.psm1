Set-StrictMode -Version 2.0

function Assert-ObjectProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $names = @($Object.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($names -notcontains $name) { throw "$Context is missing required property '$name'" }
    }
    foreach ($name in $names) {
        if ($Allowed -notcontains $name) { throw "$Context contains unknown property '$name'" }
    }
}

function Assert-HttpsUrl {
    param([string]$Value, [string]$Context)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw "$Context must be an absolute HTTPS URL"
    }
}

function Assert-PositiveInteger {
    param($Value, [string]$Context)
    try { $number = [int64]$Value } catch { throw "$Context must be an integer" }
    if ($number -le 0) { throw "$Context must be positive" }
}

function Test-LiveAvatarModelCatalog {
    param($Data)
    Assert-ObjectProperties $Data @('schema_version','catalog_version','models') @('schema_version','catalog_version','models') 'model catalog'
    if ([int]$Data.schema_version -ne 1) { throw 'unsupported model manifest schema_version' }
    $seen = @{}
    $required = @('id','display_name','repository','revision','filename','url','bytes','sha256','full_gpu_min_vram_mib','recommended_vram_mib','hybrid_min_vram_mib','ctx_size','gpu_layers','hybrid_gpu_layers','reasoning','jinja')
    foreach ($model in @($Data.models)) {
        Assert-ObjectProperties $model $required $required "model '$($model.id)'"
        if ([string]$model.id -notmatch '^[a-z0-9][a-z0-9-]{2,63}$') { throw "invalid model id '$($model.id)'" }
        if ($seen.ContainsKey([string]$model.id)) { throw "duplicate model id '$($model.id)'" }
        $seen[[string]$model.id] = $true
        if ([string]$model.revision -notmatch '^[0-9a-f]{40}$') { throw "invalid revision for '$($model.id)'" }
        if ([string]$model.sha256 -notmatch '^[0-9a-f]{64}$') { throw "invalid sha256 for '$($model.id)'" }
        if ([string]$model.filename -notmatch '(?i)\.gguf$') { throw "invalid GGUF filename for '$($model.id)'" }
        Assert-HttpsUrl ([string]$model.url) "model '$($model.id)' URL"
        foreach ($field in @('bytes','full_gpu_min_vram_mib','recommended_vram_mib','hybrid_min_vram_mib','ctx_size')) {
            Assert-PositiveInteger $model.$field "model '$($model.id)' $field"
        }
        if ([int64]$model.hybrid_min_vram_mib -gt [int64]$model.full_gpu_min_vram_mib -or
            [int64]$model.full_gpu_min_vram_mib -gt [int64]$model.recommended_vram_mib) {
            throw "model '$($model.id)' VRAM thresholds are not ascending"
        }
        if ([int]$model.gpu_layers -lt 0 -or [int]$model.hybrid_gpu_layers -lt 0) { throw "model '$($model.id)' GPU layers must be nonnegative" }
        if ([string]$model.reasoning -ne 'off') { throw "model '$($model.id)' must disable reasoning" }
        if ($model.jinja -isnot [bool]) { throw "model '$($model.id)' jinja must be boolean" }
    }
    if ($seen.Count -eq 0) { throw 'model catalog must not be empty' }
}

function Test-LiveAvatarComponentCatalog {
    param($Data)
    Assert-ObjectProperties $Data @('schema_version','catalog_version','components') @('schema_version','catalog_version','components') 'component catalog'
    if ([int]$Data.schema_version -ne 1) { throw 'unsupported component manifest schema_version' }
    $seen = @{}
    $base = @('id','install_kind','version')
    $artifact = @('id','install_kind','version','filename','urls','bytes','sha256','required_files','file_id')
    $git = @('id','install_kind','version','url','revision')
    $package = @('id','install_kind','version','package','index_url')
    foreach ($component in @($Data.components)) {
        $id = [string]$component.id
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{2,63}$') { throw "invalid component id '$id'" }
        if ($seen.ContainsKey($id)) { throw "duplicate component id '$id'" }
        $seen[$id] = $true
        $kind = [string]$component.install_kind
        switch ($kind) {
            'git_source' {
                Assert-ObjectProperties $component ($base + @('url','revision')) $git "component '$id'"
                Assert-HttpsUrl ([string]$component.url) "component '$id' URL"
                if ([string]$component.revision -notmatch '^[0-9a-f]{40}$') { throw "invalid revision for '$id'" }
            }
            'python_package' {
                Assert-ObjectProperties $component ($base + @('package','index_url')) $package "component '$id'"
                Assert-HttpsUrl ([string]$component.index_url) "component '$id' index URL"
            }
            { $_ -in @('python_exe','zip','zip_overlay','google_drive','google_drive_archive','source_bundle','wheelhouse') } {
                Assert-ObjectProperties $component ($base + @('filename','urls','bytes','sha256')) $artifact "component '$id'"
                if ([string]$component.sha256 -notmatch '^[0-9a-f]{64}$') { throw "invalid sha256 for '$id'" }
                Assert-PositiveInteger $component.bytes "component '$id' bytes"
                $urls = @($component.urls)
                if ($urls.Count -eq 0) { throw "component '$id' requires a URL" }
                foreach ($url in $urls) { Assert-HttpsUrl ([string]$url) "component '$id' URL" }
                if ($kind -like 'google_drive*' -and [string]::IsNullOrWhiteSpace([string]$component.file_id)) { throw "component '$id' requires file_id" }
            }
            default { throw "unsupported install_kind '$kind'" }
        }
    }
    if ($seen.Count -eq 0) { throw 'component catalog must not be empty' }
}

function Import-LiveAvatarManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Component','Model')][string]$Kind
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "manifest not found: $Path" }
    try { $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "invalid JSON manifest '$Path': $($_.Exception.Message)" }
    if ($null -eq $data) { throw "manifest is empty: $Path" }
    if ($Kind -eq 'Model') { Test-LiveAvatarModelCatalog $data } else { Test-LiveAvatarComponentCatalog $data }
    return $data
}

Export-ModuleMember -Function Import-LiveAvatarManifest
