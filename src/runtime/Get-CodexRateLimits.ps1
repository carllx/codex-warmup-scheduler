# Get-CodexRateLimits.ps1
# Queries Codex app-server via JSON-RPC stdio to fetch real-time rate limits
# Bounded execution: deadline-bounded RPC reads, async stderr drain, and process-tree termination on exit/timeout

[CmdletBinding()]
param(
    [int]$RpcTimeoutSeconds = 8
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }

. (Join-Path $scriptDir "Resolve-CodexRuntime.ps1")
$runtime = Resolve-CodexExecutable

if (-not $runtime.validated) {
    throw "Cannot read rate limits: Codex executable could not be resolved."
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
$pidToManage = $proc.Id

# Drain stderr concurrently in background to prevent pipe deadlock
$errTask = $proc.StandardError.ReadToEndAsync()

$writer = $proc.StandardInput
$reader = $proc.StandardOutput

function Read-RpcLineWithDeadline($reader, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $readTask = $null
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($null -eq $readTask) {
            $readTask = $reader.ReadLineAsync()
        }
        $remaining = [Math]::Max(1, $timeoutMs - [int]$sw.ElapsedMilliseconds)
        $finished = $readTask.Wait($remaining)
        if ($finished) {
            return $readTask.Result
        } else {
            return $null
        }
    }
    return $null
}

function Read-RpcResponseBounded($reader, $expectedId, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $remaining = [Math]::Max(1, $timeoutMs - [int]$sw.ElapsedMilliseconds)
        $line = Read-RpcLineWithDeadline $reader $remaining
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $json = $line | ConvertFrom-Json
            if ($json.id -eq $expectedId) {
                return $line
            }
        } catch {}
    }
    return $null
}

$rateResp = $null
try {
    $timeoutPerCallMs = [int]($RpcTimeoutSeconds * 1000)

    # 1. initialize
    $writer.WriteLine((@{ jsonrpc="2.0"; id=1; method="initialize"; params=@{ clientInfo=@{ name="warmup-scheduler"; version="2.0" } } } | ConvertTo-Json -Compress))
    $writer.Flush()
    $initResp = Read-RpcResponseBounded $reader 1 $timeoutPerCallMs

    if ($initResp) {
        # 2. initialized
        $writer.WriteLine((@{ jsonrpc="2.0"; method="initialized"; params=@{} } | ConvertTo-Json -Compress))
        $writer.Flush()

        # 3. account/rateLimits/read
        $writer.WriteLine((@{ jsonrpc="2.0"; id=2; method="account/rateLimits/read"; params=$null } | ConvertTo-Json -Compress))
        $writer.Flush()
        $rateResp = Read-RpcResponseBounded $reader 2 $timeoutPerCallMs
    }
} finally {
    try {
        $proc.StandardInput.Close()
    } catch {}

    # Bounded wait for process exit, kill process tree on timeout
    $naturalExit = $proc.WaitForExit(2000)
    if (-not $naturalExit) {
        try {
            $taskkillPath = "$env:SystemRoot\System32\taskkill.exe"
            if (Test-Path $taskkillPath) {
                & $taskkillPath /PID $pidToManage /T /F | Out-Null
            } else {
                $proc.Kill()
            }
        } catch {}
        $proc.WaitForExit(1000) | Out-Null
    }
}

Write-Output "RATE_LIMIT_JSON_START"
Write-Output $rateResp
Write-Output "RATE_LIMIT_JSON_END"