# test_steps.ps1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "T=0: Starting"

# 1. Resolve Codex
. ".\src\runtime\Resolve-CodexRuntime.ps1"
$runtime = Resolve-CodexExecutable
Write-Host "T=$($sw.ElapsedMilliseconds)ms: Runtime resolved"

# 2. Get Rate Limits
$rateLimitRaw = & ".\src\runtime\Get-CodexRateLimits.ps1"
Write-Host "T=$($sw.ElapsedMilliseconds)ms: Rate limits probed, raw count: $($rateLimitRaw.Count)"

$rawStr = if ($rateLimitRaw -is [System.Array]) { $rateLimitRaw -join "`n" } else { [string]$rateLimitRaw }
$rateLimitJson = $null
if ($rawStr -match "(?ms)RATE_LIMIT_JSON_START\s*(.*?)\s*RATE_LIMIT_JSON_END") {
    $rateLimitJson = $matches[1].Trim() | ConvertFrom-Json
}
Write-Host "T=$($sw.ElapsedMilliseconds)ms: JSON parsed: $($null -ne $rateLimitJson)"

# 3. Classify
. ".\src\runtime\Classify-RateLimitWindow.ps1"
$cls = Classify-RateLimitWindow -RateLimitResponse $rateLimitJson -CurrentTime ([DateTimeOffset]::Now)
Write-Host "T=$($sw.ElapsedMilliseconds)ms: Classified: Status=$($cls.FiveHourWindowStatus), CanEvaluate=$($cls.CanEvaluateWarmup)"

# 4. Run Decision Engine
$engineScript = [System.IO.Path]::GetFullPath("src\engine\decision_engine.py")
$configPath = [System.IO.Path]::GetFullPath("config\default.json")
$nowIso = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")

$engineArgs = @(
    "`"$engineScript`"",
    "--now", "`"$nowIso`"",
    "--config", "`"$configPath`"",
    "--window-status", "`"$($cls.FiveHourWindowStatus)`""
)
if ($cls.ResetAt) { $engineArgs += @("--active-until", "`"$($cls.ResetAt)`"") }

Write-Host "T=$($sw.ElapsedMilliseconds)ms: Invoking python..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "python"
$psi.Arguments = $engineArgs -join " "
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$out = $proc.StandardOutput.ReadToEnd()
$err = $proc.StandardError.ReadToEnd()
$proc.WaitForExit(5000)
Write-Host "T=$($sw.ElapsedMilliseconds)ms: Python complete: ExitCode=$($proc.ExitCode)"
Write-Host "Python output: $out"
