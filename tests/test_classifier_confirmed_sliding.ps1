# test_classifier_confirmed_sliding.ps1
# Deterministic fixture regressions for Classifier C1 - C5
# Validates confirmed sliding idle detection vs unresolved ambiguity.
# ZERO network calls; synthetic timestamps modeled on verified provider behavior.

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
Write-Host "RUNNING CLASSIFIER CONFIRMED SLIDING TESTS (C1 - C5)"
Write-Host "=================================================="

Import-Module (Join-Path $RepoRoot "src\runtime\RateLimitClassifier.psm1") -Force

$baseTime = [DateTimeOffset]::Parse("2026-09-19T10:00:00+08:00")

function New-RateLimitPayload([long]$resetsAt, [double]$usedPercent = 0.0, [bool]$ordinaryAllowed = $true, [bool]$weeklyBlocked = $false) {
    return [PSCustomObject]@{
        result = [PSCustomObject]@{
            ordinaryUsageAllowed = $ordinaryAllowed
            rateLimitsByLimitId = [PSCustomObject]@{
                codex = [PSCustomObject]@{
                    limitReached = $weeklyBlocked
                    primary = [PSCustomObject]@{
                        limitId = "codex"
                        windowDurationMins = 300
                        usedPercent = $usedPercent
                        resetsAt = $resetsAt
                    }
                    secondary = [PSCustomObject]@{
                        limitId = "codex"
                        windowDurationMins = 10080
                        usedPercent = 20.0
                        resetsAt = ($resetsAt + 500000)
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------
# C1: First 0% now+5h observation -> AMBIGUOUS / false
# ---------------------------------------------------------------
try {
    $now1 = $baseTime
    $resetEpoch1 = [long]($now1.AddHours(5).ToUnixTimeSeconds())
    $payload1 = New-RateLimitPayload -resetsAt $resetEpoch1 -usedPercent 0

    # Case 1a: No previous probe ($null)
    $res1a = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload1 -CurrentTime $now1 -PreviousProbe $null
    Assert-Check ($res1a.ResetAnchorStatus -eq "SLIDING_OR_UNINITIALIZED") "C1.1: Anchor is SLIDING_OR_UNINITIALIZED" "Got: $($res1a.ResetAnchorStatus)"
    Assert-Check ($res1a.FiveHourWindowStatus -eq "AMBIGUOUS") "C1.2: Status is AMBIGUOUS" "Got: $($res1a.FiveHourWindowStatus)"
    Assert-Check ($res1a.CanEvaluateWarmup -eq $false) "C1.3: CanEvaluateWarmup is false" "Got: $($res1a.CanEvaluateWarmup)"
    Assert-Check ($res1a.Reason -match "Needs subsequent probe") "C1.4: Reason indicates subsequent probe required" "Got: $($res1a.Reason)"

    # Case 1b: Previous probe with empty object (no ResetEpoch)
    $res1b = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload1 -CurrentTime $now1 -PreviousProbe ([PSCustomObject]@{})
    Assert-Check ($res1b.FiveHourWindowStatus -eq "AMBIGUOUS" -and $res1b.CanEvaluateWarmup -eq $false) "C1.5: Empty PreviousProbe fails closed to AMBIGUOUS" ""
} catch {
    Assert-Check $false "C1 Exception" $_
}

# ---------------------------------------------------------------
# C2: Successive probes with reset movement matching elapsed time
#     -> INACTIVE / SLIDING_OR_UNINITIALIZED / true
# ---------------------------------------------------------------
try {
    $t0 = $baseTime
    $r0 = [long]($t0.AddHours(5).ToUnixTimeSeconds())

    # Successive probe 10 minutes (600s) later; resetEpoch moved by exactly 600s
    $t1 = $t0.AddMinutes(10)
    $r1 = [long]($r0 + 600)
    $prevProbeExact = [PSCustomObject]@{
        Timestamp  = $t0.ToString("o")
        ResetEpoch = $r0
        Status     = "AMBIGUOUS"
    }
    $payload2a = New-RateLimitPayload -resetsAt $r1 -usedPercent 0
    $res2a = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload2a -CurrentTime $t1 -PreviousProbe $prevProbeExact

    Assert-Check ($res2a.ResetAnchorStatus -eq "SLIDING_OR_UNINITIALIZED") "C2.1: Exact lockstep anchor is SLIDING_OR_UNINITIALIZED" "Got: $($res2a.ResetAnchorStatus)"
    Assert-Check ($res2a.FiveHourWindowStatus -eq "INACTIVE") "C2.2: Exact lockstep status is INACTIVE" "Got: $($res2a.FiveHourWindowStatus)"
    Assert-Check ($res2a.CanEvaluateWarmup -eq $true) "C2.3: Exact lockstep CanEvaluateWarmup is true" "Got: $($res2a.CanEvaluateWarmup)"
    Assert-Check ($res2a.Reason -match "confirmed by successive probes") "C2.4: Reason explicitly states confirmed by successive probes" "Got: $($res2a.Reason)"

    # Probe with small jitter within 5s tolerance (elapsed 600s, epoch delta 602s -> drift 2s)
    $r1_jitter = [long]($r0 + 602)
    $payload2b = New-RateLimitPayload -resetsAt $r1_jitter -usedPercent 0
    $res2b = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload2b -CurrentTime $t1 -PreviousProbe $prevProbeExact

    Assert-Check ($res2b.FiveHourWindowStatus -eq "INACTIVE") "C2.5: Small jittered lockstep (2s drift) status is INACTIVE" "Got: $($res2b.FiveHourWindowStatus)"
    Assert-Check ($res2b.CanEvaluateWarmup -eq $true) "C2.6: Small jittered lockstep CanEvaluateWarmup is true" "Got: $($res2b.CanEvaluateWarmup)"
} catch {
    Assert-Check $false "C2 Exception" $_
}

# ---------------------------------------------------------------
# C3: Changed resetEpoch but movement is inconsistent with elapsed time
#     -> AMBIGUOUS / false
# ---------------------------------------------------------------
try {
    $t0 = $baseTime
    $r0 = [long]($t0.AddHours(5).ToUnixTimeSeconds())
    $t1 = $t0.AddMinutes(10) # 600 seconds elapsed

    # Case 3a: Large drift (elapsed 600s, epoch delta 1800s -> drift 1200s)
    $r1_divergent = [long]($r0 + 1800)
    $prevWithTime = [PSCustomObject]@{
        Timestamp  = $t0.ToString("o")
        ResetEpoch = $r0
    }
    $payload3a = New-RateLimitPayload -resetsAt $r1_divergent -usedPercent 0
    $res3a = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload3a -CurrentTime $t1 -PreviousProbe $prevWithTime

    Assert-Check ($res3a.ResetAnchorStatus -eq "SLIDING_OR_UNINITIALIZED") "C3.1: Divergent movement anchor is SLIDING_OR_UNINITIALIZED" ""
    Assert-Check ($res3a.FiveHourWindowStatus -eq "AMBIGUOUS") "C3.2: Divergent movement status is AMBIGUOUS" "Got: $($res3a.FiveHourWindowStatus)"
    Assert-Check ($res3a.CanEvaluateWarmup -eq $false) "C3.3: Divergent movement CanEvaluateWarmup is false" ""

    # Case 3b: PreviousProbe lacks observation timestamp
    $prevNoTime = [PSCustomObject]@{
        ResetEpoch = $r0
    }
    $payload3b = New-RateLimitPayload -resetsAt ($r0 + 600) -usedPercent 0
    $res3b = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload3b -CurrentTime $t1 -PreviousProbe $prevNoTime

    Assert-Check ($res3b.FiveHourWindowStatus -eq "AMBIGUOUS") "C3.4: Missing timestamp fails closed to AMBIGUOUS" "Got: $($res3b.FiveHourWindowStatus)"
    Assert-Check ($res3b.CanEvaluateWarmup -eq $false) "C3.5: Missing timestamp CanEvaluateWarmup is false" ""
    Assert-Check ($res3b.Reason -match "lacks observation timestamp") "C3.6: Reason notes missing timestamp" "Got: $($res3b.Reason)"

    # Case 3c: Epoch moved backwards relative to wall clock (deltaMinutes still ~300m)
    $prevSkewed = [PSCustomObject]@{
        Timestamp  = $t0.ToString("o")
        ResetEpoch = [long]($t0.ToUnixTimeSeconds() + 18500)
    }
    $payload3c = New-RateLimitPayload -resetsAt ([long]($t0.ToUnixTimeSeconds() + 18400)) -usedPercent 0
    $res3c = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload3c -CurrentTime $t1 -PreviousProbe $prevSkewed
    Assert-Check ($res3c.FiveHourWindowStatus -eq "AMBIGUOUS" -and $res3c.CanEvaluateWarmup -eq $false) "C3.7: Backward epoch movement fails closed to AMBIGUOUS" ""

    # Case 3d: Real provider post-warmup transition counterexample
    # Previous sliding observation:
    # Timestamp = 2026-09-19T18:06:45.3858447+08:00, ResetEpoch = 1789830405
    # First observation after successful warmup:
    # CurrentTime = 2026-09-19T18:07:35.4452660+08:00, ResetEpoch = 1789830432
    # Elapsed ~50.06s, Reset movement = 27s, Drift ~23.06s (> 5s tolerance)
    # Must fail closed to AMBIGUOUS / false (not falsely classified as confirmed sliding)
    $realPrevTime = [DateTimeOffset]::Parse("2026-09-19T18:06:45.3858447+08:00")
    $realCurrentTime = [DateTimeOffset]::Parse("2026-09-19T18:07:35.4452660+08:00")
    $prevRealWarmup = [PSCustomObject]@{
        Timestamp  = $realPrevTime.ToString("o")
        ResetEpoch = 1789830405
        Status     = "AMBIGUOUS"
    }
    $payloadReal = New-RateLimitPayload -resetsAt 1789830432 -usedPercent 0
    $resReal = ConvertTo-NormalizedQuotaState -RateLimitResponse $payloadReal -CurrentTime $realCurrentTime -PreviousProbe $prevRealWarmup

    Assert-Check ($resReal.ResetAnchorStatus -eq "SLIDING_OR_UNINITIALIZED") "C3.8: Real transition anchor is SLIDING_OR_UNINITIALIZED" "Got: $($resReal.ResetAnchorStatus)"
    Assert-Check ($resReal.FiveHourWindowStatus -eq "AMBIGUOUS") "C3.9: Real transition fails closed to AMBIGUOUS (23s drift > 5s tolerance)" "Got: $($resReal.FiveHourWindowStatus)"
    Assert-Check ($resReal.CanEvaluateWarmup -eq $false) "C3.10: Real transition CanEvaluateWarmup is false" "Got: $($resReal.CanEvaluateWarmup)"
} catch {
    Assert-Check $false "C3 Exception" $_
}

# ---------------------------------------------------------------
# C4: Same future resetEpoch across probes -> ACTIVE / FIXED / true
# ---------------------------------------------------------------
try {
    $t0 = $baseTime
    $fixedEpoch = [long]($t0.AddHours(4).ToUnixTimeSeconds())
    $t1 = $t0.AddMinutes(15)

    $prevFixed = [PSCustomObject]@{
        Timestamp  = $t0.ToString("o")
        ResetEpoch = $fixedEpoch
        Status     = "ACTIVE"
    }
    $payload4 = New-RateLimitPayload -resetsAt $fixedEpoch -usedPercent 15.0
    $res4 = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload4 -CurrentTime $t1 -PreviousProbe $prevFixed

    Assert-Check ($res4.ResetAnchorStatus -eq "FIXED") "C4.1: Same future resetEpoch anchor is FIXED" "Got: $($res4.ResetAnchorStatus)"
    Assert-Check ($res4.FiveHourWindowStatus -eq "ACTIVE") "C4.2: Same future resetEpoch status is ACTIVE" "Got: $($res4.FiveHourWindowStatus)"
    Assert-Check ($res4.CanEvaluateWarmup -eq $true) "C4.3: Same future resetEpoch CanEvaluateWarmup is true" "Got: $($res4.CanEvaluateWarmup)"
} catch {
    Assert-Check $false "C4 Exception" $_
}

# ---------------------------------------------------------------
# C5: Weekly and ordinary hard gates unchanged
# ---------------------------------------------------------------
try {
    $t0 = $baseTime
    $futureReset = [long]($t0.AddHours(3).ToUnixTimeSeconds())

    # Case 5a: ordinaryUsageAllowed = false
    $payload5a = New-RateLimitPayload -resetsAt $futureReset -usedPercent 10 -ordinaryAllowed $false
    $res5a = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload5a -CurrentTime $t0
    Assert-Check ($res5a.OrdinaryUsageAllowed -eq "FALSE") "C5.1: OrdinaryUsageAllowed is FALSE" ""
    Assert-Check ($res5a.FiveHourWindowStatus -eq "BLOCKED") "C5.2: Status is BLOCKED" ""
    Assert-Check ($res5a.CanEvaluateWarmup -eq $false) "C5.3: CanEvaluateWarmup is false under ordinary gate" ""

    # Case 5b: weeklyBlocked = true
    $payload5b = New-RateLimitPayload -resetsAt $futureReset -usedPercent 10 -ordinaryAllowed $true -weeklyBlocked $true
    $res5b = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload5b -CurrentTime $t0
    Assert-Check ($res5b.WeeklyBlocked -eq $true) "C5.4: WeeklyBlocked is true" ""
    Assert-Check ($res5b.FiveHourWindowStatus -eq "BLOCKED") "C5.5: Status is BLOCKED under weekly gate" ""
    Assert-Check ($res5b.CanEvaluateWarmup -eq $false) "C5.6: CanEvaluateWarmup is false under weekly gate" ""
} catch {
    Assert-Check $false "C5 Exception" $_
}

Write-Host "=================================================="
Write-Host "C1-C5 SUMMARY: $passCount PASSED, $failCount FAILED"
Write-Host "=================================================="
if ($failCount -gt 0) { exit 1 } else { exit 0 }
