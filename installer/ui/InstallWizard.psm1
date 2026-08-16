Set-StrictMode -Version 2.0

Import-Module "$PSScriptRoot\..\modules\ModelSelection.psm1" -ErrorAction Stop

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} TiB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GiB' -f ($Bytes / 1GB)) }
    return ('{0:N1} MiB' -f ($Bytes / 1MB))
}

function Show-LiveAvatarInstallWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)]$Hardware,
        [Parameter(Mandatory = $true)]$Catalog,
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Components,
        [ValidateSet('Official','China')][string]$Mirror = 'Official'
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Live Avatar Installer 0.1.0'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object Drawing.Size(820,600)
    $form.MinimumSize = New-Object Drawing.Size(760,540)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Location = New-Object Drawing.Point(16,16)
    $tabs.Size = New-Object Drawing.Size(772,480)
    $tabs.Appearance = 'FlatButtons'
    $tabs.ItemSize = New-Object Drawing.Size(0,1)
    $tabs.SizeMode = 'Fixed'
    $pageNames = @('Welcome','Paths','Hardware','Model Choice','Download Summary','Progress','Verification','Finish')
    foreach ($name in $pageNames) {
        $page = New-Object Windows.Forms.TabPage
        $page.Text = $name
        $page.Name = $name.Replace(' ','')
        $tabs.TabPages.Add($page) | Out-Null
    }
    $form.Controls.Add($tabs)

    $welcome = New-Object Windows.Forms.Label
    $welcome.Text = "Live Avatar installs the local LLM, speech pipeline, and avatar runtime.`r`n`r`nDownloads are resumable and verified with SHA-256. Models and user avatars remain separate from program versions."
    $welcome.AutoSize = $false
    $welcome.Location = New-Object Drawing.Point(28,36)
    $welcome.Size = New-Object Drawing.Size(680,180)
    $welcome.Font = New-Object Drawing.Font('Segoe UI',12)
    $tabs.TabPages[0].Controls.Add($welcome)

    $installLabel = New-Object Windows.Forms.Label
    $installLabel.Text = 'Program location:'
    $installLabel.Location = New-Object Drawing.Point(24,36)
    $installLabel.AutoSize = $true
    $installBox = New-Object Windows.Forms.TextBox
    $installBox.Text = $InstallRoot
    $installBox.Location = New-Object Drawing.Point(24,62)
    $installBox.Size = New-Object Drawing.Size(700,26)
    $dataLabel = New-Object Windows.Forms.Label
    $dataLabel.Text = 'Models and user data location:'
    $dataLabel.Location = New-Object Drawing.Point(24,116)
    $dataLabel.AutoSize = $true
    $dataBox = New-Object Windows.Forms.TextBox
    $dataBox.Text = $DataRoot
    $dataBox.Location = New-Object Drawing.Point(24,142)
    $dataBox.Size = New-Object Drawing.Size(700,26)
    $tabs.TabPages[1].Controls.AddRange(@($installLabel,$installBox,$dataLabel,$dataBox))

    $hardwareLabel = New-Object Windows.Forms.Label
    $hardwareLabel.Text = "GPU: $($Hardware.gpu_name)`r`nVRAM: $($Hardware.vram_mib) MiB`r`nDriver: $($Hardware.driver_version)`r`nCompute capability: $($Hardware.compute_capability)"
    $hardwareLabel.Location = New-Object Drawing.Point(28,34)
    $hardwareLabel.Size = New-Object Drawing.Size(680,180)
    $hardwareLabel.Font = New-Object Drawing.Font('Consolas',11)
    $tabs.TabPages[2].Controls.Add($hardwareLabel)

    $preferenceLabel = New-Object Windows.Forms.Label
    $preferenceLabel.Text = 'Model preference:'
    $preferenceLabel.Location = New-Object Drawing.Point(24,30)
    $preferenceLabel.AutoSize = $true
    $preferenceBox = New-Object Windows.Forms.ComboBox
    $preferenceBox.DropDownStyle = 'DropDownList'
    $preferenceBox.Location = New-Object Drawing.Point(24,56)
    $preferenceBox.Size = New-Object Drawing.Size(280,28)
    @('Recommended','Faster','HigherQuality') | ForEach-Object { $preferenceBox.Items.Add($_) | Out-Null }
    $preferenceBox.SelectedItem = 'Recommended'
    $modelDetails = New-Object Windows.Forms.Label
    $modelDetails.Location = New-Object Drawing.Point(24,108)
    $modelDetails.Size = New-Object Drawing.Size(700,260)
    $modelDetails.Font = New-Object Drawing.Font('Segoe UI',10)
    $tabs.TabPages[3].Controls.AddRange(@($preferenceLabel,$preferenceBox,$modelDetails))

    $mirrorLabel = New-Object Windows.Forms.Label
    $mirrorLabel.Text = 'Download route:'
    $mirrorLabel.Location = New-Object Drawing.Point(24,28)
    $mirrorLabel.AutoSize = $true
    $mirrorBox = New-Object Windows.Forms.ComboBox
    $mirrorBox.DropDownStyle = 'DropDownList'
    $mirrorBox.Location = New-Object Drawing.Point(24,54)
    $mirrorBox.Size = New-Object Drawing.Size(280,28)
    @('Official','China') | ForEach-Object { $mirrorBox.Items.Add($_) | Out-Null }
    $mirrorBox.SelectedItem = $Mirror
    $summaryLabel = New-Object Windows.Forms.Label
    $summaryLabel.Location = New-Object Drawing.Point(24,108)
    $summaryLabel.Size = New-Object Drawing.Size(700,260)
    $tabs.TabPages[4].Controls.AddRange(@($mirrorLabel,$mirrorBox,$summaryLabel))

    for ($index = 5; $index -le 7; $index++) {
        $label = New-Object Windows.Forms.Label
        $label.Location = New-Object Drawing.Point(28,40)
        $label.Size = New-Object Drawing.Size(680,160)
        $label.Font = New-Object Drawing.Font('Segoe UI',11)
        $label.Text = switch ($index) {
            5 { 'Installation progress is shown here after confirmation.' }
            6 { 'Runtime, CUDA, model, and service checks run before activation.' }
            7 { 'Installation is ready. Use the Live Avatar shortcut to start.' }
        }
        $tabs.TabPages[$index].Controls.Add($label)
    }

    $back = New-Object Windows.Forms.Button
    $back.Text = '< Back'
    $back.Location = New-Object Drawing.Point(510,516)
    $back.Size = New-Object Drawing.Size(86,32)
    $next = New-Object Windows.Forms.Button
    $next.Text = 'Next >'
    $next.Location = New-Object Drawing.Point(604,516)
    $next.Size = New-Object Drawing.Size(86,32)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object Drawing.Point(698,516)
    $cancel.Size = New-Object Drawing.Size(86,32)
    $form.Controls.AddRange(@($back,$next,$cancel))

    $script:WizardResult = $null
    $updateSelection = {
        $preference = [string]$preferenceBox.SelectedItem
        $candidate = Select-LiveAvatarModel -Profile $Hardware -Catalog $Catalog -Preference $preference
        $choices = Get-LiveAvatarModelChoices -Profile $Hardware -Catalog $Catalog
        $lines = New-Object Collections.Generic.List[string]
        $lines.Add("Selected: $($candidate.model.display_name) [$($candidate.mode)]")
        $lines.Add($candidate.reason)
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate.warning)) { $lines.Add("Warning: $($candidate.warning)") }
        if (-not $candidate.preference_available) { $lines.Add("Unavailable: $($candidate.disabled_reason)") }
        $lines.Add('')
        foreach ($item in $choices) {
            $status = if ($item.enabled) { $item.mode } else { "disabled - $($item.reason)" }
            $lines.Add("$($item.model.display_name): $status")
        }
        $modelDetails.Text = $lines -join "`r`n"
        $componentBytes = [int64]0
        foreach ($component in $Components) { $componentBytes += [int64]$component.bytes }
        $total = $componentBytes + [int64]$candidate.model.bytes
        $summaryLabel.Text = "Model: $($candidate.model.display_name)`r`nMode: $($candidate.mode)`r`nVerified download total: $(Format-Bytes $total)`r`nProgram: $($installBox.Text)`r`nData: $($dataBox.Text)"
        return $candidate
    }
    $preferenceBox.add_SelectedIndexChanged({ & $updateSelection | Out-Null })
    $installBox.add_TextChanged({ & $updateSelection | Out-Null })
    $dataBox.add_TextChanged({ & $updateSelection | Out-Null })
    & $updateSelection | Out-Null

    $back.add_Click({ if ($tabs.SelectedIndex -gt 0) { $tabs.SelectedIndex-- } })
    $next.add_Click({
        if ($tabs.SelectedIndex -lt 4) { $tabs.SelectedIndex++; return }
        $candidate = & $updateSelection
        if (-not $candidate.preference_available) {
            [Windows.Forms.MessageBox]::Show($candidate.disabled_reason, 'Model unavailable', 'OK', 'Warning') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($installBox.Text) -or [string]::IsNullOrWhiteSpace($dataBox.Text)) {
            [Windows.Forms.MessageBox]::Show('Both paths are required.', 'Invalid paths', 'OK', 'Warning') | Out-Null
            return
        }
        $script:WizardResult = [pscustomobject]@{
            confirmed=$true;install_root=$installBox.Text;data_root=$dataBox.Text
            preference=[string]$preferenceBox.SelectedItem;mirror=[string]$mirrorBox.SelectedItem
        }
        $form.DialogResult = 'OK'
        $form.Close()
    })
    $cancel.add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
    $tabs.add_SelectedIndexChanged({
        $back.Enabled = $tabs.SelectedIndex -gt 0
        $next.Text = if ($tabs.SelectedIndex -eq 4) { 'Install' } else { 'Next >' }
    })
    $back.Enabled = $false
    [void]$form.ShowDialog()
    return $script:WizardResult
}

Export-ModuleMember -Function Show-LiveAvatarInstallWizard
