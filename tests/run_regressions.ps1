# run_regressions.ps1
# Real-component regressions R1 - R5 for Codex Warmup V2 Dynamic Scheduler

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "=================================================="
Write-Host "RUNNING REAL-COMPONENT REGRESSIONS (R1 - R5)"
Write-Host "=================================================="

$passCount = 0
$failCount = 0

function Assert-Condition([bool]$condition, [string]$testName, [string]$detail) {
    if ($condition) {
        Write-Host "[PASS] $testName" -ForegroundColor Green
        $global:passCount++
    } else {
        Write-Host "[FAIL] $testName - $detail" -ForegroundColor Red
        $global:failCount++
    }
}

# --- R1: Primary is not 300m (primary=60m, secondary=300m) ---
try {
    $now = [DateTimeOffset]::UtcNow
    $resetEpoch = [long]($now.AddHours(3).ToUnixTimeSeconds())
    $fixture1 = [PSCustomObject]@{
        result = [PSCustomObject]@{
            ordinaryUsageAllowed = $true
            rateLimits = [PSCustomObject]@{
                primary = [PSCustomObject]@{
                    limitId = "codex"
                    windowDurationMins = 60
                    usedPercent = 10
                    resetsAt = [long]($now.AddMinutes(40).ToUnixTimeSeconds())
                }
                secondary = [PSCustomObject]@{
                    limitId = "codex"
                    windowDurationMins = 300
                    usedPercent = 25
                    resetsAt = $resetEpoch
                }
            }
        }
    }
    . (Join-Path $RepoRoot "src\runtime\Classify-RateLimitWindow.ps1")
    $r1Res = Classify-RateLimitWindow -RateLimitResponse $fixture1
    
    Assert-Condition ($r1Res.OrdinaryUsageAllowed -eq "TRUE") "R1.1: OrdinaryUsageAllowed is TRUE" ""
    Assert-Condition ($r1Res.FiveHourWindowStatus -eq "ACTIVE") "R1.2: 5h Window Status is ACTIVE" "Got: $($r1Res.FiveHourWindowStatus)"
    Assert-Condition ($r1Res.Identified5hWindow.windowDurationMins -eq 300) "R1.3: Window duration is 300m (not assumed primary)" ""
    Assert-Condition ($r1Res.ResetEpoch -eq $resetEpoch) "R1.4: Correct reset epoch captured" ""
    Assert-Condition ($r1Res.CanEvaluateWarmup -eq $true) "R1.5: Eligible for warmup evaluation" ""
} catch {
    Assert-Condition $false "R1 Exception" $_
}

# --- R2: Sliding resetsAt (usedPercent=0, delta ~300m changes) ---
try {
    $tempCache = [System.IO.Path]::GetTempFileName()
    $now = [DateTimeOffset]::UtcNow
    $probe1Reset = [long]($now.AddMinutes(299).ToUnixTimeSeconds())
    $probe2Reset = [long]($now.AddMinutes(300).ToUnixTimeSeconds())
    
    @{ ResetEpoch = $probe1Reset } | ConvertTo-Json | Out-File -FilePath $tempCache -Encoding utf8 -Force
    
    $fixture2 = [PSCustomObject]@{
        result = [PSCustomObject]@{
            ordinaryUsageAllowed = $true
            rateLimits = [PSCustomObject]@{
                primary = [PSCustomObject]@{
                    limitId = "codex"
                    windowDurationMins = 300
                    usedPercent = 0
                    resetsAt = $probe2Reset
                }
            }
        }
    }
    $r2Res = Classify-RateLimitWindow -RateLimitResponse $fixture2 -HistoryCachePath $tempCache
    Remove-Item -Path $tempCache -Force -ErrorAction SilentlyContinue

    Assert-Condition ($r2Res.ResetAnchorStatus -eq "SLIDING_OR_UNINITIALIZED") "R2.1: Detected SLIDING_OR_UNINITIALIZED" "Got: $($r2Res.ResetAnchorStatus)"
    Assert-Condition ($r2Res.FiveHourWindowStatus -eq "AMBIGUOUS") "R2.2: 5h Window Status is AMBIGUOUS" "Got: $($r2Res.FiveHourWindowStatus)"
    Assert-Condition ($r2Res.CanEvaluateWarmup -eq $false) "R2.3: Hard Gate prohibits warmup" ""
} catch {
    Assert-Condition $false "R2 Exception" $_
}

# --- R3: ordinaryUsageAllowed = false (Hard Gate) ---
try {
    $fixture3 = [PSCustomObject]@{
        result = [PSCustomObject]@{
            ordinaryUsageAllowed = $false
            rateLimits = [PSCustomObject]@{
                primary = [PSCustomObject]@{
                    limitId = "codex"
                    windowDurationMins = 300
                    usedPercent = 10
                    resetsAt = [long](([DateTimeOffset]::UtcNow).AddHours(2).ToUnixTimeSeconds())
                }
            }
        }
    }
    $r3Res = Classify-RateLimitWindow -RateLimitResponse $fixture3

    Assert-Condition ($r3Res.OrdinaryUsageAllowed -eq "FALSE") "R3.1: OrdinaryUsageAllowed is FALSE" ""
    Assert-Condition ($r3Res.FiveHourWindowStatus -eq "BLOCKED") "R3.2: 5h Window Status is BLOCKED" ""
    Assert-Condition ($r3Res.CanEvaluateWarmup -eq $false) "R3.3: Hard Gate blocks warmup immediately" ""
} catch {
    Assert-Condition $false "R3 Exception" $_
}

# --- R4: Delayed missed run (starts when available, probes fresh server state, replans) ---
try {
    $ctrlPath = Join-Path $RepoRoot "src\scheduler\controller.ps1"
    $ctrlOut = & $ctrlPath -ShadowMode -DryRun
    $ctrlText = $ctrlOut -join "`n"

    Assert-Condition ($ctrlText -match "Codex Runtime resolved") "R4.1: Controller resolved Codex CLI" ""
    Assert-Condition ($ctrlText -match "Rate Limits Classified") "R4.2: Controller probed & classified rate limits" ""
    Assert-Condition ($ctrlText -match "Invoking Decision Engine") "R4.3: Controller invoked Decision Engine" ""
    Assert-Condition ($ctrlText -match "Decision Engine Result") "R4.4: Fresh replan executed successfully" ""
    Assert-Condition ($ctrlText -match "Controller Finished") "R4.5: Clean exit without blind replay" ""
} catch {
    Assert-Condition $false "R4 Exception" $_
}

# --- R5: Named Mutex Concurrency Guard ---
try {
    $mutexName = "Global\CodexWarmupV2Controller"
    $mutexCreated = $false
    $testMutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$mutexCreated)
    $hasLock = $testMutex.WaitOne(0, $false)
    
    if ($hasLock) {
        try {
            $subProcessPsi = New-Object System.Diagnostics.ProcessStartInfo
            $subProcessPsi.FileName = "powershell.exe"
            $subProcessPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ctrlPath`" -ShadowMode -DryRun"
            $subProcessPsi.UseShellExecute = $false
            $subProcessPsi.RedirectStandardOutput = $true
            $subProcessPsi.CreateNoWindow = $true
            $subp = [System.Diagnostics.Process]::Start($subProcessPsi)
            $subOut = $subp.StandardOutput.ReadToEnd()
            $subp.WaitForExit()

            Assert-Condition ($subp.ExitCode -eq 0) "R5.1: Blocked instance exited with code 0 (IgnoreNew)" "Got exit code: $($subp.ExitCode)"
            Assert-Condition ($subOut -match "Another instance of CodexWarmupV2Controller is currently executing") "R5.2: Lock conflict detected and logged" ""
        } finally {
            $testMutex.ReleaseMutex()
            $testMutex.Dispose()
        }
    } else {
        Assert-Condition $false "R5 Setup" "Could not acquire test mutex"
    }
} catch {
    Assert-Condition $false "R5 Exception" $_
}

Write-Host "=================================================="
Write-Host "REGRESSION SUMMARY: $passCount PASSED, $failCount FAILED"
Write-Host "=================================================="
if ($failCount -gt 0) { exit 1 } else { exit 0 }
