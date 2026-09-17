# update-runtime.ps1
# Deploys source repository scripts and configs to %LOCALAPPDATA%\CodexWarmupV2\runtime

[CmdletBinding()]
param(
    [string]$TargetBase = "$env:LOCALAPPDATA\CodexWarmupV2",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$RuntimeTarget = Join-Path $TargetBase "runtime"
$ConfigTarget = Join-Path $TargetBase "config"
$BackupTarget = Join-Path $TargetBase "backup"

Write-Host "Deploying Codex Warmup V2 from $RepoRoot to $TargetBase..."

foreach ($dir in @($RuntimeTarget, $ConfigTarget, $BackupTarget)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

# Deploy runtime files
$filesToDeploy = @(
    "src\runtime\Resolve-CodexRuntime.ps1",
    "src\runtime\Get-CodexRateLimits.ps1",
    "src\runtime\Execute-CodexWarmup.ps1",
    "src\runtime\RateLimitClassifier.psm1",
    "src\scheduler\Update-ScheduledTrigger.ps1",
    "src\engine\decision_engine.py",
    "src\scheduler\controller.ps1"
)

foreach ($relPath in $filesToDeploy) {
    $src = Join-Path $RepoRoot $relPath
    if (Test-Path $src) {
        $dest = Join-Path $RuntimeTarget (Split-Path -Leaf $src)
        Copy-Item -Path $src -Destination $dest -Force
        Write-Host "  Deployed: $(Split-Path -Leaf $src) -> $RuntimeTarget"
    } else {
        Write-Warning "Source file missing: $src"
    }
}

# Deploy config
$cfgSrc = Join-Path $RepoRoot "config\default.json"
$cfgDest = Join-Path $ConfigTarget "default.json"
if (Test-Path $cfgSrc) {
    if (-not (Test-Path $cfgDest) -or $Force) {
        Copy-Item -Path $cfgSrc -Destination $cfgDest -Force
        Write-Host "  Deployed config: default.json -> $ConfigTarget"
    } else {
        Write-Host "  Config already exists at $cfgDest (use -Force to overwrite)"
    }
}

Write-Host "Deployment completed successfully."
