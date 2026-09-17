# Execute-CodexWarmup.ps1
# Performs minimal ephemeral Codex exec request using resolved runtime with bounded execution

[CmdletBinding()]
param(
    [string]$CodexExe,
    [string]$Model = "gpt-5.6-luna",
    [string]$Prompt = "Reply only: Ready",
    [string]$WorkspaceDir = "$env:LOCALAPPDATA\CodexWarmupV2\workspace",
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }

if (-not $CodexExe -or -not (Test-Path $CodexExe)) {
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

$runnerModule = Join-Path $scriptDir "ProcessRunner.psm1"
Import-Module $runnerModule -Force

$args = "exec --ephemeral --skip-git-repo-check -s read-only -m $Model -C `"$WorkspaceDir`" `"$Prompt`""
$startTime = Get-Date

$procRes = Invoke-BoundedProcess -FilePath $CodexExe -Arguments $args -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkspaceDir

$endTime = Get-Date

[PSCustomObject]@{
    StartTime    = $startTime.ToString("o")
    EndTime      = $endTime.ToString("o")
    DurationSec  = $procRes.DurationSec
    Model        = $Model
    ExitCode     = $procRes.ExitCode
    Stdout       = $procRes.Stdout
    Stderr       = $procRes.Stderr
    TimedOut     = $procRes.TimedOut
    Success      = ($procRes.Success -and $procRes.Stdout -match "Ready")
}