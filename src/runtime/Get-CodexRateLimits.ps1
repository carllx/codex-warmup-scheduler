. "$env:LOCALAPPDATA\CodexWarmupV2\Resolve-CodexExecutable.ps1"
$runtime = Resolve-CodexExecutable

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
$writer.WriteLine((@{ jsonrpc="2.0"; id=1; method="initialize"; params=@{ clientInfo=@{ name="test"; version="1.0" } } } | ConvertTo-Json -Compress))
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
$proc.WaitForExit(2000) | Out-Null
if (-not $proc.HasExited) { $proc.Kill() }

Write-Host "RATE_LIMIT_JSON_START"
Write-Host $rateResp
Write-Host "RATE_LIMIT_JSON_END"
