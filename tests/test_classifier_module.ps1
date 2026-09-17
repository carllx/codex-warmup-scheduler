# test_classifier_module.ps1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "T=0: Testing RateLimitClassifier.psm1 import & function call"

Import-Module ".\src\runtime\RateLimitClassifier.psm1" -Force
Write-Host "T=$($sw.ElapsedMilliseconds)ms: Module imported cleanly (zero stdin wait)"

# Use future epoch for active window test
$futureEpoch = [long]([DateTimeOffset]::UtcNow.AddHours(3).ToUnixTimeSeconds())

$samplePayload = @{
    result = @{
        ordinaryUsageAllowed = $true
        rateLimitsByLimitId = @{
            codex = @{
                primary = @{ windowDurationMins = 300; usedPercent = 35; resetsAt = $futureEpoch }
                secondary = @{ windowDurationMins = 10080; usedPercent = 9; resetsAt = ($futureEpoch + 100000) }
            }
        }
    }
}

$state = ConvertTo-NormalizedQuotaState -RateLimitResponse $samplePayload -CodexRuntimeVersion "codex-cli 0.154.0-alpha.6.2"
Write-Host "T=$($sw.ElapsedMilliseconds)ms: Function returned NormalizedQuotaState"
Write-Host "  OrdinaryUsageAllowed: $($state.OrdinaryUsageAllowed)"
Write-Host "  FiveHourWindowStatus: $($state.FiveHourWindowStatus)"
Write-Host "  ResetAnchorStatus:    $($state.ResetAnchorStatus)"
Write-Host "  ResetAt:              $($state.ResetAt)"
Write-Host "  CanEvaluateWarmup:    $($state.CanEvaluateWarmup)"

if ($state.FiveHourWindowStatus -eq "ACTIVE" -and $state.CanEvaluateWarmup -eq $true) {
    Write-Host "SUCCESS: RateLimitClassifier module verified."
    exit 0
} else {
    throw "Module test failed"
}
