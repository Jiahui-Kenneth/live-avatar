$script:LiveAvatarTestFailures = 0
$script:LiveAvatarTestPasses = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        $script:LiveAvatarTestFailures++
        Write-Host "FAIL: $Message (expected=<$Expected>, actual=<$Actual>)" -ForegroundColor Red
        return
    }
    $script:LiveAvatarTestPasses++
    Write-Host "PASS: $Message"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:LiveAvatarTestFailures++
        Write-Host "FAIL: $Message" -ForegroundColor Red
        return
    }
    $script:LiveAvatarTestPasses++
    Write-Host "PASS: $Message"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try {
        & $Action
        $script:LiveAvatarTestFailures++
        Write-Host "FAIL: $Message (no exception was thrown)" -ForegroundColor Red
    }
    catch {
        $script:LiveAvatarTestPasses++
        Write-Host "PASS: $Message"
    }
}

function Complete-TestRun {
    Write-Host "Tests: $script:LiveAvatarTestPasses passed, $script:LiveAvatarTestFailures failed"
    if ($script:LiveAvatarTestFailures -gt 0) { exit 1 }
}
