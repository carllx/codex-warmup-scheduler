<#
.SYNOPSIS
    Codex Warmup Module for Codex Warmup V2.
.DESCRIPTION
    Declaration-only module providing Invoke-CodexWarmup to trigger minimal
    ephemeral warmup execution with bounded timeouts.
#>

# Capture module root at module load time
$script:CodexWarmupModuleRoot = $PSScriptRoot
if (-not $script:CodexWarmupModuleRoot -and $MyInvocation.MyCommand.Path) {
    $script:CodexWarmupModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Invoke-CodexWarmup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$CodexExe,

        [Parameter(Mandatory=$false)]
        [string]$Model = "gpt-5.6-luna",

        [Parameter(Mandatory=$false)]
        [string]$Prompt = "Reply only: Ready",

        [Parameter(Mandatory=$false)]
        [string]$WorkspaceDir = "$env:LOCALAPPDATA\CodexWarmupV2\workspace",

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 45
    )

    $ErrorActionPreference = "Stop"
    $moduleDir = $script:CodexWarmupModuleRoot
    if (-not $moduleDir) {
        throw "Cannot resolve CodexWarmup module root."
    }

    if (-not $CodexExe -or -not (Test-Path $CodexExe)) {
        . (Join-Path $moduleDir "Resolve-CodexRuntime.ps1")
        $resolved = Resolve-CodexExecutable
        if (-not $resolved.validated) {
            throw "Cannot execute warmup: Codex runtime could not be resolved."
        }
        $CodexExe = $resolved.path
    }

    if (-not (Test-Path $WorkspaceDir)) {
        New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
    }

    $runnerModule = Join-Path $moduleDir "ProcessRunner.psm1"
    Import-Module $runnerModule -Force

    $args = "exec --ephemeral --skip-git-repo-check -s read-only -m $Model -C `"$WorkspaceDir`" `"$Prompt`""
    $startTime = Get-Date

    $procRes = Invoke-BoundedProcess -FilePath $CodexExe -Arguments $args -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkspaceDir

    $endTime = Get-Date

    return [PSCustomObject]@{
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
}

Set-Alias -Name Execute-CodexWarmup -Value Invoke-CodexWarmup
Export-ModuleMember -Function Invoke-CodexWarmup -Alias Execute-CodexWarmup
