. "$env:LOCALAPPDATA\CodexWarmupV2\Resolve-CodexExecutable.ps1"
$runtime = Resolve-CodexExecutable
if (-not $runtime.validated) {
    Write-Error "Runtime unavailable"
    exit 1
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

# Helper to send JSON-RPC
function Send-RpcRequest($streamWriter, $obj) {
    $json = $obj | ConvertTo-Json -Compress
    $streamWriter.WriteLine($json)
    $streamWriter.Flush()
}

$writer = $proc.StandardInput
$reader = $proc.StandardOutput

# 1. Send initialize
$initReq = @{
    jsonrpc = "2.0"
    id = 1
    method = "initialize"
    params = @{
        clientInfo = @{
            name = "codex-warmup-v2"
            version = "2.0.0"
        }
    }
}
Send-RpcRequest $writer $initReq

# Read response
$initResp = $reader.ReadLine()
Write-Host "Init Response:" $initResp

# 2. Send initialized notification if needed
$initNotif = @{
    jsonrpc = "2.0"
    method = "initialized"
    params = @{}
}
Send-RpcRequest $writer $initNotif

# 3. Send account/rateLimits/read
$rateReq = @{
    jsonrpc = "2.0"
    id = 2
    method = "account/rateLimits/read"
    params = $null
}
Send-RpcRequest $writer $rateReq

# Read response
$rateResp = $reader.ReadLine()
Write-Host "Rate Limits Response:" $rateResp

# Terminate process cleanly
$proc.StandardInput.Close()
$proc.WaitForExit(3000) | Out-Null
if (-not $proc.HasExited) {
    $proc.Kill()
}
