# repro_controller_mutex.ps1
# Minimal isolated harness for named mutex Global\CodexWarmupV2Controller

$ErrorActionPreference = "Stop"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$mutexName = "Global\CodexWarmupV2Controller"
$mutexCreated = $false

Write-Host "=== TEST 1: Process A acquiring mutex ==="
$mutexA = New-Object System.Threading.Mutex($false, $mutexName, [ref]$mutexCreated)
$hasLockA = $mutexA.WaitOne(0, $false)
Write-Host "Process A acquired lock: $hasLockA"

if (-not $hasLockA) {
    throw "Process A failed to acquire initial lock"
}

try {
    Write-Host "=== TEST 2: Process B attempting acquisition while A holds lock ==="
    $childCmd = @"
`$mName = '$mutexName'
`$m = New-Object System.Threading.Mutex(`$false, `$mName)
`$hasLock = `$m.WaitOne(0, `$false)
if (-not `$hasLock) {
    Write-Host 'MUTEX_BUSY'
    exit 0
} else {
    Write-Host 'MUTEX_ACQUIRED_UNEXPECTEDLY'
    `$m.ReleaseMutex()
    exit 1
}
"@
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -Command `"$childCmd`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $procB = [System.Diagnostics.Process]::Start($psi)
    $bOut = $procB.StandardOutput.ReadToEnd()
    $bErr = $procB.StandardError.ReadToEnd()
    $procB.WaitForExit(3000)

    Write-Host "Process B output: $($bOut.Trim())"
    Write-Host "Process B exit code: $($procB.ExitCode)"

    if ($bOut.Trim() -ne "MUTEX_BUSY" -or $procB.ExitCode -ne 0) {
        throw "Process B did not return MUTEX_BUSY or exited with non-zero"
    }

} finally {
    Write-Host "=== TEST 3: Process A releasing mutex ==="
    $mutexA.ReleaseMutex()
    $mutexA.Dispose()
    Write-Host "Process A released lock"
}

Write-Host "=== TEST 4: Process C acquiring mutex after release ==="
$mutexC = New-Object System.Threading.Mutex($false, $mutexName, [ref]$mutexCreated)
$hasLockC = $mutexC.WaitOne(0, $false)
Write-Host "Process C acquired lock: $hasLockC"

if (-not $hasLockC) {
    throw "Process C failed to acquire lock after release"
}
$mutexC.ReleaseMutex()
$mutexC.Dispose()

Write-Host "OUTCOME: GREEN - MUTEX CONCURRENCY PRIMITIVE VERIFIED in $($sw.ElapsedMilliseconds)ms"
