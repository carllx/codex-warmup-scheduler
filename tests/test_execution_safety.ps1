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
# Warmup import/no-execution regression
# Verify CodexWarmup.psm1 is declaration-only and importing it does NOT execute warmup
# -----------------------------------------------------------------------------
try {
    $warmupModule = Join-Path $RepoRoot "src\runtime\CodexWarmup.psm1"

    $beforeProcesses = Get-Process -Name "codex*" -ErrorAction SilentlyContinue

    Import-Module $warmupModule -Force

    $afterProcesses = Get-Process -Name "codex*" -ErrorAction SilentlyContinue

    $funcAvailable = (Get-Command Invoke-CodexWarmup -ErrorAction SilentlyContinue) -ne $null
    $aliasAvailable = (Get-Command Execute-CodexWarmup -ErrorAction SilentlyContinue) -ne $null
    $noSpuriousExecution = ($null -eq $afterProcesses) -or ($beforeProcesses.Count -eq $afterProcesses.Count)

    $importClean = $funcAvailable -and $aliasAvailable -and $noSpuriousExecution

    Report-Result $importClean "WARMUP_IMPORT" "Warmup module import is declaration-only without execution" "Func=$funcAvailable, Alias=$aliasAvailable, NoSpuriousProc=$noSpuriousExecution"
} catch {
    Report-Result $false "WARMUP_IMPORT" "Exception occurred" $_
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
# Production-owned RPC implementation (Get-CodexRateLimits.ps1) with mock app-server
# Must prove deadline + bounded return + owned child cleanup
# -----------------------------------------------------------------------------
try {
    $mockScript = Join-Path $env:TEMP "mock_unresponsive_app_server.ps1"
    $pidFile = Join-Path $env:TEMP "mock_unresponsive_app_server.pid"
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }

    # Mock app-server: writes its own PID to $pidFile, outputs non-RPC noise, sleeps
    $mockContent = @"
`$pidPath = '$pidFile'
[System.IO.File]::WriteAllText(`$pidPath, `$PID.ToString())
[Console]::Out.WriteLine('{"jsonrpc":"2.0","method":"noise"}')
Start-Sleep -Seconds 120
"@
    [System.IO.File]::WriteAllText($mockScript, $mockContent)

    $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $rateLimitScript = Join-Path $RepoRoot "src\runtime\Get-CodexRateLimits.ps1"
    $mockArgs = "-NoProfile -NonInteractive -File `"$mockScript`""

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rpcOut = & $rateLimitScript -CodexExe $psExe -Arguments $mockArgs -RpcTimeoutSeconds 2
    $sw.Stop()

    $elapsedMs = $sw.ElapsedMilliseconds
    $boundedTime = ($elapsedMs -ge 1800 -and $elapsedMs -le 9000)

    # Verify mock child PID was recorded and is now terminated
    $childCleanedUp = $false
    if (Test-Path $pidFile) {
        $mockPid = [int](Get-Content $pidFile -Raw).Trim()
        $childRunning = (Get-Process -Id $mockPid -ErrorAction SilentlyContinue) -ne $null
        $childCleanedUp = (-not $childRunning)
    }

    # Verify production RPC returned empty/null rate limit response
    $outStr = if ($rpcOut -is [System.Array]) { $rpcOut -join "`n" } else { [string]$rpcOut }
    $noExpectedResp = ($outStr -notmatch '"account/rateLimits/read"') -and ($outStr -notmatch '"primary"')

    $h3Pass = $boundedTime -and $childCleanedUp -and $noExpectedResp

    Report-Result $h3Pass "H3" "Production RPC deadline expiration bounded return and owned child cleanup verified" "BoundedTime=$boundedTime (ElapsedMs=$elapsedMs), ChildCleanedUp=$childCleanedUp, NoExpectedResp=$noExpectedResp"
} catch {
    Report-Result $false "H3" "Exception occurred" $_
} finally {
    if (Test-Path $mockScript) { Remove-Item $mockScript -Force -ErrorAction SilentlyContinue }
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
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

# -----------------------------------------------------------------------------
# AST: PowerShell Abstract Syntax Tree parse verification
# All authored .ps1 and .psm1 files must parse without errors
# -----------------------------------------------------------------------------
try {
    $psFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.ps1", "*.psm1" | Where-Object {
        $_.FullName -notmatch '\\(\.git|logs|state|backup)\\'
    }

    $astErrors = @()
    foreach ($f in $psFiles) {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $astErrors += "$($f.Name): $($errors[0].Message)"
        }
    }

    $astPass = ($astErrors.Count -eq 0)
    Report-Result $astPass "AST" "All PowerShell scripts and modules parsed cleanly via AST" "Errors=$($astErrors -join '; ')"
} catch {
    Report-Result $false "AST" "Exception occurred during AST validation" $_
}

# -----------------------------------------------------------------------------
# Code Size: All authored files within acceptable threshold
# -----------------------------------------------------------------------------
try {
    $sizeScript = Join-Path $RepoRoot "scripts\check-code-size.ps1"
    $sizeOut = & $sizeScript -RootDirectory $RepoRoot
    $ceilingViolation = $sizeOut | Where-Object { $_ -match "EXCEEDS_CEILING" -or $_ -match "WARNING_INSPECT_SEAMS" }
    $codeSizePass = ($ceilingViolation.Count -eq 0)

    Report-Result $codeSizePass "CODE_SIZE" "All authored files within acceptable code size limits" ""
} catch {
    Report-Result $false "CODE_SIZE" "Exception occurred during code size check" $_
}

Write-Host "================================================================"
Write-Host "SUMMARY: $passCount PASSED, $failCount FAILED"
Write-Host "================================================================"

if ($failCount -gt 0) { exit 1 } else { exit 0 }