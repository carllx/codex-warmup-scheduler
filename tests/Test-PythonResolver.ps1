$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ResolverScript = Join-Path $ScriptDir "..\src\runtime\Resolve-PythonRuntime.ps1"
if (-not (Test-Path $ResolverScript)) {
    $ResolverScript = "$env:LOCALAPPDATA\CodexWarmupV2\runtime\Resolve-PythonRuntime.ps1"
}

. $ResolverScript

function Run-PythonResolverTests {
    $results = @()

    # Test 1: Resolve in current environment
    $resolved = Resolve-PythonExecutable
    $test1Pass = ($resolved.validated -eq $true -and (Test-Path $resolved.path) -and $resolved.version)
    $results += [PSCustomObject]@{
        Test     = "Resolve in Current Environment"
        Pass     = $test1Pass
        Path     = $resolved.path
        Version  = $resolved.version
        Source   = $resolved.source
    }

    # Test 2: WindowsApps stub rejection
    $winAppsStub = "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"
    $test2Pass = $false
    if (Test-Path $winAppsStub) {
        $stubRes = Test-PythonExecutable $winAppsStub
        $test2Pass = ($null -eq $stubRes)
    } else {
        $test2Pass = $true
    }
    $results += [PSCustomObject]@{
        Test     = "Reject WindowsApps Stub (ExitCode 9009)"
        Pass     = $test2Pass
        Path     = $winAppsStub
        Version  = $null
        Source   = "STUB_REJECT"
    }

    # Test 3: Python without dateutil rejection
    $venvPy = "$env:USERPROFILE\.agent-reach-venv\Scripts\python.exe"
    $test3Pass = $false
    if (Test-Path $venvPy) {
        $venvRes = Test-PythonExecutable $venvPy
        $test3Pass = ($null -eq $venvRes)
    } else {
        $test3Pass = $true
    }
    $results += [PSCustomObject]@{
        Test     = "Reject Python without dateutil"
        Pass     = $test3Pass
        Path     = $venvPy
        Version  = $null
        Source   = "DATEUTIL_REJECT"
    }

    # Test 4: Simulated Task Scheduler PATH (WindowsApps stub + venv without dateutil)
    $machPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $origPath = $env:PATH
    $taskSimRes = $null
    try {
        $env:PATH = "$machPath;$userPath"
        $taskSimRes = Resolve-PythonExecutable
    } finally {
        $env:PATH = $origPath
    }
    $test4Pass = ($taskSimRes.validated -eq $true -and (Test-Path $taskSimRes.path) -and $taskSimRes.source -in @("REGISTRY", "WELL_KNOWN", "SCAN", "CONDA_ENV"))
    $results += [PSCustomObject]@{
        Test     = "Resolve under Simulated Task Scheduler PATH"
        Pass     = $test4Pass
        Path     = $taskSimRes.path
        Version  = $taskSimRes.version
        Source   = $taskSimRes.source
    }

    # Test 5: Verify executable works with --version and dateutil directly
    $directVer = & $resolved.path --version 2>&1
    $directDu = & $resolved.path -c "import dateutil; print(dateutil.__file__)" 2>&1
    $test5Pass = ($LASTEXITCODE -eq 0 -and $directDu -match "dateutil")
    $results += [PSCustomObject]@{
        Test     = "Direct Python --version and dateutil execution"
        Pass     = $test5Pass
        Path     = $resolved.path
        Version  = "$directVer"
        Source   = "DIRECT_RUN"
    }

    return $results
}

Run-PythonResolverTests | Format-Table -AutoSize
