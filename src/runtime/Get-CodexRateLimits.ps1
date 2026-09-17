# Get-CodexRateLimits.ps1
# Queries Codex app-server via JSON-RPC stdio to fetch real-time rate limits

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

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
$writer = $proc.StandardInput
$reader = $proc.StandardOutput

function Read-RpcResponse($reader, $expectedId) {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
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

# 1. initialize
$writer.WriteLine((@{ jsonrpc="2.0"; id=1; method="initialize"; params=@{ clientInfo=@{ name="warmup-scheduler"; version="2.0" } } } | ConvertTo-Json -Compress))
$writer.Flush()
$initResp = Read-RpcResponse $reader 1

# 2. initialized
$writer.WriteLine((@{ jsonrpc="2.0"; method="initialized"; params=@{} } | ConvertTo-Json -Compress))
$writer.Flush()

# 3. account/rateLimits/read
$writer.WriteLine((@{ jsonrpc="2.0"; id=2; method="account/rateLimits/read"; params=$null } | ConvertTo-Json -Compress))
$writer.Flush()
$rateResp = Read-RpcResponse $reader 2

$proc.StandardInput.Close()
$proc.WaitForExit(3000) | Out-Null
if (-not $proc.HasExited) { $proc.Kill() }

Write-Output "RATE_LIMIT_JSON_START"
Write-Output $rateResp
Write-Output "RATE_LIMIT_JSON_END"
