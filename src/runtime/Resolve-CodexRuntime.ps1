function Resolve-CodexExecutable {
    [CmdletBinding()]
    param()

    # Priority A: Check PATH / where.exe
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path $cmd.Source)) {
        $ver = Test-CodexExecutable $cmd.Source
        if ($ver) {
            return [PSCustomObject]@{
                path      = $cmd.Source
                version   = $ver
                source    = "PATH"
                validated = $true
            }
        }
    }

    # Priority B: Check ~/.codex/config.toml CODEX_CLI_PATH
    $configPath = "$env:USERPROFILE\.codex\config.toml"
    if (Test-Path $configPath) {
        $lines = Get-Content $configPath -ErrorAction SilentlyContinue
        $cliLine = $lines | Where-Object { $_ -match '^\s*CODEX_CLI_PATH\s*=\s*[''"]([^''"]+)[''"]' }
        if ($cliLine -and $matches[1]) {
            $candidate = $matches[1]
            if (Test-Path $candidate) {
                $ver = Test-CodexExecutable $candidate
                if ($ver) {
                    return [PSCustomObject]@{
                        path      = $candidate
                        version   = $ver
                        source    = "CONFIG"
                        validated = $true
                    }
                }
            }
        }
    }

    # Priority C: Scan %LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe
    $scanBase = "$env:LOCALAPPDATA\OpenAI\Codex\bin"
    if (Test-Path $scanBase) {
        $candidates = Get-ChildItem -Path $scanBase -Filter "codex.exe" -Recurse -File -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending

        foreach ($cand in $candidates) {
            $ver = Test-CodexExecutable $cand.FullName
            if ($ver) {
                return [PSCustomObject]@{
                    path      = $cand.FullName
                    version   = $ver
                    source    = "SCAN"
                    validated = $true
                }
            }
        }
    }

    return [PSCustomObject]@{
        path      = $null
        version   = $null
        source    = "CODEX_RUNTIME_UNAVAILABLE"
        validated = $false
    }
}

function Test-CodexExecutable {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
        $runnerModule = Join-Path $scriptDir "ProcessRunner.psm1"
        if (Test-Path $runnerModule) {
            Import-Module $runnerModule -Force
            $procRes = Invoke-BoundedProcess -FilePath $FilePath -Arguments "--version" -TimeoutSeconds 5
            if ($procRes.Success -and $procRes.Stdout) {
                return $procRes.Stdout.Trim()
            }
            return $null
        }

        # Fallback bounded execution if module not co-located
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = "--version"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $exited = $p.WaitForExit(5000)
        if (-not $exited) {
            try {
                $taskkillPath = "$env:SystemRoot\System32\taskkill.exe"
                if (Test-Path $taskkillPath) {
                    & $taskkillPath /PID $p.Id /T /F | Out-Null
                } else {
                    $p.Kill()
                }
            } catch {}
            $p.WaitForExit(1000) | Out-Null
            return $null
        }
        [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 1000) | Out-Null
        if ($p.ExitCode -eq 0 -and $outTask.IsCompleted -and $outTask.Result) {
            return $outTask.Result.Trim()
        }
    } catch {
        return $null
    }
    return $null
}

# If run directly as a script, output JSON
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {
    $resolved = Resolve-CodexExecutable
    $resolved | ConvertTo-Json -Compress
}