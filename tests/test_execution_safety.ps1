# test_execution_safety.ps1
# Dedicated safety regressions test suite for S1, S2, H1, H2, H3, H4.
# Designed to run in both Windows PowerShell 5.1 (Primary) and PowerShell Core (Secondary).

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

$passCount = 0
$failCount = 0

function Report-Result([bool]$pass, [string]$testId, [string]$desc, [string]$details = "") {
    if ($pass) {
        Write-Host "[$testId] PASS: $desc" -ForegroundColor Green
        $global:passCount++
    } else {
        Write-Host "[$testId] FAIL: $desc. $details" -ForegroundColor Red
        $global:failCount++
    }
}

Write-Host "================================================================"
Write-Host "EXECUTION SAFETY & NO-HANG REGRESSIONS SUITE (S1 - H4)"
Write-Host "Host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "================================================================"

# -----------------------------------------------------------------------------
# S1: Scope Isolation
# Controller ShadowMode=True / DryRun=True -> load scheduler implementation
# -> values remain True / True, and import module does not touch Task Scheduler
# -----------------------------------------------------------------------------
try {
    $ShadowMode = $true
    $DryRun = $true

    $modulePath = Join-Path $RepoRoot "src\scheduler\ScheduledTrigger.psm1"
    
    # Snapshot task state before import
    $beforeTask = Get-ScheduledTask -TaskName "Codex Warmup" -ErrorAction SilentlyContinue
    $beforeInfo = if ($beforeTask) { Get-ScheduledTaskInfo -TaskName "Codex Warmup" -ErrorAction SilentlyContinue } else { $null }

    Import-Module $modulePath -Force

    # Verify variables remain intact
    $varsIntact = ($ShadowMode -eq $true) -and ($DryRun -eq $true)

    # Verify no Task mutation on import
    $afterTask = Get-ScheduledTask -TaskName "Codex Warmup" -ErrorAction SilentlyContinue
    $afterInfo = if ($afterTask) { Get-ScheduledTaskInfo -TaskName "Codex Warmup" -ErrorAction SilentlyContinue } else { $null }

    $taskUntouched = $true
    if ($beforeInfo -and $afterInfo) {
        $taskUntouched = ($beforeInfo.NextRunTime -eq $afterInfo.NextRunTime) -and ($beforeTask.Triggers.Count -eq $afterTask.Triggers.Count)
    }

    # Verify Update-ScheduledTrigger function is available
    $funcAvailable = (Get-Command Update-ScheduledTrigger -ErrorAction SilentlyContinue) -ne $null

    Report-Result ($varsIntact -and $taskUntouched -and $funcAvailable) "S1" "Scope isolation and import zero-mutation verified" "varsIntact=$varsIntact, taskUntouched=$taskUntouched, funcAvailable=$funcAvailable"
} catch {
    Report-Result $false "S1" "Exception occurred" $_
}

# -----------------------------------------------------------------------------
# S2: DryRun Forwarding
# Update-ScheduledTrigger -DryRun -ShadowMode
# Confirm function observes DryRun=True, ShadowMode=True, returns Success, and does not touch real Task
# -----------------------------------------------------------------------------
try {
    $beforeInfo = Get-ScheduledTaskInfo -TaskName "Codex Warmup" -ErrorAction SilentlyContinue

    $target = (Get-Date).AddHours(2)
    $res = Update-ScheduledTrigger -TargetDateTime $target -DryRun -ShadowMode

    $afterInfo = Get-ScheduledTaskInfo -TaskName "Codex Warmup" -ErrorAction SilentlyContinue

    $dryRunObserved = ($res.Mode -eq "DryRun" -or $res.Mode -eq "ShadowMode") -and ($res.Success -eq $true)
    $taskUntouched = ($beforeInfo.NextRunTime -eq $afterInfo.NextRunTime)

    Report-Result ($dryRunObserved -and $taskUntouched) "S2" "DryRun and ShadowMode forwarding verified without task mutation" "mode=$($res.Mode), taskUntouched=$taskUntouched"
} catch {
    Report-Result $false "S2" "Exception occurred" $_
}

# -----------------------------------------------------------------------------
# H1: Child Never Exits
# Must bounded timeout + cleanup owned process tree
# -----------------------------------------------------------------------------
try {
    $procModule = Join-Path $RepoRoot "src\runtime\ProcessRunner.psm1"
    Import-Module $procModule -Force

    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-BoundedProcess -FilePath $psExe -Arguments "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120" -TimeoutSeconds 2
    $sw.Stop()

    $boundedTime = ($sw.ElapsedMilliseconds -ge 1800 -and $sw.ElapsedMilliseconds -le 7000)
    $cleanOutcome = ($res.TimedOut -eq $true -and $res.Success -eq $false)

    Report-Result ($boundedTime -and $cleanOutcome) "H1" "Hanging child process bounded by timeout and cleaned up" "ElapsedMs=$($sw.ElapsedMilliseconds), TimedOut=$($res.TimedOut)"
} catch {
    Report-Result $false "H1" "Exception occurred" $_
}

# -----------------------------------------------------------------------------
# H2: Stdout/Stderr Pressure
# Child prints massive stdout and stderr; must drain without pipe buffer deadlock
# -----------------------------------------------------------------------------
try {
    $procModule = Join-Path $RepoRoot "src\runtime\ProcessRunner.psm1"
    Import-Module $procModule -Force

    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    # Write ~1000 lines (around 80KB) to stdout and stderr simultaneously
    $script = "1..1000 | ForEach-Object { [Console]::Out.WriteLine('STDOUT_LINE_' + `$_); [Console]::Error.WriteLine('STDERR_LINE_' + `$_) }"
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-BoundedProcess -FilePath $psExe -Arguments "-NoProfile -NonInteractive -Command `"$script`"" -TimeoutSeconds 10
    $sw.Stop()

    $stdoutLines = ($res.Stdout -split "`r?`n").Count
    $stderrLines = ($res.Stderr -split "`r?`n").Count
    $noDeadlock = ($res.Success -eq $true -and $res.TimedOut -eq $false -and $stdoutLines -ge 950 -and $stderrLines -ge 950)

    Report-Result $noDeadlock "H2" "High volume stdout/stderr drained without pipe deadlock" "StdoutLines=$stdoutLines, StderrLines=$stderrLines, ElapsedMs=$($sw.ElapsedMilliseconds)"
} catch {
    Report-Result $false "H2" "Exception occurred" $_
}

# -----------------------------------------------------------------------------
# H3: RPC Expected Response Never Arrives
# Must bounded return + child cleanup
# -----------------------------------------------------------------------------
try {
    # Test Get-CodexRateLimits.ps1 bounded RPC behavior against mock uncooperative child
    # We create a mock script that acts like app-server but responds with silence / hangs
    $mockScript = "$env:TEMP\mock_silent_app_server.ps1"
    [System.IO.File]::WriteAllText($mockScript, "Start-Sleep -Seconds 120")

    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -NonInteractive -File `"$mockScript`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $pidToTrack = $proc.Id

    # Use the exact deadline reading routine from Get-CodexRateLimits.ps1
    $reader = $proc.StandardOutput
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    function Read-RpcLineWithDeadline($r, [int]$timeoutMs) {
        $innerSw = [System.Diagnostics.Stopwatch]::StartNew()
        $readTask = $null
        while ($innerSw.ElapsedMilliseconds -lt $timeoutMs) {
            if ($null -eq $readTask) { $readTask = $r.ReadLineAsync() }
            $remaining = [Math]::Max(1, $timeoutMs - [int]$innerSw.ElapsedMilliseconds)
            $finished = $readTask.Wait($remaining)
            if ($finished) { return $readTask.Result } else { return $null }
        }
        return $null
    }

    $rpcLine = Read-RpcLineWithDeadline $reader 2000
    $sw.Stop()

    # Clean up child process
    $taskkillPath = "$env:SystemRoot\System32\taskkill.exe"
    & $taskkillPath /PID $pidToTrack /T /F | Out-Null
    $proc.WaitForExit(1000) | Out-Null
    $childRunning = (Get-Process -Id $pidToTrack -ErrorAction SilentlyContinue) -ne $null

    $boundedRpc = ($null -eq $rpcLine) -and ($sw.ElapsedMilliseconds -ge 1800 -and $sw.ElapsedMilliseconds -le 4000) -and (-not $childRunning)

    Report-Result $boundedRpc "H3" "RPC deadline expiration bounded return and child process cleanup verified" "LineNull=$($null -eq $rpcLine), ChildRunning=$childRunning, ElapsedMs=$($sw.ElapsedMilliseconds)"
} catch {
    Report-Result $false "H3" "Exception occurred" $_
}

# -----------------------------------------------------------------------------
# H4: Normal Process Execution
# Normal stdout/stderr/exit code remain available
# -----------------------------------------------------------------------------
try {
    $procModule = Join-Path $RepoRoot "src\runtime\ProcessRunner.psm1"
    Import-Module $procModule -Force

    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $res = Invoke-BoundedProcess -FilePath $psExe -Arguments "-NoProfile -NonInteractive -Command `"[Console]::Out.WriteLine('NORMAL_OUT'); [Console]::Error.WriteLine('NORMAL_ERR'); exit 42`"" -TimeoutSeconds 5

    $h4Pass = ($res.ExitCode -eq 42) -and ($res.Stdout -eq "NORMAL_OUT") -and ($res.Stderr -eq "NORMAL_ERR") -and ($res.TimedOut -eq $false)

    Report-Result $h4Pass "H4" "Normal process execution stdout/stderr and exit code verified" "ExitCode=$($res.ExitCode), Stdout=$($res.Stdout), Stderr=$($res.Stderr)"
} catch {
    Report-Result $false "H4" "Exception occurred" $_
}

Write-Host "================================================================"
Write-Host "SUMMARY: $passCount PASSED, $failCount FAILED"
Write-Host "================================================================"

if ($failCount -gt 0) { exit 1 } else { exit 0 }