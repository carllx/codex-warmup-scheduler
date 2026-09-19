# test_process_runner_stdin.ps1
# Regression test for ProcessRunner stdin EOF delivery contract.
# Proves that when a child process is executed by Invoke-BoundedProcess:
#   1. Standard input is redirected (non-interactive).
#   2. EOF is immediately delivered on stdin upon process start.
#   3. A child awaiting stdin EOF exits promptly without timing out.
# ZERO network calls; ZERO Codex quota consumed; uses a harmless local mock script.

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
Write-Host "TEST PROCESS RUNNER STDIN EOF CONTRACT"
Write-Host "=================================================="

Import-Module (Join-Path $RepoRoot "src\runtime\ProcessRunner.psm1") -Force

$mockStdinPy = Join-Path $env:TEMP "mock_pr_stdin_wait.py"

# Child process that reads stdin to EOF and verifies redirection
$pyContent = @"
import sys

# Read stdin until EOF
data = sys.stdin.read()
if data == "":
    print("EOF_RECEIVED")
    if not sys.stdin.isatty():
        print("STDIN_IS_REDIRECTED")
    sys.exit(0)
else:
    print("UNEXPECTED_DATA", file=sys.stderr)
    sys.exit(1)
"@

$pyContent | Set-Content -Path $mockStdinPy -Encoding ascii

try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-BoundedProcess -FilePath "python" -Arguments "`"$mockStdinPy`"" -TimeoutSeconds 3
    $sw.Stop()

    Assert-Check ($res.Success -eq $true) "Stdin EOF test: Success is true" "Got: $($res.Success)"
    Assert-Check ($res.TimedOut -eq $false) "Stdin EOF test: TimedOut is false" "Got: $($res.TimedOut)"
    Assert-Check ($res.ExitCode -eq 0) "Stdin EOF test: ExitCode is 0" "Got: $($res.ExitCode)"
    Assert-Check ($res.Stdout -match "EOF_RECEIVED") "Stdin EOF test: Stdout contains EOF_RECEIVED marker" "Stdout was: $($res.Stdout)"
    Assert-Check ($res.Stdout -match "STDIN_IS_REDIRECTED") "Stdin EOF test: Child observes redirected input" "Stdout was: $($res.Stdout)"
    Assert-Check ($sw.ElapsedMilliseconds -lt 2500) "Stdin EOF test: Process exited promptly without blocking" "ElapsedMs: $($sw.ElapsedMilliseconds)"

} finally {
    if (Test-Path $mockStdinPy) {
        Remove-Item -Path $mockStdinPy -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nPassed: $passCount, Failed: $failCount"
if ($failCount -gt 0) {
    exit 1
}
exit 0
