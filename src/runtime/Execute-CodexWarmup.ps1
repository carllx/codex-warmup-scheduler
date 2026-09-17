# Execute-CodexWarmup.ps1
# Performs minimal ephemeral Codex exec request using resolved runtime

[CmdletBinding()]
param(
    [string],
    [string] =  gpt-5.6-luna,
    [string] = Reply only: Ready,
    [string] = C:\Users\carll\AppData\Local\CodexWarmupV2\workspace
)

Continue = Stop

if (-not  -or -not (Test-Path )) {
     = Split-Path -Parent System.Management.Automation.InvocationInfo.MyCommand.Path
    . \Resolve-CodexRuntime.ps1
     = Resolve-CodexExecutable
    if (-not .validated) {
        throw Cannot execute warmup: Codex runtime could not be resolved.
    }
     = .path
}

if (-not (Test-Path )) {
    New-Item -ItemType Directory -Force -Path  | Out-Null
}

 = Get-Date
 = New-Object System.Diagnostics.ProcessStartInfo
.FileName = 
.Arguments = exec --ephemeral --skip-git-repo-check -s read-only -m -C "" ""
.UseShellExecute = False
.RedirectStandardInput = True
.RedirectStandardOutput = True
.RedirectStandardError = True
.CreateNoWindow = True

 = [System.Diagnostics.Process]::Start()
.StandardInput.Close()

 = .StandardOutput.ReadToEnd()
 = .StandardError.ReadToEnd()
.WaitForExit()

 = Get-Date
 = [Math]::Round(( - ).TotalSeconds, 2)
 = .ExitCode

[PSCustomObject]@{
    StartTime    = .ToString(o)
    EndTime      = .ToString(o)
    DurationSec  = 
    Model        = 
    ExitCode     = 
    Stdout       = .Trim()
    Stderr       = .Trim()
    Success      = ( -eq 0 -and .Trim() -match Ready)
}
