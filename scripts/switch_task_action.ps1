[CmdletBinding()]
param(
    [switch]$ShadowMode
)

$ErrorActionPreference = "Stop"

$taskName = "Codex Warmup"
$runtimeController = "$env:LOCALAPPDATA\CodexWarmupV2\runtime\controller.ps1"

if (-not (Test-Path $runtimeController)) {
    throw "Runtime controller not found at: $runtimeController"
}

$task = Get-ScheduledTask -TaskName $taskName
Write-Host "Current Task State: $($task.State)"

$argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$runtimeController`""
if ($ShadowMode) {
    $argStr += " -ShadowMode"
}

$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argStr

Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
Write-Host "Task action updated to deployed runtime: $runtimeController"

$updatedTask = Get-ScheduledTask -TaskName $taskName
$updatedAction = $updatedTask.Actions[0]
Write-Host "Verified Updated Action Execute: $($updatedAction.Execute)"
Write-Host "Verified Updated Action Arguments: $($updatedAction.Arguments)"
