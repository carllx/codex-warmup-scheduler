# rollback_to_v1.ps1
# Restores Codex Warmup V1 Scheduled Task from backup XML

[CmdletBinding()]
param(
    [string]$BackupXmlPath = "$env:LOCALAPPDATA\CodexWarmupV2\backup\CodexWarmup_v1_task.xml",
    [string]$TaskName = "Codex Warmup"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BackupXmlPath)) {
    throw "Backup XML not found at: $BackupXmlPath"
}

Write-Host "Restoring '$TaskName' from backup XML: $BackupXmlPath"

$xmlContent = Get-Content -Path $BackupXmlPath -Raw

Register-ScheduledTask -TaskName $TaskName -Xml $xmlContent -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
Write-Host "Task '$TaskName' restored successfully. State: $($task.State)"
Write-Host "Triggers count: $($task.Triggers.Count)"
Write-Host "Action: $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
