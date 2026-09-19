# test_process_runner_timeout.ps1
# Regression test for ProcessRunner timeout-observability defect.
# Proves that when a child process exceeds hard timeout:
#   1. Process-tree termination occurs (TimedOut == true, ExitCode == -1).
#   2. Pre-timeout child stderr is preserved alongside the timeout diagnostic.
# Also verifies that normal (non-timed-out) child execution preserves stdout/stderr.
# ZERO network calls; ZERO Codex quota consumed; uses harmless mock scripts.

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

$passCount = 0
$failCount = 0

function Assert-Check([bool]$condition, [string]$testName, [string]$detail = "") {
    if ($condition) {
        Write-Host "[PASS] $testName" -ForegroundColor Green
        $global:passCount++
    } else {
        Write-Host "[FAIL] $testName - $detail" -ForegroundColor Red
        $global:failCount++
    }
}

Write-Host "=================================================="
Write-Host "TEST PROCESS RUNNER TIMEOUT OBSERVABILITY"
Write-Host "=================================================="

Import-Module (Join-Path $RepoRoot "src\runtime\ProcessRunner.psm1") -Force

$mockTimeoutBat = Join-Path $env:TEMP "mock_pr_timeout.bat"
$mockSuccessBat = Join-Path $env:TEMP "mock_pr_success.bat"

# Mock 1: writes marker to stderr and sleeps past 1s timeout
$timeoutContent = @"
@echo off
echo DIAGNOSTIC_BEFORE_TIMEOUT 1>&2
ping 127.0.0.1 -n 4 > nul
"@
$timeoutContent | Set-Content -Path $mockTimeoutBat -Encoding ascii

# Mock 2: writes to stdout and stderr, exits immediately with 0
$successContent = @"
@echo off
echo NORMAL_STDOUT_LINE
echo NORMAL_STDERR_LINE 1>&2
exit /b 0
"@
$successContent | Set-Content -Path $mockSuccessBat -Encoding ascii

try {
    # 1. Test timeout observability
    $resTimeout = Invoke-BoundedProcess -FilePath "cmd.exe" -Arguments "/c `"$mockTimeoutBat`"" -TimeoutSeconds 1

    Assert-Check ($resTimeout.TimedOut -eq $true) "Timeout test: TimedOut is true" "Got: $($resTimeout.TimedOut)"
    Assert-Check ($resTimeout.ExitCode -eq -1) "Timeout test: ExitCode is -1" "Got: $($resTimeout.ExitCode)"
    Assert-Check ($resTimeout.Success -eq $false) "Timeout test: Success is false" "Got: $($resTimeout.Success)"
    Assert-Check ($resTimeout.Stderr -match "DIAGNOSTIC_BEFORE_TIMEOUT") "Timeout test: Child stderr marker preserved" "Stderr was: $($resTimeout.Stderr)"
    Assert-Check ($resTimeout.Stderr -match "exceeded hard timeout") "Timeout test: Timeout diagnostic indicated in Stderr" "Stderr was: $($resTimeout.Stderr)"

    # 2. Test normal execution preservation
    $resSuccess = Invoke-BoundedProcess -FilePath "cmd.exe" -Arguments "/c `"$mockSuccessBat`"" -TimeoutSeconds 5

    Assert-Check ($resSuccess.TimedOut -eq $false) "Normal test: TimedOut is false" "Got: $($resSuccess.TimedOut)"
    Assert-Check ($resSuccess.ExitCode -eq 0) "Normal test: ExitCode is 0" "Got: $($resSuccess.ExitCode)"
    Assert-Check ($resSuccess.Success -eq $true) "Normal test: Success is true" "Got: $($resSuccess.Success)"
    Assert-Check ($resSuccess.Stdout -match "NORMAL_STDOUT_LINE") "Normal test: Stdout preserved" "Stdout was: $($resSuccess.Stdout)"
    Assert-Check ($resSuccess.Stderr -match "NORMAL_STDERR_LINE") "Normal test: Stderr preserved" "Stderr was: $($resSuccess.Stderr)"

} finally {
    if (Test-Path $mockTimeoutBat) {
        Remove-Item -Path $mockTimeoutBat -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $mockSuccessBat) {
        Remove-Item -Path $mockSuccessBat -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nPassed: $passCount, Failed: $failCount"
if ($failCount -gt 0) {
    exit 1
}
exit 0
