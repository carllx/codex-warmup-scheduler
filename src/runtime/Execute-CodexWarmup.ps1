# Execute-CodexWarmup.ps1
# Performs minimal ephemeral Codex exec request using resolved runtime

[CmdletBinding()]
param(
    [string]$CodexExe,
    [string]$Model = "gpt-5.6-luna",
    [string]$Prompt = "Reply only: Ready",
    [string]$WorkspaceDir = "$env:LOCALAPPDATA\CodexWarmupV2\workspace"
)

$ErrorActionPreference = "Stop"

if (-not $CodexExe -or -not (Test-Path $CodexExe)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDir "Resolve-CodexRuntime.ps1")
    $resolved = Resolve-CodexExecutable
    if (-not $resolved.validated) {
        throw "Cannot execute warmup: Codex runtime could not be resolved."
    }
    $CodexExe = $resolved.path
}

if (-not (Test-Path $WorkspaceDir)) {
    New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
}

$startTime = Get-Date
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $CodexExe
$psi.Arguments = "exec --ephemeral --skip-git-repo-check -s read-only -m $Model -C `"$WorkspaceDir`" `"$Prompt`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.StandardInput.Close()

$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

$endTime = Get-Date
$durationSec = [Math]::Round(($endTime - $startTime).TotalSeconds, 2)
$exitCode = $proc.ExitCode

[PSCustomObject]@{
    StartTime    = $startTime.ToString("o")
    EndTime      = $endTime.ToString("o")
    DurationSec  = $durationSec
    Model        = $Model
    ExitCode     = $exitCode
    Stdout       = $stdout.Trim()
    Stderr       = $stderr.Trim()
    Success      = ($exitCode -eq 0 -and $stdout.Trim() -match "Ready")
}
