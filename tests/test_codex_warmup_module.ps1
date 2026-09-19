# test_codex_warmup_module.ps1
# Regression test for CodexWarmup module-root resolution defect
# Proves that invoking imported Invoke-CodexWarmup and Execute-CodexWarmup.ps1
# does not fail with "Cannot bind argument to parameter 'Path' because it is null".
# ZERO Codex quota consumed; uses a harmless mock executable.

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
Write-Host "TEST CODEX WARMUP MODULE REGRESSION"
Write-Host "=================================================="

# Create harmless mock process returning 'Ready'
$mockExe = Join-Path $env:TEMP "mock_codex_ready.bat"
"@echo Ready" | Set-Content -Path $mockExe -Encoding ascii

try {
    # 1. Test direct module import and invocation
    Import-Module (Join-Path $RepoRoot "src\runtime\CodexWarmup.psm1") -Force
    
    $invokedDirect = $false
    $directError = $null
    try {
        $resDirect = Invoke-CodexWarmup -CodexExe $mockExe -Prompt "Ready" -TimeoutSeconds 5
        $invokedDirect = ($resDirect -and $resDirect.Success -and ($resDirect.Stdout -match "Ready"))
    } catch {
        $directError = $_.Exception.Message
    }

    Assert-Check ($invokedDirect -and -not $directError) "Invoke-CodexWarmup executes without null Path binding failure" "Error: $directError"

    # 2. Test execution via Execute-CodexWarmup.ps1 wrapper
    $wrapperScript = Join-Path $RepoRoot "src\runtime\Execute-CodexWarmup.ps1"
    $invokedWrapper = $false
    $wrapperError = $null
    try {
        $resWrapper = & $wrapperScript -CodexExe $mockExe -Prompt "Ready" -TimeoutSeconds 5
        $invokedWrapper = ($resWrapper -and $resWrapper.Success -and ($resWrapper.Stdout -match "Ready"))
    } catch {
        $wrapperError = $_.Exception.Message
    }

    Assert-Check ($invokedWrapper -and -not $wrapperError) "Execute-CodexWarmup.ps1 executes without null Path binding failure" "Error: $wrapperError"

} finally {
    if (Test-Path $mockExe) {
        Remove-Item -Path $mockExe -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nPassed: $passCount, Failed: $failCount"
if ($failCount -gt 0) {
    exit 1
}
exit 0
