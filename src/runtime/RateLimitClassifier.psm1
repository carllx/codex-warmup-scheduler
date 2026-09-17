<#
.SYNOPSIS
    RateLimitClassifier Module for Codex Warmup V2.
.DESCRIPTION
    Declaration-only module. Provides ConvertTo-NormalizedQuotaState to evaluate
    Codex rate-limit RPC payloads against fail-closed rules and produce a standardized NormalizedQuotaState.
#>

function ConvertTo-NormalizedQuotaState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$RateLimitResponse,

        [Parameter(Mandatory=$false)]
        [object]$PreviousProbe = $null,

        [Parameter(Mandatory=$false)]
        [DateTimeOffset]$CurrentTime = [DateTimeOffset]::Now,

        [Parameter(Mandatory=$false)]
        [string]$CodexRuntimeVersion = $null
    )

    $result = [PSCustomObject]@{
        OrdinaryUsageAllowed   = "UNKNOWN" # TRUE, FALSE, UNKNOWN
        FiveHourWindowStatus   = "FIVE_HOUR_WINDOW_UNKNOWN" # ACTIVE, INACTIVE, AMBIGUOUS, BLOCKED, FIVE_HOUR_WINDOW_UNKNOWN
        ResetAnchorStatus      = "UNKNOWN" # FIXED, SLIDING_OR_UNINITIALIZED, UNKNOWN
        WeeklyBlocked          = $false
        ResetAt                = $null # ISO 8601 string
        ResetEpoch             = $null
        WindowDurationMinutes  = 300
        CanEvaluateWarmup      = $false
        Reason                 = ""
        ObservedAt             = $CurrentTime.ToString("o")
        CodexRuntimeVersion    = $CodexRuntimeVersion
        Identified5hWindow     = $null
        IdentifiedWeeklyWindow = $null
    }

    if ($null -eq $RateLimitResponse) {
        $result.Reason = "Rate limit response is null."
        return $result
    }

    # Unwrap JSON-RPC result if present
    $payload = $RateLimitResponse
    if ($payload.result) {
        $payload = $payload.result
    }

    # 1. ordinaryUsageAllowed (Hard Gate: TRUE / FALSE / UNKNOWN)
    if ($null -ne $payload.ordinaryUsageAllowed) {
        if ($payload.ordinaryUsageAllowed -eq $true) {
            $result.OrdinaryUsageAllowed = "TRUE"
        } elseif ($payload.ordinaryUsageAllowed -eq $false) {
            $result.OrdinaryUsageAllowed = "FALSE"
            $result.FiveHourWindowStatus = "BLOCKED"
            $result.Reason = "ordinaryUsageAllowed is false (Hard Gate: Warmup Prohibited)."
            return $result
        } else {
            $result.OrdinaryUsageAllowed = "UNKNOWN"
            $result.FiveHourWindowStatus = "FIVE_HOUR_WINDOW_UNKNOWN"
            $result.Reason = "ordinaryUsageAllowed value is unexpected."
            return $result
        }
    } else {
        $result.OrdinaryUsageAllowed = "UNKNOWN"
        $result.FiveHourWindowStatus = "FIVE_HOUR_WINDOW_UNKNOWN"
        $result.Reason = "ordinaryUsageAllowed missing from payload (Fail-Closed)."
        return $result
    }

    # 2. Extract Codex rate limits (Contract: prefer rateLimitsByLimitId['codex'], fallback to rateLimits.limitId == 'codex')
    $codexLimitContainer = $null

    if ($payload.rateLimitsByLimitId -and $payload.rateLimitsByLimitId.codex) {
        $codexLimitContainer = $payload.rateLimitsByLimitId.codex
    } elseif ($payload.rateLimits -and $payload.rateLimits.limitId -eq "codex") {
        $codexLimitContainer = $payload.rateLimits
    }

    if ($null -eq $codexLimitContainer) {
        $result.FiveHourWindowStatus = "FIVE_HOUR_WINDOW_UNKNOWN"
        $result.Reason = "No rate limit container found for limitId 'codex' (Fail-Closed)."
        return $result
    }

    # 3. Extract candidate windows without assuming primary/secondary meaning
    $candidateWindows = @()
    if ($codexLimitContainer.primary) { $candidateWindows += $codexLimitContainer.primary }
    if ($codexLimitContainer.secondary) { $candidateWindows += $codexLimitContainer.secondary }
    if ($codexLimitContainer.windows -is [System.Collections.IEnumerable]) {
        foreach ($w in $codexLimitContainer.windows) { $candidateWindows += $w }
    }
    if ($codexLimitContainer.limits -is [System.Collections.IEnumerable]) {
        foreach ($w in $codexLimitContainer.limits) { $candidateWindows += $w }
    }

    # 4. Classify windows by windowDurationMins: 300 vs 10080
    $fiveHourCandidates = @()
    $weeklyCandidates = @()

    foreach ($w in $candidateWindows) {
        $dur = $w.windowDurationMins
        if ($dur -eq 300) {
            $fiveHourCandidates += $w
        } elseif ($dur -eq 10080) {
            $weeklyCandidates += $w
        }
    }

    # Weekly quota evaluation
    if ($codexLimitContainer.limitReached -eq $true) {
        $result.WeeklyBlocked = $true
    }
    foreach ($ww in $weeklyCandidates) {
        if ($ww.usedPercent -ge 100 -or $ww.rateLimitReachedType) {
            $result.WeeklyBlocked = $true
        }
    }
    $result.IdentifiedWeeklyWindow = if ($weeklyCandidates.Count -gt 0) { $weeklyCandidates[0] } else { $null }

    if ($result.WeeklyBlocked) {
        $result.FiveHourWindowStatus = "BLOCKED"
        $result.Reason = "Weekly quota is exhausted."
        return $result
    }

    # 5. Classify 5-hour candidate window
    if ($fiveHourCandidates.Count -eq 0) {
        $result.FiveHourWindowStatus = "FIVE_HOUR_WINDOW_UNKNOWN"
        $result.Reason = "No 300-minute window found for limitId 'codex' (Fail-Closed: do not assume primary == 300m)."
        return $result
    }
    if ($fiveHourCandidates.Count -gt 1) {
        $result.FiveHourWindowStatus = "FIVE_HOUR_WINDOW_UNKNOWN"
        $result.Reason = "Multiple 300-minute window candidates found (ambiguous schema)."
        return $result
    }

    $fiveHourWindow = $fiveHourCandidates[0]
    $result.Identified5hWindow = $fiveHourWindow

    if ($null -eq $fiveHourWindow.resetsAt) {
        $result.FiveHourWindowStatus = "INACTIVE"
        $result.ResetAnchorStatus = "SLIDING_OR_UNINITIALIZED"
        $result.CanEvaluateWarmup = $true
        $result.Reason = "No reset timestamp; window is inactive and uninitialized."
        return $result
    }

    $resetEpoch = [long]$fiveHourWindow.resetsAt
    $result.ResetEpoch = $resetEpoch
    $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch)
    $resetLocal = $resetUtc.ToLocalTime()
    $nowLocal = $CurrentTime.ToLocalTime()

    if ($resetLocal -le $nowLocal) {
        $result.FiveHourWindowStatus = "INACTIVE"
        $result.ResetAnchorStatus = "FIXED"
        $result.CanEvaluateWarmup = $true
        $result.Reason = "Prior window has already expired at $($resetLocal.ToString('o'))."
        return $result
    }

    $result.ResetAt = $resetLocal.ToString("yyyy-MM-ddTHH:mm:sszzz")
    $deltaMinutes = ($resetLocal - $nowLocal).TotalMinutes

    # 6. Reset Anchor Classification (FIXED vs SLIDING_OR_UNINITIALIZED vs UNKNOWN)
    $priorResetEpoch = $null
    if ($PreviousProbe) {
        if ($PreviousProbe.ResetEpoch) {
            $priorResetEpoch = [long]$PreviousProbe.ResetEpoch
        } elseif ($PreviousProbe -is [long] -or $PreviousProbe -is [int]) {
            $priorResetEpoch = [long]$PreviousProbe
        }
    }

    if (($fiveHourWindow.usedPercent -eq 0 -or $null -eq $fiveHourWindow.usedPercent) -and ($deltaMinutes -ge 295)) {
        if ($null -ne $priorResetEpoch -and $resetEpoch -ne $priorResetEpoch) {
            $result.ResetAnchorStatus = "SLIDING_OR_UNINITIALIZED"
            $result.FiveHourWindowStatus = "AMBIGUOUS"
            $result.CanEvaluateWarmup = $false
            $result.Reason = "Reset anchor is sliding with clock (uninitialized). Quota state is ambiguous."
            return $result
        } elseif ($null -eq $priorResetEpoch) {
            $result.ResetAnchorStatus = "SLIDING_OR_UNINITIALIZED"
            $result.FiveHourWindowStatus = "AMBIGUOUS"
            $result.CanEvaluateWarmup = $false
            $result.Reason = "Potential sliding reset anchor detected (delta ~$([Math]::Round($deltaMinutes))m, 0% usage). Needs subsequent probe."
            return $result
        }
    }

    $result.ResetAnchorStatus = "FIXED"
    $result.FiveHourWindowStatus = "ACTIVE"
    $result.CanEvaluateWarmup = $true
    $result.Reason = "Stable 5-hour active window established until $($resetLocal.ToString('o'))."

    return $result
}

Export-ModuleMember -Function ConvertTo-NormalizedQuotaState
