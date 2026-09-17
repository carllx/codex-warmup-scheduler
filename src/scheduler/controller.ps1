# controller.ps1
# Codex Warmup V2 Production Runtime Controller
# Executed by Windows Task Scheduler from %LOCALAPPDATA%\CodexWarmupV2\runtime\

[CmdletBinding()]
param(
    [switch]$ShadowMode,
    [switch]$DryRun,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

# Concurrency Guard: Named Mutex Global\CodexWarmupV2Controller
$mutexName = "Global\CodexWarmupV2Controller"
$mutexCreated = $false
$mutex = $null

try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$mutexCreated)
    $hasHandle = $mutex.WaitOne(0, $false)
    if (-not $hasHandle) {
        Write-Host "[$([DateTime]::Now.ToString('o'))][WARN] Another instance of CodexWarmupV2Controller is currently executing. Exiting immediately (IgnoreNew)."
        exit 0
    }
} catch {
    Write-Warning "Failed to initialize or acquire named mutex '$mutexName': $_"
}

try {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (Test-Path (Join-Path $ScriptDir "decision_engine.py")) {
        $RuntimeDir   = $ScriptDir
        $EngineDir    = $ScriptDir
        $SchedulerDir = $ScriptDir
        $BaseDir      = Split-Path -Parent $ScriptDir
    } else {
        $RuntimeDir   = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\runtime"))
        $EngineDir    = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\engine"))
        $SchedulerDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\scheduler"))
        $BaseDir      = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\.."))
    }

    $LogsDir   = Join-Path $BaseDir "logs"
    $StateDir  = Join-Path $BaseDir "state"
    $ConfigDir = Join-Path $BaseDir "config"

    foreach ($d in @($LogsDir, $StateDir, $ConfigDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    $TodayStr = (Get-Date).ToString("yyyy-MM-dd")
    $LogFile = Join-Path $LogsDir "warmup-$TodayStr.log"
    $StateFile = Join-Path $StateDir "runtime_state.json"
    $ProbeCacheFile = Join-Path $StateDir "probe_cache.json"

    function Log-Message([string]$msg, [string]$level = "INFO") {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $entry = "[$ts][$level] $msg"
        Write-Host $entry
        Add-Content -Path $LogFile -Value $entry -Encoding utf8
    }

    Log-Message "=== Codex Warmup V2 Controller Started ==="
    Log-Message "Execution Mode: ShadowMode=$($ShadowMode.IsPresent), DryRun=$($DryRun.IsPresent)"

    # 1. Resolve Codex Executable
    . (Join-Path $RuntimeDir "Resolve-CodexRuntime.ps1")
    $runtime = Resolve-CodexExecutable
    if (-not $runtime.validated) {
        Log-Message "Failed to resolve valid Codex CLI: $($runtime.source)" "ERROR"
        exit 1
    }
    Log-Message "Codex Runtime resolved: $($runtime.path) (version: $($runtime.version), source: $($runtime.source))"

    # Function to query and classify rate limits
    function Get-ClassifiedQuotaState {
        param([string]$CacheFile)
        
        $rateLimitJson = $null
        try {
            $rateLimitRaw = & (Join-Path $RuntimeDir "Get-CodexRateLimits.ps1")
            $rawStr = if ($rateLimitRaw -is [System.Array]) { $rateLimitRaw -join "`n" } else { [string]$rateLimitRaw }
            if ($rawStr -match "(?ms)RATE_LIMIT_JSON_START\s*(.*?)\s*RATE_LIMIT_JSON_END") {
                $rateLimitJson = $matches[1].Trim() | ConvertFrom-Json
            } elseif ($rateLimitRaw -is [System.Array] -and $rateLimitRaw.Count -ge 2) {
                $rateLimitJson = $rateLimitRaw[1] | ConvertFrom-Json
            } else {
                $rateLimitJson = $rawStr | ConvertFrom-Json
            }
        } catch {
            Log-Message "Error querying app-server rate limits: $_" "WARN"
            return $null
        }

        Import-Module (Join-Path $RuntimeDir "RateLimitClassifier.psm1") -Force
        $prevProbe = $null
        if ($CacheFile -and (Test-Path $CacheFile)) {
            try { $prevProbe = Get-Content $CacheFile -Raw | ConvertFrom-Json } catch {}
        }
        $classification = ConvertTo-NormalizedQuotaState `
            -RateLimitResponse $rateLimitJson `
            -PreviousProbe $prevProbe `
            -CurrentTime ([DateTimeOffset]::Now) `
            -CodexRuntimeVersion $runtime.version
        
        # Update probe cache
        if ($classification.ResetEpoch) {
            @{
                Timestamp  = (Get-Date).ToString("o")
                ResetEpoch = $classification.ResetEpoch
                ResetAt    = $classification.ResetAt
                Status     = $classification.FiveHourWindowStatus
            } | ConvertTo-Json | Out-File -FilePath $CacheFile -Encoding utf8 -Force
        }
        
        return [PSCustomObject]@{
            Raw            = $rateLimitJson
            Classification = $classification
        }
    }

    # 2. Query App Server for Rate Limits & Classify
    $quota = Get-ClassifiedQuotaState -CacheFile $ProbeCacheFile
    if (-not $quota -or -not $quota.Classification) {
        Log-Message "Rate limits query failed or unparseable. Fail-Closed: scheduling safety probe in 30 minutes." "WARN"
        . (Join-Path $SchedulerDir "Update-ScheduledTrigger.ps1")
        Update-ScheduledTrigger -TargetDateTime (Get-Date).AddMinutes(30) -ShadowMode:$ShadowMode.IsPresent -DryRun:$DryRun.IsPresent
        exit 0
    }

    $cls = $quota.Classification
    Log-Message "Rate Limits Classified: ordinaryUsageAllowed=$($cls.OrdinaryUsageAllowed), 5hStatus=$($cls.FiveHourWindowStatus), resetAnchor=$($cls.ResetAnchorStatus), weeklyBlocked=$($cls.WeeklyBlocked), resetsAt=$($cls.ResetAt), reason=$($cls.Reason)"

    # Hard Gate 1: Check Quota Uncertainty / Ambiguity / Ordinary Usage Hard Gate
    if (-not $cls.CanEvaluateWarmup) {
        Log-Message "Hard Gate Triggered: Quota state not eligible for warmup evaluation ($($cls.FiveHourWindowStatus)). Scheduling bounded probe later." "WARN"
        
        $nextProbeMinutes = 15
        if ($cls.FiveHourWindowStatus -eq "AMBIGUOUS") {
            $nextProbeMinutes = 10
        } elseif ($cls.OrdinaryUsageAllowed -eq "FALSE" -or $cls.FiveHourWindowStatus -eq "BLOCKED") {
            $nextProbeMinutes = 60
        }

        $nextProbeTime = (Get-Date).AddMinutes($nextProbeMinutes)
        Log-Message "Scheduling next safety probe at $($nextProbeTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        
        . (Join-Path $SchedulerDir "Update-ScheduledTrigger.ps1")
        Update-ScheduledTrigger -TargetDateTime $nextProbeTime -ShadowMode:$ShadowMode.IsPresent -DryRun:$DryRun.IsPresent
        
        $stateRecord = [PSCustomObject]@{
            timestamp      = (Get-Date).ToString("o")
            action         = "PROBE_LATER"
            classification = $cls
            nextProbeTime  = $nextProbeTime.ToString("o")
            shadowMode     = $ShadowMode.IsPresent
        }
        $stateRecord | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFile -Encoding utf8
        exit 0
    }

    # 3. Prepare Engine Context & Run Decision Engine
    if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) {
        $candConfig = Join-Path $ConfigDir "default.json"
        if (-not (Test-Path $candConfig)) {
            $candConfig = Join-Path $BaseDir "config\default.json"
        }
        $ConfigPath = $candConfig
    }

    $nowIso = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $engineScript = Join-Path $EngineDir "decision_engine.py"

    $engineArgs = @(
        "`"$engineScript`"",
        "--now", "`"$nowIso`"",
        "--config", "`"$ConfigPath`"",
        "--window-status", "`"$($cls.FiveHourWindowStatus)`""
    )

    if ($cls.ResetAt) {
        $engineArgs += @("--active-until", "`"$($cls.ResetAt)`"")
    }
    if ($cls.WeeklyBlocked) {
        $engineArgs += "--weekly-exhausted"
    }

    Log-Message "Invoking Decision Engine: python $($engineArgs -join ' ')"

    $enginePsi = New-Object System.Diagnostics.ProcessStartInfo
    $enginePsi.FileName = "python"
    $enginePsi.Arguments = $engineArgs -join " "
    $enginePsi.UseShellExecute = $false
    $enginePsi.RedirectStandardOutput = $true
    $enginePsi.RedirectStandardError = $true
    $enginePsi.CreateNoWindow = $true

    $engineProc = [System.Diagnostics.Process]::Start($enginePsi)
    $engineOut = $engineProc.StandardOutput.ReadToEnd()
    $engineErr = $engineProc.StandardError.ReadToEnd()
    $engineProc.WaitForExit()

    if ($engineProc.ExitCode -ne 0) {
        Log-Message "Decision Engine failed with exit code $($engineProc.ExitCode): $engineErr" "ERROR"
        exit 2
    }

    $decision = $engineOut | ConvertFrom-Json
    Log-Message "Decision Engine Result: Action=$($decision.decision), ScheduledTime=$($decision.scheduledTime), ExpectedBoundary=$($decision.expectedBoundary), Score=$($decision.score), Reason=$($decision.reason)"

    # Save initial runtime state
    $currentState = [PSCustomObject]@{
        timestamp      = $nowIso
        runtime        = $runtime
        classification = $cls
        decision       = $decision
        shadowMode     = $ShadowMode.IsPresent
        dryRun         = $DryRun.IsPresent
    }
    $currentState | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFile -Encoding utf8

    # 4. Action Execution & Transaction Chain
    . (Join-Path $SchedulerDir "Update-ScheduledTrigger.ps1")

    switch ($decision.decision) {
        "WARMUP_NOW" {
            Log-Message "Decision is WARMUP_NOW."
            if ($ShadowMode) {
                Log-Message "[ShadowMode] Simulated Warmup completed. Proceeding to simulated re-probe & reschedule."
            } else {
                Log-Message "Invoking Execute-CodexWarmup.ps1..."
                . (Join-Path $RuntimeDir "Execute-CodexWarmup.ps1")
                $res = Execute-CodexWarmup -CodexExe $runtime.path
                Log-Message "Warmup completed. ExitCode=$($res.ExitCode), Output=$($res.Stdout)"
                if (-not $res.Success) {
                    Log-Message "Warmup execution did not return Ready or failed. Scheduling retry in 5 minutes." "ERROR"
                    Update-ScheduledTrigger -TargetDateTime (Get-Date).AddMinutes(5) -ShadowMode:$ShadowMode.IsPresent -DryRun:$DryRun.IsPresent
                    exit 3
                }
            }

            # Transaction Chain Step: Warmup -> fresh probe -> classify -> replan -> trigger update -> read-back verify
            Log-Message "Executing Transaction Chain: Re-probing fresh rate limits post-warmup..."
            Start-Sleep -Seconds 2
            $postQuota = Get-ClassifiedQuotaState -CacheFile $ProbeCacheFile
            $postCls = $postQuota.Classification
            Log-Message "Post-Warmup Classification: 5hStatus=$($postCls.FiveHourWindowStatus), resetsAt=$($postCls.ResetAt)"

            $postNowIso = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
            $postEngineArgs = @(
                "`"$engineScript`"",
                "--now", "`"$postNowIso`"",
                "--config", "`"$ConfigPath`"",
                "--window-status", "`"$($postCls.FiveHourWindowStatus)`""
            )
            if ($postCls.ResetAt) { $postEngineArgs += @("--active-until", "`"$($postCls.ResetAt)`"") }
            if ($postCls.WeeklyBlocked) { $postEngineArgs += "--weekly-exhausted" }

            $enginePsi.Arguments = $postEngineArgs -join " "
            $postProc = [System.Diagnostics.Process]::Start($enginePsi)
            $postOut = $postProc.StandardOutput.ReadToEnd()
            $postProc.WaitForExit()
            
            $postDecision = $postOut | ConvertFrom-Json
            Log-Message "Post-Warmup Replanned: Action=$($postDecision.decision), NextSchedule=$($postDecision.scheduledTime)"

            if ($postDecision.scheduledTime) {
                $targetTime = [DateTime]::Parse($postDecision.scheduledTime)
                $trigRes = Update-ScheduledTrigger -TargetDateTime $targetTime -ShadowMode:$ShadowMode.IsPresent -DryRun:$DryRun.IsPresent
                Log-Message "Post-Warmup Trigger Registration: Verified NextRunTime=$($trigRes.NextRunTime)"
            }
        }
        "SCHEDULE_WARMUP" {
            Log-Message "Scheduling next wakeup at: $($decision.scheduledTime)"
            $targetTime = [DateTime]::Parse($decision.scheduledTime)
            $trigRes = Update-ScheduledTrigger -TargetDateTime $targetTime -ShadowMode:$ShadowMode.IsPresent -DryRun:$DryRun.IsPresent
            Log-Message "Trigger Registration: Verified NextRunTime=$($trigRes.NextRunTime)"
        }
        "NO_ACTION" {
            Log-Message "No action required: $($decision.reason). Scheduling safety probe in 60 minutes."
            $targetTime = (Get-Date).AddMinutes(60)
            Update-ScheduledTrigger -TargetDateTime $targetTime -ShadowMode:$ShadowMode.IsPresent -DryRun:$DryRun.IsPresent
        }
    }

    Log-Message "=== Codex Warmup V2 Controller Finished ==="

} finally {
    if ($mutex -and $hasHandle) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
