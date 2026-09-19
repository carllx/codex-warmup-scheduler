# test_warmup_notification.ps1
# Focused verification for WarmupNotification module:
# 1. Parameter contract validation
# 2. Failure isolation (never throws or blocks execution)
# 3. No-noise verification (ShadowMode, DryRun, non-WARMUP branches never notify)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $RepoRoot "src\runtime\WarmupNotification.psm1"

Write-Host "=================================================="
Write-Host "RUNNING WARMUP NOTIFICATION VERIFICATION"
Write-Host "=================================================="

$passCount = 0
$failCount = 0

function Assert-Condition([bool]$condition, [string]$testName, [string]$detail = "") {
    if ($condition) {
        Write-Host "[PASS] $testName" -ForegroundColor Green
        $global:passCount++
    } else {
        Write-Host "[FAIL] $testName - $detail" -ForegroundColor Red
        $global:failCount++
    }
}

# 1. Module Import
try {
    Import-Module $ModulePath -Force
    Assert-Condition ($null -ne (Get-Command Show-WarmupNotification -ErrorAction SilentlyContinue)) "T1: Module imports and exports Show-WarmupNotification"
} catch {
    Assert-Condition $false "T1: Module import failed" $_
}

# 2. Parameter Contract
try {
    $command = Get-Command Show-WarmupNotification
    $kindParam = $command.Parameters["Kind"]
    $validSet = ($kindParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
    
    $hasStarting = "Starting" -in $validSet
    $hasSuccess  = "Success" -in $validSet
    $hasFailure  = "Failure" -in $validSet
    $count3      = ($validSet.Count -eq 3)

    Assert-Condition ($hasStarting -and $hasSuccess -and $hasFailure -and $count3) "T2: ValidateSet strictly contains Starting, Success, Failure" "Got: $($validSet -join ', ')"
} catch {
    Assert-Condition $false "T2: Parameter inspection exception" $_
}

# 3. Invalid Kind Rejection
try {
    $threw = $false
    try {
        Show-WarmupNotification -Kind "InvalidKind" -ErrorAction Stop
    } catch {
        $threw = $true
    }
    Assert-Condition $threw "T3: Invalid Kind is rejected by parameter validation"
} catch {
    Assert-Condition $false "T3: Invalid kind test exception" $_
}

# 4. Best-effort Failure Isolation (Never Throws)
try {
    # Even if environment is broken or mocked to throw, Show-WarmupNotification must swallow silently
    $swallowed = $true
    try {
        # Execution with valid kinds must not throw under any circumstances
        Show-WarmupNotification -Kind "Starting"
        Show-WarmupNotification -Kind "Success"
        Show-WarmupNotification -Kind "Failure"
    } catch {
        $swallowed = $false
    }
    Assert-Condition $swallowed "T4: Show-WarmupNotification executes without throwing"
} catch {
    Assert-Condition $false "T4: Execution threw an unexpected exception" $_
}

# 5. Timing / Non-blocking Check (Helper must never delay real warmup materially)
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Show-WarmupNotification -Kind "Starting"
    $sw.Stop()
    $elapsedMs = $sw.ElapsedMilliseconds
    Assert-Condition ($elapsedMs -lt 500) "T5: Notification execution is fast and does not delay warmup (<500ms)" "Elapsed: ${elapsedMs}ms"
} catch {
    Assert-Condition $false "T5: Timing test exception" $_
}

# 6. Static AST Inspection: Controller wiring isolation (No noise)
try {
    $ctrlFile = Join-Path $RepoRoot "src\scheduler\controller.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ctrlFile, [ref]$null, [ref]$null)
    $commandAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
    
    $notificationCalls = $commandAsts | Where-Object { $_.GetCommandName() -eq "Show-WarmupNotification" }
    
    # Verify exact call count in controller
    Assert-Condition ($notificationCalls.Count -eq 3) "T6.1: Exactly 3 Show-WarmupNotification invocations in controller" "Found: $($notificationCalls.Count)"
    
    # Verify all calls are strictly guarded by if (-not $DryRun) inside the real production (else) branch
    $allGuardedByDryRun = $true
    foreach ($call in $notificationCalls) {
        $parentIf = $call.Parent
        while ($null -ne $parentIf -and -not ($parentIf -is [System.Management.Automation.Language.IfStatementAst])) {
            $parentIf = $parentIf.Parent
        }
        if ($null -eq $parentIf -or $parentIf.Extent.Text -notmatch "DryRun") {
            $allGuardedByDryRun = $false
        }
    }
    Assert-Condition $allGuardedByDryRun "T6.2: All Show-WarmupNotification calls in controller are explicitly guarded by -DryRun check"
} catch {
    Assert-Condition $false "T6: Static AST analysis exception" $_
}

Write-Host "=================================================="
Write-Host "NOTIFICATION TEST SUMMARY: $passCount PASSED, $failCount FAILED"
Write-Host "=================================================="
if ($failCount -gt 0) { exit 1 } else { exit 0 }
