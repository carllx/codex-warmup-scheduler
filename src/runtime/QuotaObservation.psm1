# QuotaObservation.psm1
# Codex Warmup V2 - Non-content observational quota telemetry

function Write-QuotaObservation {
    param(
        [Parameter(Mandatory=$true)]$Classification,
        [string]$RuntimeVersion,
        [string]$ObservationsPath
    )
    try {
        $fiveHourUsed = $null
        if ($Classification.Identified5hWindow -and $null -ne $Classification.Identified5hWindow.usedPercent) {
            $fiveHourUsed = [double]$Classification.Identified5hWindow.usedPercent
        }
        $weeklyUsed = $null
        if ($Classification.IdentifiedWeeklyWindow -and $null -ne $Classification.IdentifiedWeeklyWindow.usedPercent) {
            $weeklyUsed = [double]$Classification.IdentifiedWeeklyWindow.usedPercent
        }

        $record = [ordered]@{
            schemaVersion        = 1
            observedAt           = if ($Classification.ObservedAt) { [string]$Classification.ObservedAt } else { (Get-Date).ToString("o") }
            fiveHourStatus       = [string]$Classification.FiveHourWindowStatus
            fiveHourUsedPercent  = $fiveHourUsed
            resetAt              = if ($Classification.ResetAt) { [string]$Classification.ResetAt } else { $null }
            resetEpoch           = if ($null -ne $Classification.ResetEpoch) { [long]$Classification.ResetEpoch } else { $null }
            resetAnchorStatus    = if ($Classification.ResetAnchorStatus) { [string]$Classification.ResetAnchorStatus } else { $null }
            weeklyUsedPercent    = $weeklyUsed
            weeklyBlocked        = [bool]$Classification.WeeklyBlocked
            ordinaryUsageAllowed = [string]$Classification.OrdinaryUsageAllowed
            codexRuntimeVersion  = if ($RuntimeVersion) { [string]$RuntimeVersion } else { $null }
        }

        $jsonLine = $record | ConvertTo-Json -Compress
        Add-Content -Path $ObservationsPath -Value $jsonLine -Encoding utf8

        # Bounded retention: max 5000 records; if exceeded, keep newest 4000
        if (Test-Path $ObservationsPath) {
            $allLines = Get-Content -Path $ObservationsPath
            if ($allLines.Count -gt 5000) {
                $retained = $allLines[($allLines.Count - 4000)..($allLines.Count - 1)]
                $retained | Set-Content -Path $ObservationsPath -Encoding utf8
            }
        }
    } catch {
        Write-Warning "Failed to record quota observation: $_"
    }
}

Export-ModuleMember -Function Write-QuotaObservation
