# test_scheduled_trigger.ps1
# Focused tests for Update-ScheduledTrigger on disposable task under non-elevated context

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$ModulePath = Join-Path $RepoRoot "src\scheduler\ScheduledTrigger.psm1"

Import-Module $ModulePath -Force

$testTaskName = "CodexWarmupTest_" + [guid]::NewGuid().ToString('N').Substring(0, 8)
$disposableCreated = $false

try {
    # 1. Register disposable task
    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c exit 0"
    $initialTrigger = New-ScheduledTaskTrigger -Daily -At "01:00"
    Register-ScheduledTask -TaskName $testTaskName -Action $action -Trigger $initialTrigger | Out-Null
    $disposableCreated = $true
    Write-Host "[TEST 1] Disposable task registered: $testTaskName"

    # 2. Call Update-ScheduledTrigger in DryRun/ShadowMode
    $targetTime = (Get-Date).AddHours(2)
    $dryRes = Update-ScheduledTrigger -TaskName $testTaskName -TargetDateTime $targetTime -DryRun
    if (-not $dryRes.Success -or $dryRes.Mode -ne "DryRun") {
        throw "DryRun failed: $($dryRes | Out-String)"
    }
    Write-Host "[TEST 2] DryRun Update-ScheduledTrigger: PASS"

    # 3. Call Update-ScheduledTrigger in Production mode (live apply on disposable task)
    $prodTarget = (Get-Date).AddHours(3)
    $liveRes = Update-ScheduledTrigger -TaskName $testTaskName -TargetDateTime $prodTarget
    if (-not $liveRes.Success -or $liveRes.Mode -ne "Production") {
        throw "Live update failed: $($liveRes | Out-String)"
    }
    Write-Host "[TEST 3] Live non-elevated Update-ScheduledTrigger: PASS"

    # 4. Verify read-back on disposable task
    $updatedTask = Get-ScheduledTask -TaskName $testTaskName
    $updatedInfo = Get-ScheduledTaskInfo -TaskName $testTaskName

    if ($updatedTask.Triggers.Count -ne 1) {
        throw "Expected 1 trigger, found $($updatedTask.Triggers.Count)"
    }
    if (-not $updatedTask.Settings.WakeToRun) {
        throw "WakeToRun is not true"
    }
    if (-not $updatedTask.Settings.StartWhenAvailable) {
        throw "StartWhenAvailable is not true"
    }
    if ($updatedTask.Settings.MultipleInstances -ne "IgnoreNew") {
        throw "MultipleInstances is not IgnoreNew"
    }
    if (-not $updatedInfo.NextRunTime) {
        throw "NextRunTime is null"
    }
    Write-Host "[TEST 4] Read-back verification (TriggerCount=1, WakeToRun=True, StartWhenAvailable=True, NextRunTime=$($updatedInfo.NextRunTime)): PASS"

    # 5. Verify production task was completely untouched
    $prodTask = Get-ScheduledTask -TaskName "Codex Warmup"
    $prodInfo = Get-ScheduledTaskInfo -TaskName "Codex Warmup"
    if ($prodTask.Triggers.Count -ne 5) {
        throw "CRITICAL: Production task triggers were modified! Expected 5 daily triggers, got $($prodTask.Triggers.Count)"
    }
    if ($prodInfo.NextRunTime.TimeOfDay.Hours -ne 20) {
        throw "CRITICAL: Production task NextRunTime modified! Expected 20:00, got $($prodInfo.NextRunTime)"
    }
    Write-Host "[TEST 5] Production task untouched (5 static daily triggers, NextRun=20:00): PASS"

    Write-Host "`nALL FOCUSED TESTS PASSED."
} finally {
    if ($disposableCreated) {
        Unregister-ScheduledTask -TaskName $testTaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Cleaned up disposable task: $testTaskName"
    }
}
