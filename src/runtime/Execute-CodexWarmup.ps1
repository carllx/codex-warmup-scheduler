# Execute-CodexWarmup.ps1
# Thin CLI wrapper for Invoke-CodexWarmup from CodexWarmup.psm1

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

$modulePath = Join-Path $PSScriptRoot "CodexWarmup.psm1"
Import-Module $modulePath -Force

Invoke-CodexWarmup @PSBoundParameters
