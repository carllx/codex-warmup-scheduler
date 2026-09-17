# ScheduledTrigger.psm1
# Declaration-only module managing Windows Scheduled Task triggers for Codex Warmup V2
# Exports: Update-ScheduledTrigger

function Update-ScheduledTrigger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [DateTime]$TargetDateTime,

        [Parameter(Mandatory=$false)]
        [string]$TaskName = "Codex Warmup",

        [switch]$DryRun,
        [switch]$ShadowMode
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if (-not $task) {
        throw "Scheduled task '$TaskName' not found."
    }

    $now = Get-Date

    if ($TargetDateTime) {
        if ($TargetDateTime -le $now.AddMinutes(1)) {
            Write-Warning "TargetDateTime $TargetDateTime is in the past or within 1 minute. Bounding to now + 2 minutes."
            $TargetDateTime = $now.AddMinutes(2)
        }
    }

    Write-Host "Updating scheduled triggers for task '$TaskName'..."
    Write-Host "  Target Wakeup: $(if ($TargetDateTime) { $TargetDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'NONE (AtLogOn only)' })"
    Write-Host "  DryRun: $($DryRun.IsPresent), ShadowMode: $($ShadowMode.IsPresent)"

    # Construct triggers:
    # 1. Dynamic one-shot TimeTrigger
    $triggers = @()
    if ($TargetDateTime) {
        $oneShotTrigger = New-ScheduledTaskTrigger -Once -At $TargetDateTime
        $triggers += $oneShotTrigger
    }

    # 2. AtLogOn recovery trigger
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $triggers += $logonTrigger

    # Configure settings strictly according to user rules:
    # WakeToRun = true, StartWhenAvailable = true, MultipleInstances = IgnoreNew
    $settings = New-ScheduledTaskSettingsSet `
        -WakeToRun `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    if ($DryRun -or $ShadowMode) {
        Write-Host "[DryRun/ShadowMode] Proposed Trigger Count: $($triggers.Count)"
        foreach ($trig in $triggers) {
            if ($trig.StartBoundary) {
                Write-Host "  - Dynamic TimeTrigger: StartBoundary=$($trig.StartBoundary)"
            } else {
                Write-Host "  - Recovery Trigger: AtLogOn"
            }
        }
        Write-Host "[DryRun/ShadowMode] Settings: WakeToRun=$($settings.WakeToRun), StartWhenAvailable=$($settings.StartWhenAvailable), MultipleInstances=$($settings.MultipleInstances)"
        return [PSCustomObject]@{
            Success        = $true
            Mode           = if ($DryRun) { "DryRun" } else { "ShadowMode" }
            TargetDateTime = if ($TargetDateTime) { $TargetDateTime.ToString("o") } else { $null }
            NextRunTime    = if ($TargetDateTime) { $TargetDateTime.ToString("o") } else { $null }
        }
    }

    # Apply to Scheduled Task
    Set-ScheduledTask -TaskName $TaskName -Trigger $triggers -Settings $settings | Out-Null

    # Read-back verification
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $updatedTask = Get-ScheduledTask -TaskName $TaskName

    $verifiedNextRun = $info.NextRunTime
    Write-Host "Task triggers updated successfully."
    Write-Host "  Verified Trigger Count: $($updatedTask.Triggers.Count)"
    Write-Host "  Verified NextRunTime:   $verifiedNextRun"

    return [PSCustomObject]@{
        Success        = $true
        Mode           = "Production"
        TargetDateTime = if ($TargetDateTime) { $TargetDateTime.ToString("o") } else { $null }
        NextRunTime    = if ($verifiedNextRun) { $verifiedNextRun.ToString("o") } else { $null }
        TriggerCount   = $updatedTask.Triggers.Count
    }
}

Export-ModuleMember -Function Update-ScheduledTrigger