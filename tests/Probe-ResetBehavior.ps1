. "$env:LOCALAPPDATA\CodexWarmupV2\Resolve-CodexExecutable.ps1"

function Read-RateLimitSnapshot {
    $runtime = Resolve-CodexExecutable
    if (-not $runtime.validated) { return $null }

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
                if ($json.id -eq $expectedId) { return $json }
            } catch {}
        }
        return $null
    }

    $writer.WriteLine((@{ jsonrpc="2.0"; id=1; method="initialize"; params=@{ clientInfo=@{ name="probe"; version="1.0" } } } | ConvertTo-Json -Compress))
    $writer.Flush()
    $null = Read-RpcResponse $reader 1

    $writer.WriteLine((@{ jsonrpc="2.0"; method="initialized"; params=@{} } | ConvertTo-Json -Compress))
    $writer.Flush()

    $writer.WriteLine((@{ jsonrpc="2.0"; id=2; method="account/rateLimits/read"; params=$null } | ConvertTo-Json -Compress))
    $writer.Flush()
    $rateJson = Read-RpcResponse $reader 2

    $proc.StandardInput.Close()
    $proc.WaitForExit(2000) | Out-Null
    if (-not $proc.HasExited) { $proc.Kill() }

    return $rateJson.result
}

Write-Host "Sample 1:"
$s1 = Read-RateLimitSnapshot
$t1 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$p1 = $s1.rateLimits.primary
Write-Host "T1 ($t1): resetsAt=$($p1.resetsAt), duration=$($p1.windowDurationMins), usedPercent=$($p1.usedPercent)"

Start-Sleep -Seconds 35

Write-Host "Sample 2:"
$s2 = Read-RateLimitSnapshot
$t2 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$p2 = $s2.rateLimits.primary
Write-Host "T2 ($t2): resetsAt=$($p2.resetsAt), duration=$($p2.windowDurationMins), usedPercent=$($p2.usedPercent)"

Start-Sleep -Seconds 35

Write-Host "Sample 3:"
$s3 = Read-RateLimitSnapshot
$t3 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$p3 = $s3.rateLimits.primary
Write-Host "T3 ($t3): resetsAt=$($p3.resetsAt), duration=$($p3.windowDurationMins), usedPercent=$($p3.usedPercent)"

$isFixed = ($p1.resetsAt -eq $p2.resetsAt -and $p2.resetsAt -eq $p3.resetsAt)
Write-Host "Anchor Behavior: " (if ($isFixed) { "FIXED_ANCHOR" } else { "SLIDING_OR_UNINITIALIZED" })

# Return sanitized output
[PSCustomObject]@{
    fiveHourWindow = [PSCustomObject]@{
        durationMinutes      = $p1.windowDurationMins
        resetAt              = ([DateTimeOffset]::FromUnixTimeSeconds($p1.resetsAt).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss"))
        resetAtUnix          = $p1.resetsAt
        usedPercent          = $p1.usedPercent
        ordinaryUsageAllowed = $s1.ordinaryUsageAllowed
        anchorBehavior       = (if ($isFixed) { "FIXED" } else { "SLIDING" })
    }
} | ConvertTo-Json -Depth 5
