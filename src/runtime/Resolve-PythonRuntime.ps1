# Resolve-PythonRuntime.ps1
# Discovers and validates Python runtime for Codex Warmup V2 Decision Engine
# Exports: Resolve-PythonExecutable, Test-PythonExecutable

$script:PythonRuntimeResolverRoot = $PSScriptRoot
if (-not $script:PythonRuntimeResolverRoot -and $MyInvocation.MyCommand.Path) {
    $script:PythonRuntimeResolverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Test-PythonExecutable {
    param([string]$FilePath)

    if (-not $FilePath -or -not (Test-Path $FilePath)) { return $null }

    # Exclude WindowsApps stub / app execution aliases (reparse points that exit 9009)
    if ($FilePath -match 'AppData[\\/]Local[\\/]Microsoft[\\/]WindowsApps') {
        return $null
    }

    try {
        $item = Get-Item $FilePath -ErrorAction SilentlyContinue
        if ($item -and $item.Length -eq 0) {
            return $null
        }
    } catch {
        return $null
    }

    # Decision Engine requires python with dateutil
    $testCode = "import sys, dateutil; print(sys.version.split()[0])"
    $scriptDir = $script:PythonRuntimeResolverRoot
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }

    $runnerModule = if ($scriptDir) { Join-Path $scriptDir "ProcessRunner.psm1" } else { $null }
    if ($runnerModule -and (Test-Path $runnerModule)) {
        Import-Module $runnerModule -Force
    }

    if (Get-Command Invoke-BoundedProcess -ErrorAction SilentlyContinue) {
        $res = Invoke-BoundedProcess -FilePath $FilePath -Arguments "-c `"$testCode`"" -TimeoutSeconds 5
        if ($res.Success -and $res.ExitCode -eq 0 -and $res.Stdout) {
            $ver = $res.Stdout.Trim().Split("`r`n")[0].Trim()
            return [PSCustomObject]@{
                Valid   = $true
                Version = "Python $ver"
            }
        }
        return $null
    }

    # Fallback to ProcessStartInfo if ProcessRunner module is not co-located
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = "-c `"$testCode`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        if ($p.WaitForExit(5000)) {
            $stdout = $outTask.Result
            if ($p.ExitCode -eq 0 -and $stdout) {
                $ver = $stdout.Trim().Split("`r`n")[0].Trim()
                return [PSCustomObject]@{
                    Valid   = $true
                    Version = "Python $ver"
                }
            }
        } else {
            try { $p.Kill() } catch {}
        }
    } catch {}

    return $null
}

function Resolve-PythonExecutable {
    [CmdletBinding()]
    param()

    $tested = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Priority A: Explicit environment override
    $envCands = @($env:PYTHON_EXECUTABLE, $env:CODEX_WARMUP_PYTHON) | Where-Object { $_ }
    foreach ($cand in $envCands) {
        if (-not (Test-Path $cand)) { continue }
        $fullPath = [System.IO.Path]::GetFullPath($cand)
        if ($tested.Add($fullPath)) {
            $t = Test-PythonExecutable $fullPath
            if ($t) {
                return [PSCustomObject]@{
                    path      = $fullPath
                    version   = $t.Version
                    source    = "ENV_OVERRIDE"
                    validated = $true
                }
            }
        }
    }

    # Priority B: PATH / where.exe
    $pathCands = @()
    $cmdCands = Get-Command python.exe, python -All -ErrorAction SilentlyContinue
    if ($cmdCands) {
        foreach ($c in $cmdCands) {
            if ($c.Source) { $pathCands += $c.Source }
            elseif ($c.Path) { $pathCands += $c.Path }
        }
    }
    $whereCands = where.exe python 2>$null
    if ($whereCands) {
        $pathCands += $whereCands
    }

    foreach ($cand in $pathCands) {
        if (-not $cand -or -not (Test-Path $cand)) { continue }
        $fullPath = [System.IO.Path]::GetFullPath($cand)
        if ($tested.Add($fullPath)) {
            $t = Test-PythonExecutable $fullPath
            if ($t) {
                return [PSCustomObject]@{
                    path      = $fullPath
                    version   = $t.Version
                    source    = "PATH"
                    validated = $true
                }
            }
        }
    }

    # Priority C: Python Launcher (py -0p)
    $pyLauncher = Get-Command py.exe, py -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pyLauncher) {
        try {
            $pyLines = & $pyLauncher.Source -0p 2>$null
            foreach ($line in $pyLines) {
                if ($line -match '^\s*-[^\s]+\s+(.*)$') {
                    $cand = $matches[1].Trim()
                    if (Test-Path $cand) {
                        $fullPath = [System.IO.Path]::GetFullPath($cand)
                        if ($tested.Add($fullPath)) {
                            $t = Test-PythonExecutable $fullPath
                            if ($t) {
                                return [PSCustomObject]@{
                                    path      = $fullPath
                                    version   = $t.Version
                                    source    = "PY_LAUNCHER"
                                    validated = $true
                                }
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    # Priority D: Windows Registry (PythonCore registrations)
    $regRoots = @(
        "HKLM:\SOFTWARE\Python\PythonCore",
        "HKCU:\SOFTWARE\Python\PythonCore",
        "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore"
    )
    foreach ($regRoot in $regRoots) {
        if (-not (Test-Path $regRoot)) { continue }
        $verKeys = Get-ChildItem -Path $regRoot -ErrorAction SilentlyContinue
        foreach ($vk in $verKeys) {
            $ipKey = Join-Path $vk.PSPath "InstallPath"
            if (Test-Path $ipKey) {
                $prop = Get-ItemProperty -Path $ipKey -ErrorAction SilentlyContinue
                $exeProp = $prop.ExecutablePath
                $dirProp = $prop.'(default)'

                $regCands = @()
                if ($exeProp) { $regCands += $exeProp }
                if ($dirProp) { $regCands += (Join-Path $dirProp "python.exe") }

                foreach ($cand in $regCands) {
                    if (-not $cand -or -not (Test-Path $cand)) { continue }
                    $fullPath = [System.IO.Path]::GetFullPath($cand)
                    if ($tested.Add($fullPath)) {
                        $t = Test-PythonExecutable $fullPath
                        if ($t) {
                            return [PSCustomObject]@{
                                path      = $fullPath
                                version   = $t.Version
                                source    = "REGISTRY"
                                validated = $true
                            }
                        }
                    }
                }
            }
        }
    }

    # Priority E: Well-known installation directories & Conda
    $knownLocations = @(
        "$env:ProgramData\anaconda3\python.exe",
        "$env:ProgramData\miniconda3\python.exe",
        "$env:USERPROFILE\anaconda3\python.exe",
        "$env:USERPROFILE\miniconda3\python.exe"
    )

    foreach ($loc in $knownLocations) {
        if ($loc -and (Test-Path $loc)) {
            $fullPath = [System.IO.Path]::GetFullPath($loc)
            if ($tested.Add($fullPath)) {
                $t = Test-PythonExecutable $fullPath
                if ($t) {
                    return [PSCustomObject]@{
                        path      = $fullPath
                        version   = $t.Version
                        source    = "WELL_KNOWN"
                        validated = $true
                    }
                }
            }
        }
    }

    # Conda environments tracker file (~/.conda/environments.txt)
    $condaEnvFile = Join-Path $env:USERPROFILE ".conda\environments.txt"
    if (Test-Path $condaEnvFile) {
        $envLines = Get-Content $condaEnvFile -ErrorAction SilentlyContinue
        foreach ($envLine in $envLines) {
            $lineTrim = $envLine.Trim()
            if ($lineTrim -and (Test-Path $lineTrim)) {
                $cand = Join-Path $lineTrim "python.exe"
                if (Test-Path $cand) {
                    $fullPath = [System.IO.Path]::GetFullPath($cand)
                    if ($tested.Add($fullPath)) {
                        $t = Test-PythonExecutable $fullPath
                        if ($t) {
                            return [PSCustomObject]@{
                                path      = $fullPath
                                version   = $t.Version
                                source    = "CONDA_ENV"
                                validated = $true
                            }
                        }
                    }
                }
            }
        }
    }

    # Standard installation search roots (wildcards for version dirs)
    $scanGlobs = @(
        @{ Base = "$env:LOCALAPPDATA\Programs\Python"; Filter = "python.exe" },
        @{ Base = "C:\Program Files"; Filter = "Python*" },
        @{ Base = "C:\Program Files (x86)"; Filter = "Python*" },
        @{ Base = "C:\"; Filter = "Python*" }
    )

    foreach ($sg in $scanGlobs) {
        if (Test-Path $sg.Base) {
            $cands = Get-ChildItem -Path $sg.Base -Filter $sg.Filter -ErrorAction SilentlyContinue
            foreach ($item in $cands) {
                $candExe = if ($item.PSIsContainer) { Join-Path $item.FullName "python.exe" } else { $item.FullName }
                if (Test-Path $candExe) {
                    $fullPath = [System.IO.Path]::GetFullPath($candExe)
                    if ($tested.Add($fullPath)) {
                        $t = Test-PythonExecutable $fullPath
                        if ($t) {
                            return [PSCustomObject]@{
                                path      = $fullPath
                                version   = $t.Version
                                source    = "SCAN"
                                validated = $true
                            }
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        path      = $null
        version   = $null
        source    = "PYTHON_RUNTIME_UNAVAILABLE"
        validated = $false
    }
}
