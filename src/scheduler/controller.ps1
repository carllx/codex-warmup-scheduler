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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Detect whether running in deployed runtime (flat directory) or source repo
if (Test-Path (Join-Path $ScriptDir "decision_engine.py")) {
    # Deployed runtime layout: all runtime scripts in same folder
    $RuntimeDir = $ScriptDir
    $EngineDir  = $ScriptDir
    $BaseDir    = Split-Path -Parent $ScriptDir
} else {
    # Source repo layout: src/scheduler -> src/runtime, src/engine
    $RuntimeDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\runtime"))
    $EngineDir  = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\engine"))
    $BaseDir    = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir "..\.."))
}

$LogsDir = Join-Path $BaseDir "logs"
$StateDir = Join-Path $BaseDir "state"
$ConfigDir = Join-Path $BaseDir "config"

foreach ($d in @($LogsDir, $StateDir, $ConfigDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$TodayStr = (Get-Date).ToString("yyyy-MM-dd")
$LogFile = Join-Path $LogsDir "warmup-$TodayStr.log"
$StateFile = Join-Path $StateDir "runtime_state.json"

function Log-Message([string]$msg, [string]$level = "INFO") {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $entry = "[$ts][$level] $msg"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry -Encoding utf8
}

Log-Message "=== Codex Warmup V2 Controller Started ==="
Log-Message "Mode: ShadowMode=$($ShadowMode.IsPresent), DryRun=$($DryRun.IsPresent)"

# 1. Resolve Codex Executable
. (Join-Path $RuntimeDir "Resolve-CodexRuntime.ps1")
$runtime = Resolve-CodexExecutable
if (-not $runtime.validated) {
    Log-Message "Failed to resolve valid Codex CLI: $($runtime.source)" "ERROR"
    exit 1
}
Log-Message "Codex Runtime resolved: $($runtime.path) (version: $($runtime.version), source: $($runtime.source))"

# 2. Query App Server for Rate Limits
$rateLimitJson = $null
try {
    $rateLimitRaw = & (Join-Path $RuntimeDir "Get-CodexRateLimits.ps1")
    if ($rateLimitRaw -match "(?ms)RATE_LIMIT_JSON_START\s*(.*?)\s*RATE_LIMIT_JSON_END") {
        $rateLimitJson = $matches[1] | ConvertFrom-Json
    } else {
        $rateLimitJson = $rateLimitRaw | ConvertFrom-Json
    }
} catch {
    Log-Message "Error querying app-server rate limits: $_" "WARN"
}

$activeUntil = $null
$weeklyExhausted = $false

if ($rateLimitJson -and $rateLimitJson.result -and $rateLimitJson.result.rateLimits) {
    $rl = $rateLimitJson.result.rateLimits
    Log-Message "Rate limits received: limitReached=$($rl.limitReached), resetsAt=$($rl.resetsAt)"
    if ($rl.limitReached) {
        $weeklyExhausted = $true
    }
    if ($rl.resetsAt) {
        $resetEpoch = [long]$rl.resetsAt
        $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch)
        $resetLocal = $resetUtc.ToLocalTime()
        Log-Message "Active window / next reset local time: $($resetLocal.ToString('o'))"
        if ($resetLocal -gt (Get-Date)) {
            $activeUntil = $resetLocal.ToString("yyyy-MM-ddTHH:mm:sszzz")
        }
    }
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
    "--config", "`"$ConfigPath`""
)

if ($activeUntil) {
    $engineArgs += @("--active-until", "`"$activeUntil`"")
}
if ($weeklyExhausted) {
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
Log-Message "Decision Engine Result: Action=$($decision.decision), ScheduledTime=$($decision.scheduledTime), ExpectedBoundary=$($decision.expectedBoundary), Reason=$($decision.reason)"

# Save runtime state
$currentState = [PSCustomObject]@{
    timestamp  = $nowIso
    runtime    = $runtime
    decision   = $decision
    shadowMode = $ShadowMode.IsPresent
}
$currentState | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFile -Encoding utf8

# 4. Action Execution
if ($ShadowMode) {
    Log-Message "[ShadowMode] No warmup or schedule mutation performed. Audit complete."
    exit 0
}

switch ($decision.decision) {
    "WARMUP_NOW" {
        Log-Message "Executing immediate warmup..."
        . (Join-Path $RuntimeDir "Execute-CodexWarmup.ps1")
        $res = Execute-CodexWarmup -CodexExe $runtime.path
        Log-Message "Warmup completed. ExitCode=$($res.ExitCode), Output=$($res.Stdout)"
    }
    "SCHEDULE_WARMUP" {
        Log-Message "Scheduling next wakeup at: $($decision.scheduledTime)"
        # Scheduler trigger update logic
    }
    "NO_ACTION" {
        Log-Message "No action required: $($decision.reason)"
    }
}

Log-Message "=== Codex Warmup V2 Controller Finished ==="
