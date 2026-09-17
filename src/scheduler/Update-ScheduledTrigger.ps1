# Update-ScheduledTrigger.ps1
# Thin CLI wrapper for Update-ScheduledTrigger from ScheduledTrigger.psm1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [DateTime]$TargetDateTime,

    [Parameter(Mandatory=$false)]
    [string]$TaskName = "Codex Warmup",

    [switch]$DryRun,
    [switch]$ShadowMode
)

$modulePath = Join-Path $PSScriptRoot "ScheduledTrigger.psm1"
Import-Module $modulePath -Force

Update-ScheduledTrigger @PSBoundParameters