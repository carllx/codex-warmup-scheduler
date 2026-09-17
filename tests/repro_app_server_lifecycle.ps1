# repro_app_server_lifecycle.ps1
# Minimal harness to test codex app-server --stdio lifecycle and shutdown

[CmdletBinding()]
param(
    [ValidateSet("LegacyCloseOnly", "DrainGracefulWait", "DrainGracefulWithKillFallback")]
    [string]$Mode = "LegacyCloseOnly",
    [int]$WaitSeconds = 2
)

$ErrorActionPreference = "Stop"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

. "$PSScriptRoot\..\src\runtime\Resolve-CodexRuntime.ps1"
$runtime = Resolve-CodexExecutable
if (-not $runtime.validated) {
    throw "Codex runtime unvalidated"
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $runtime.path
$psi.Arguments = "app-server --stdio"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$pidToTrack = $proc.Id
Write-Host "APP_SERVER_STARTED: PID=$pidToTrack Mode=$Mode"

$writer = $proc.StandardInput
$reader = $proc.StandardOutput

function Read-Rpc($reader, $expectedId) {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $json = $line | ConvertFrom-Json
            if ($json.id -eq $expectedId) { return $line }
        } catch {}
    }
    return $null
}

# 1. initialize
$writer.WriteLine((@{ jsonrpc="2.0"; id=1; method="initialize"; params=@{ clientInfo=@{ name="test"; version="1.0" } } } | ConvertTo-Json -Compress))
$writer.Flush()
$initResp = Read-Rpc $reader 1

# 2. initialized
$writer.WriteLine((@{ jsonrpc="2.0"; method="initialized"; params=@{} } | ConvertTo-Json -Compress))
$writer.Flush()

# 3. account/rateLimits/read
$writer.WriteLine((@{ jsonrpc="2.0"; id=2; method="account/rateLimits/read"; params=$null } | ConvertTo-Json -Compress))
$writer.Flush()
$rateResp = Read-Rpc $reader 2

$gotTarget = ($rateResp -and $rateResp -match '"ordinaryUsageAllowed"')
Write-Host "TARGET_RESPONSE_RECEIVED: $gotTarget"

if (-not $gotTarget) {
    throw "Did not receive target rate limit response"
}

# Now exercise the lifecycle shutdown policy under test
switch ($Mode) {
    "LegacyCloseOnly" {
        # Exactly mirrors the old Get-CodexRateLimits.ps1
        # Close StandardInput and call WaitForExit with timeout
        $proc.StandardInput.Close()
        $exited = $proc.WaitForExit($WaitSeconds * 1000)
        
        $procIsRunning = (Get-Process -Id $pidToTrack -ErrorAction SilentlyContinue) -ne $null
        Write-Host "LIFECYCLE_RESULT: NaturalExited=$exited, StillRunning=$procIsRunning, ElapsedMs=$($sw.ElapsedMilliseconds)"
        if (-not $exited -or $procIsRunning) {
            # Clean up residual process before failing harness
            Stop-Process -Id $pidToTrack -Force -ErrorAction SilentlyContinue
            Write-Host "OUTCOME: RED - GRACEFUL_EXIT_TIMEOUT (app-server did not naturally exit upon closing stdin within $WaitSeconds s)"
            exit 1
        } else {
            Write-Host "OUTCOME: GREEN - NATURAL_EXIT"
            exit 0
        }
    }
    "DrainGracefulWithKillFallback" {
        # Drain remaining streams asynchronously or discard
        $proc.StandardInput.Close()
        $exited = $proc.WaitForExit($WaitSeconds * 1000)
        if (-not $exited) {
            Write-Host "GRACEFUL_EXIT_TIMEOUT: falling back to kill"
            # Cross-platform / .NET termination
            try {
                # In .NET Core 3.0+ / .NET 5+, Kill(true) kills process tree
                $proc.Kill($true)
            } catch {
                # Fallback for Windows PowerShell 5.1 / .NET 4.x
                & taskkill.exe /PID $pidToTrack /T /F | Out-Null
            }
            $proc.WaitForExit(1000) | Out-Null
        }
        $procIsRunning = (Get-Process -Id $pidToTrack -ErrorAction SilentlyContinue) -ne $null
        Write-Host "LIFECYCLE_RESULT: NaturalExited=$exited, StillRunning=$procIsRunning, ElapsedMs=$($sw.ElapsedMilliseconds)"
        if ($procIsRunning) {
            Write-Host "OUTCOME: RED - PROCESS_STILL_RUNNING"
            exit 1
        } else {
            Write-Host "OUTCOME: GREEN - CLEAN_TERMINATION"
            exit 0
        }
    }
}
