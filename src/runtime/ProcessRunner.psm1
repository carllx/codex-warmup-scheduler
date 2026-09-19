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
        # Hard timeout reached: kill owned process tree immediately with bounded cleanup
        Stop-BoundedProcessTree -ProcessId $pidToManage -Process $proc -TimeoutMs 2000

        # Allow brief bounded wait for process to disappear
        $proc.WaitForExit(1000) | Out-Null

        # Bounded wait to drain any remaining partial streams from the terminated child
        try {
            [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 1000) | Out-Null
        } catch {}

        $endTime = Get-Date
        $durationSec = [Math]::Round(($endTime - $startTime).TotalSeconds, 2)

        $stdoutText = if ($outTask.IsCompleted) { $outTask.Result.Trim() } else { "" }
        $capturedErr = if ($errTask.IsCompleted) { $errTask.Result.Trim() } else { "" }
        $timeoutMsg = "Process '$FilePath' exceeded hard timeout of $TimeoutSeconds seconds and was terminated."
        $stderrText = if ($capturedErr) { "$capturedErr`n$timeoutMsg" } else { $timeoutMsg }

        return [PSCustomObject]@{
            Success     = $false
            ExitCode    = -1
            Stdout      = $stdoutText
            Stderr      = $stderrText
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

function Stop-BoundedProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [int]$ProcessId = 0,

        [Parameter(Mandatory=$false)]
        [System.Diagnostics.Process]$Process = $null,

        [Parameter(Mandatory=$false)]
        [int]$TimeoutMs = 2000
    )

    if ($ProcessId -le 0 -and $Process) {
        try { $ProcessId = $Process.Id } catch {}
    }
    if ($ProcessId -le 0) { return }

    # 1. Bounded taskkill execution: launch with ProcessStartInfo and wait at most $TimeoutMs
    try {
        $taskkillPath = "$env:SystemRoot\System32\taskkill.exe"
        if (Test-Path $taskkillPath) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $taskkillPath
            $psi.Arguments = "/PID $ProcessId /T /F"
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $tkProc = [System.Diagnostics.Process]::Start($psi)
            if ($tkProc) {
                $completed = $tkProc.WaitForExit($TimeoutMs)
                if (-not $completed) {
                    try { $tkProc.Kill() } catch {}
                }
            }
        }
    } catch {}

    # 2. Direct termination fallback if target process instance still exists
    try {
        if ($Process -and -not $Process.HasExited) {
            $Process.Kill()
        } elseif (-not $Process) {
            $p = [System.Diagnostics.Process]::GetProcessById($ProcessId)
            if ($p -and -not $p.HasExited) {
                $p.Kill()
            }
        }
    } catch {}
}

Export-ModuleMember -Function Invoke-BoundedProcess, Stop-BoundedProcessTree