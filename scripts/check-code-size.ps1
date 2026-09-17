# check-code-size.ps1
# Scans project-authored .py, .ps1, and .psm1 files, excluding generated artifacts and caches.
# Reports path, LOC, and review level based on AGENTS.md Agent Navigability guidelines.

[CmdletBinding()]
param(
    [string]$RootDirectory = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"

$excludePatterns = @(
    "*\.git\*",
    "*\__pycache__\*",
    "*\.pytest_cache\*",
    "*\node_modules\*",
    "*\logs\*",
    "*\state\*",
    "*\backup\*",
    "*\scenarios.json",
    "*\simulation_report.json"
)

$extensions = @("*.py", "*.ps1", "*.psm1")

$files = Get-ChildItem -Path $RootDirectory -Recurse -File -Include $extensions | Where-Object {
    $itemPath = $_.FullName
    $excluded = $false
    foreach ($pat in $excludePatterns) {
        if ($itemPath -like $pat) { $excluded = $true; break }
    }
    -not $excluded
}

$results = @()

foreach ($file in $files) {
    $lines = (Get-Content -Path $file.FullName -Encoding utf8).Count
    $relPath = if ($file.FullName.StartsWith($RootDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        $file.FullName.Substring($RootDirectory.Length).TrimStart('\', '/')
    } else {
        $file.FullName
    }
    
    $level = "NORMAL (<400 LOC)"
    if ($lines -gt 700) {
        $level = "EXCEEDS_CEILING (>700 LOC)"
    } elseif ($lines -gt 500) {
        $level = "WARNING_INSPECT_SEAMS (>500 LOC)"
    } elseif ($lines -gt 400) {
        $level = "ATTENTION (>400 LOC)"
    }

    $results += [PSCustomObject]@{
        Path        = $relPath
        LOC         = $lines
        ReviewLevel = $level
    }
}

Write-Host "================================================================================"
Write-Host "CODEX WARMUP V2 - AGENT NAVIGABILITY CODE SIZE REPORT"
Write-Host "================================================================================"

$results | Sort-Object LOC -Descending | Format-Table -AutoSize -Property LOC, ReviewLevel, Path

$over400 = $results | Where-Object { $_.LOC -gt 400 }
if ($over400.Count -gt 0) {
    Write-Host "`nFiles exceeding 400 LOC review threshold:"
    $over400 | ForEach-Object { Write-Host "  - $($_.Path): $($_.LOC) LOC [$($_.ReviewLevel)]" }
} else {
    Write-Host "`nAll authored files are within the 400 LOC preferred threshold."
}
