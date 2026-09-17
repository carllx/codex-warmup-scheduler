<#
.SYNOPSIS
    ProcessRunner Module for Codex Warmup V2.
.DESCRIPTION
    Declaration-only module providing bounded external process execution,
    concurrent pipe draining to avoid deadlock, hard timeout, and process-tree cleanup.
    Fully compatible with Windows PowerShell 5.1 and PowerShell Core.
#>

function Invoke-BoundedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,

        [Parameter(Mandatory=$false)]
        [string]$Arguments = "",

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 30,

        [Parameter(Mandatory=$false)]
        [string]$WorkingDirectory = $null
    )

    $startTime = Get-Date
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [PSCustomObject]@{
            Success     = $false
            ExitCode    = -1
            Stdout      = ""
            Stderr      = "Failed to start process '$FilePath': $_"
            TimedOut    = $false
            DurationSec = 0
        }
    }

    $pidToManage = $proc.Id

    # Drain stdout and stderr concurrently using async task readers to prevent pipe deadlocks
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $timeoutMs = $TimeoutSeconds * 1000
    $exited = $proc.WaitForExit($timeoutMs)

    if (-not $exited) {
        # Hard timeout reached: kill owned process tree immediately
        try {
            $taskkillPath = "$env:SystemRoot\System32\taskkill.exe"
            if (Test-Path $taskkillPath) {
                & $taskkillPath /PID $pidToManage /T /F | Out-Null
            } else {
                $proc.Kill()
            }
        } catch {}

        # Allow brief bounded wait for process to disappear
        $proc.WaitForExit(1000) | Out-Null

        $endTime = Get-Date
        $durationSec = [Math]::Round(($endTime - $startTime).TotalSeconds, 2)

        return [PSCustomObject]@{
            Success     = $false
            ExitCode    = -1
            Stdout      = if ($outTask.IsCompleted) { $outTask.Result.Trim() } else { "" }
            Stderr      = "Process '$FilePath' exceeded hard timeout of $TimeoutSeconds seconds and was terminated."
            TimedOut    = $true
            DurationSec = $durationSec
        }
    }

    # Process completed within timeout. Drain remaining stream tasks with bounded wait
    [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 2000) | Out-Null

    $endTime = Get-Date
    $durationSec = [Math]::Round(($endTime - $startTime).TotalSeconds, 2)

    $stdoutText = if ($outTask.IsCompleted) { $outTask.Result.Trim() } else { "" }
    $stderrText = if ($errTask.IsCompleted) { $errTask.Result.Trim() } else { "" }

    return [PSCustomObject]@{
        Success     = ($proc.ExitCode -eq 0)
        ExitCode    = $proc.ExitCode
        Stdout      = $stdoutText
        Stderr      = $stderrText
        TimedOut    = $false
        DurationSec = $durationSec
    }
}

Export-ModuleMember -Function Invoke-BoundedProcess